import Foundation
import TaktAPI

/// Offline backend with the same rules as the server (append on create, versioned reorder).
/// Used by tests, SwiftUI previews and the app's demo mode (`-demo` launch argument).
public actor InMemoryBackend: TaktBackend {
    struct Node {
        var summary: TaskSummary
        var parent: String?
        var children: [String] = []
        var version = 0
    }

    private var projectList: [Project] = []
    private var nodes: [String: Node] = [:]
    private var nextId = 0
    private var noteRows: [String: NoteRow] = [:]
    /// Calls made, for tests.
    public private(set) var calls: [String] = []
    /// When set, the next call throws this error.
    private var failNext: Error?

    /// A stored note: what the server keeps, minus the audio itself.
    struct NoteRow {
        var id: String
        var title: String
        var locale: String
        var createdAt: Date
        var durationMs = 0
        var transcript: [TranscriptLine] = []
        var speakers: [Speaker] = []
        /// Uploaded segments: index -> duration.
        var segments: [Int: Int] = [:]
        var chains: [Chain] = []
        var extractionVersion = 0
        var imported: [ImportedStep] = []
        /// The transcript the current draft was extracted from (nil = never extracted).
        var extractedFrom: [TranscriptLine]?
    }

    /// Segments that were given an upload ticket (the server only completes uploaded audio).
    private var ticketed: Set<String> = []

    public init() {}

    public func failNextCall(with error: Error) { failNext = error }

    /// Test hook: the next `extract` throws an API error with this status and code (the call is still recorded).
    public func failNextExtract(with code: String, status: Int) {
        failNextExtractError = .api(status: status, code: code, message: code)
    }
    private var failNextExtractError: BackendError?

    /// Test / demo hook: every `extract` waits for this before answering (the language model's latency).
    public func delayExtract(_ wait: (@Sendable () async -> Void)?) { extractDelay = wait }
    private var extractDelay: (@Sendable () async -> Void)?

    /// Bumps a level's version as if another device had changed it.
    public func touch(_ taskId: String) { nodes[taskId]?.version += 1 }

    // MARK: TaktBackend

    public func projects() async throws -> [Project] {
        try check("projects")
        return projectList
    }

    public func createProject(name: String) async throws -> Project {
        try check("createProject")
        let root = add(parent: nil, name: name)
        let p = Project(id: newId(), name: name, rootTaskId: root, createdAt: Date())
        projectList.insert(p, at: 0)
        return p
    }

    public func renameProject(_ id: String, name: String) async throws -> Project {
        try check("renameProject \(id)")
        guard let i = projectList.firstIndex(where: { $0.id == id }) else { throw notFound }
        projectList[i].name = name
        let root = projectList[i].rootTaskId
        nodes[root]?.summary.name = name
        nodes[root]?.summary.short = name
        return projectList[i]
    }

    public func deleteProject(_ id: String) async throws {
        try check("deleteProject \(id)")
        guard let i = projectList.firstIndex(where: { $0.id == id }) else { throw notFound }
        var stack = [projectList[i].rootTaskId]
        while let t = stack.popLast() {
            stack += nodes[t]?.children ?? []
            nodes[t] = nil
        }
        projectList.remove(at: i)
    }

    public func level(_ taskId: String) async throws -> Level {
        try check("level \(taskId)")
        return try levelOf(taskId)
    }

    public func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary {
        try check("createTask \(parentId)")
        guard nodes[parentId] != nil else { throw notFound }
        let id = add(
            parent: parentId, name: body.name, short: body.short, place: body.place ?? "",
            address: body.address ?? "", lat: body.lat, lng: body.lng,
            prerequisites: (body.prerequisites ?? []).map { ($0.action, $0.urgency ?? .before) }
        )
        return nodes[id]!.summary
    }

    public func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level {
        try check("reorder \(parentId) \(ids.joined(separator: ","))")
        guard let node = nodes[parentId] else { throw notFound }
        guard node.version == version else {
            throw BackendError.api(status: 409, code: "version_conflict", message: "changed")
        }
        guard Set(ids) == Set(node.children), ids.count == node.children.count else {
            throw BackendError.api(status: 400, code: "not_a_permutation", message: "bad ids")
        }
        nodes[parentId]!.children = ids
        nodes[parentId]!.version += 1
        return try levelOf(parentId)
    }

    public func deleteTask(_ id: String) async throws -> Level {
        try check("deleteTask \(id)")
        guard let node = nodes[id] else { throw notFound }
        guard let parent = node.parent else {
            throw BackendError.api(status: 400, code: "cannot_delete_root", message: "root")
        }
        func drop(_ id: String) {
            for c in nodes[id]?.children ?? [] { drop(c) }
            nodes[id] = nil
        }
        drop(id)
        nodes[parent]!.children.removeAll { $0 == id }
        nodes[parent]!.version += 1
        return try levelOf(parent)
    }

    public func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite {
        try check("setPrerequisite \(id)")
        for (key, n) in nodes {
            if let i = n.summary.prerequisites.firstIndex(where: { $0.id == id }) {
                nodes[key]!.summary.prerequisites[i].done = done
                return nodes[key]!.summary.prerequisites[i]
            }
        }
        throw notFound
    }

    public func moveTask(_ id: String, to parent: String, before: String?) async throws -> (from: Level, to: Level) {
        try check("moveTask \(id) \(parent) \(before ?? "-")")
        guard let node = nodes[id], nodes[parent] != nil else { throw notFound }
        if let before, nodes[before] == nil { throw notFound }
        guard rootOf(id) == rootOf(parent) else {
            throw BackendError.api(status: 400, code: "cross_project", message: "other project")
        }
        guard let from = node.parent else {
            throw BackendError.api(status: 400, code: "root_task", message: "root")
        }
        var cur: String? = parent
        while let c = cur {
            if c == id { throw BackendError.api(status: 400, code: "move_into_self", message: "into itself") }
            cur = nodes[c]?.parent
        }
        var target = nodes[parent]!.children.filter { $0 != id }
        if let before {
            guard before != id, let at = target.firstIndex(of: before) else {
                throw BackendError.api(status: 400, code: "bad_before", message: "not a sibling")
            }
            target.insert(id, at: at)
        } else {
            target.append(id)
        }
        if from == parent {
            nodes[parent]!.children = target
            nodes[parent]!.version += 1
        } else {
            nodes[from]!.children.removeAll { $0 == id }
            nodes[from]!.version += 1
            nodes[parent]!.children = target
            nodes[parent]!.version += 1
            nodes[id]!.parent = parent
        }
        return (try levelOf(from), try levelOf(parent))
    }

    public func search(_ q: String) async throws -> SearchResult {
        try check("search \(q)")
        let hit: (String) -> Bool = { $0.range(of: q, options: [.caseInsensitive, .literal]) != nil }
        let cap = 20
        let projects = projectList.filter { hit($0.name) }
            .sorted { $0.name < $1.name }.prefix(cap)
            .map { SearchResult.ProjectsPayloadPayload(id: $0.id, name: $0.name) }
        var tasks: [(name: String, hit: SearchResult.TasksPayloadPayload)] = []
        for p in projectList {
            var stack: [(id: String, path: [String])] = [(p.rootTaskId, [p.name])]
            while let (id, path) = stack.popLast() {
                guard let n = nodes[id] else { continue }
                if let parent = n.parent, hit(n.summary.name) {
                    tasks.append((n.summary.name, .init(
                        id: id, name: n.summary.name, projectId: p.id, parentTaskId: parent, path: path)))
                }
                let below = n.parent == nil ? path : path + [n.summary.name]
                stack += n.children.reversed().map { ($0, below) }
            }
        }
        var notes: [SearchResult.NotesPayloadPayload] = []
        let rows = noteRows.values.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        for r in rows.prefix(cap) {
            if hit(r.title) {
                notes.append(.init(noteId: r.id, title: r.title, lineIndex: nil, startMs: nil, text: r.title))
            }
            for (i, l) in r.transcript.enumerated().filter({ hit($0.element.text) }).prefix(2) {
                notes.append(.init(noteId: r.id, title: r.title, lineIndex: i, startMs: l.startMs, text: l.text))
            }
        }
        return SearchResult(
            projects: Array(projects),
            tasks: tasks.sorted { $0.name < $1.name }.prefix(cap).map(\.hit),
            notes: Array(notes.prefix(cap)))
    }

    // MARK: Notes

    public func notes() async throws -> [NoteSummary] {
        try check("notes")
        return noteRows.values
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .map(summary)
    }

    public func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note {
        try check("createNote \(id)")
        if let existing = noteRows[id] { return note(existing) }
        noteRows[id] = NoteRow(id: id, title: title ?? Self.defaultTitle(createdAt), locale: locale, createdAt: createdAt)
        return note(noteRows[id]!)
    }

    public func note(_ id: String) async throws -> Note {
        try check("note \(id)")
        return note(try row(id))
    }

    public func updateNote(
        _ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?
    ) async throws -> Note {
        try check("updateNote \(id)")
        var r = try row(id)
        if let title { r.title = title }
        if let durationMs { r.durationMs = durationMs }
        if let speakers { r.speakers = speakers }
        if let transcript { r.transcript = transcript }
        noteRows[id] = r
        return note(r)
    }

    public func deleteNote(_ id: String) async throws {
        try check("deleteNote \(id)")
        _ = try row(id)
        noteRows[id] = nil
        ticketed = ticketed.filter { !$0.hasPrefix("\(id)/") }
    }

    public func uploadTicket(note id: String, segment: Int) async throws -> UploadTicket {
        try check("uploadTicket \(id) \(segment)")
        _ = try row(id)
        ticketed.insert("\(id)/\(segment)")
        let now = Date()
        return UploadTicket(uploadUrl: Self.audioURL(id, segment), expiresAt: now.addingTimeInterval(900))
    }

    public func completeSegment(note id: String, segment: Int, durationMs: Int) async throws -> Note {
        try check("completeSegment \(id) \(segment)")
        var r = try row(id)
        guard ticketed.contains("\(id)/\(segment)") else {
            throw BackendError.api(status: 409, code: "segment_missing", message: "not uploaded")
        }
        r.segments[segment] = durationMs
        r.durationMs = r.segments.values.reduce(0, +)
        noteRows[id] = r
        return note(r)
    }

    public func noteAudio(_ id: String) async throws -> AudioUrls {
        try check("noteAudio \(id)")
        let r = try row(id)
        let expires = Date().addingTimeInterval(3600)
        return AudioUrls(segments: r.segments.sorted { $0.key < $1.key }.map {
            AudioSegmentURL(index: $0.key, durationMs: $0.value, url: Self.audioURL(id, $0.key), expiresAt: expires)
        })
    }

    /// Deterministic stand-in for the language model: one chain per line that mentions
    /// 去 / 订 / 买, with that line as its only step.
    public func extract(note id: String) async throws -> Note {
        try check("extract \(id)")
        if let extractDelay { await extractDelay() }
        if let e = failNextExtractError {
            failNextExtractError = nil
            throw e
        }
        var r = try row(id)
        guard !r.transcript.isEmpty else {
            throw BackendError.api(status: 400, code: "empty_transcript", message: "empty")
        }
        if r.extractedFrom == r.transcript { return note(r) }
        let last = r.transcript.map(\.endMs).max() ?? 0
        if r.transcript.map(\.text) == Self.kyotoLines.map(\.2) {
            r.chains = kyotoChains(r.transcript)
            r.extractionVersion += 1
            r.extractedFrom = r.transcript
            noteRows[id] = r
            return note(r)
        }
        r.chains = r.transcript.filter { l in ["去", "订", "买"].contains { l.text.contains($0) } }.map { l in
            let text = String(l.text.trimmingCharacters(in: .whitespaces).prefix(200))
            let clause = text.split(whereSeparator: { "，。！？,.!?".contains($0) }).first.map(String.init) ?? text
            return Chain(
                id: newId(), name: clause,
                steps: [ChainStep(
                    id: newId(), name: text,
                    quote: Quote(startMs: min(l.startMs, last), endMs: min(max(l.endMs, l.startMs), last)))])
        }
        r.extractionVersion += 1
        r.extractedFrom = r.transcript
        noteRows[id] = r
        return note(r)
    }

    public func updateExtraction(note id: String, version: Int, chains: [Chain]) async throws -> Note {
        try check("updateExtraction \(id)")
        var r = try row(id)
        guard version == r.extractionVersion else {
            throw BackendError.api(status: 409, code: "version_conflict", message: "changed")
        }
        let done = Set(r.imported.map(\.stepId))
        guard !chains.contains(where: { $0.steps.contains { done.contains($0.id) } }) else {
            throw BackendError.api(status: 400, code: "already_imported", message: "imported")
        }
        r.chains = chains
        r.extractionVersion += 1
        noteRows[id] = r
        return note(r)
    }

    public func importNote(
        _ id: String, parent: String, picks: [ImportPick], before: String?
    ) async throws -> (level: Level, note: Note) {
        try check("importNote \(id)")
        var r = try row(id)
        guard nodes[parent] != nil else { throw notFound }
        if let before, nodes[parent]!.children.contains(before) == false {
            throw BackendError.api(status: 400, code: "bad_before", message: "not a child of the parent")
        }

        // Validate every pick against the current draft before writing anything.
        let draft = Dictionary(r.chains.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var plan: [(chain: Chain, steps: [ChainStep], places: [String: PickedPlace])] = []
        for pick in picks {
            let wanted = Set(pick.stepIds)
            let steps = draft[pick.chainId]?.steps.filter { wanted.contains($0.id) } ?? []
            guard let chain = draft[pick.chainId], steps.count == wanted.count, pick.stepIds.count == wanted.count else {
                throw BackendError.api(status: 409, code: "stale_draft", message: "reload the draft")
            }
            for s in steps where !used.insert(s.id).inserted {
                throw BackendError.api(status: 400, code: "duplicate_pick", message: "picked twice")
            }
            plan.append((chain, steps, pick.placesByStep))
        }

        let now = Date()
        for (chain, steps, places) in plan {
            // One step is a plain task; a chain of two or more becomes a parent with ordered children.
            let group = steps.count >= 2 ? add(parent: parent, before: before, name: chain.name) : parent
            for s in steps {
                let task: String
                if let p = places[s.id] {
                    task = add(
                        parent: group, before: group == parent ? before : nil, name: s.name, place: p.place,
                        address: p.address, lat: p.lat, lng: p.lng)
                } else {
                    task = add(parent: group, before: group == parent ? before : nil, name: s.name, place: s.place ?? "")
                }
                r.imported.append(ImportedStep(
                    stepId: s.id, chainName: chain.name, stepName: s.name, taskId: task, parentTaskId: group,
                    importedAt: now))
            }
        }
        r.chains = r.chains
            .map { Chain(id: $0.id, name: $0.name, steps: $0.steps.filter { !used.contains($0.id) }) }
            .filter { !$0.steps.isEmpty }
        r.extractionVersion += 1
        noteRows[id] = r
        return (try levelOf(parent), note(r))
    }

    /// Stores a ready-made note (demo data, tests).
    public func seed(_ n: Note) {
        noteRows[n.id] = NoteRow(
            id: n.id, title: n.title, locale: n.locale, createdAt: n.createdAt, durationMs: n.durationMs,
            transcript: n.transcript, speakers: n.speakers,
            segments: Dictionary(n.segments.filter(\.uploaded).map { ($0.index, $0.durationMs) }, uniquingKeysWith: { a, _ in a }),
            chains: n.extraction.chains, extractionVersion: n.extraction.version, imported: n.imported)
    }

    private func row(_ id: String) throws -> NoteRow {
        guard let r = noteRows[id] else { throw notFound }
        return r
    }

    private func summary(_ r: NoteRow) -> NoteSummary {
        NoteSummary(
            id: r.id, title: r.title, locale: r.locale, durationMs: r.durationMs, createdAt: r.createdAt,
            hasTranscript: !r.transcript.isEmpty, chainCount: r.chains.count, importedCount: r.imported.count)
    }

    private func note(_ r: NoteRow) -> Note {
        Note(
            id: r.id, title: r.title, locale: r.locale, durationMs: r.durationMs, createdAt: r.createdAt,
            hasTranscript: !r.transcript.isEmpty, chainCount: r.chains.count, importedCount: r.imported.count,
            transcript: r.transcript, speakers: r.speakers,
            segments: r.segments.sorted { $0.key < $1.key }.map {
                NoteSegment(index: $0.key, durationMs: $0.value, uploaded: true)
            },
            extraction: .init(version: r.extractionVersion, chains: r.chains), imported: r.imported)
    }

    private static func audioURL(_ note: String, _ segment: Int) -> String { "memory://notes/\(note)/\(segment).m4a" }

    /// `YYYY-MM-DD HH:mm` in UTC, like the server.
    private static func defaultTitle(_ at: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: at)
    }

    // MARK: Building

    /// Adds a task (or a root when `parent` is nil); returns its id.
    @discardableResult
    public func add(
        parent: String?, before: String? = nil, name: String, short: String? = nil, place: String = "", address: String = "",
        lat: Double? = nil, lng: Double? = nil, prerequisites: [(String, Urgency)] = []
    ) -> String {
        let id = newId()
        let pres = prerequisites.map { Prerequisite(id: newId(), action: $0.0, urgency: $0.1, done: false) }
        nodes[id] = Node(
            summary: TaskSummary(
                id: id, name: name, short: short ?? name, place: place, address: address, lat: lat, lng: lng,
                completed: false, prerequisites: pres, childCount: 0
            ),
            parent: parent
        )
        if let parent {
            if let before, let at = nodes[parent]?.children.firstIndex(of: before) {
                nodes[parent]?.children.insert(id, at: at)
            } else {
                nodes[parent]?.children.append(id)
            }
            nodes[parent]?.version += 1
        }
        return id
    }

    private func levelOf(_ taskId: String) throws -> Level {
        guard let node = nodes[taskId] else { throw notFound }
        var crumbs: [Crumb] = []
        var cur: String? = taskId
        while let c = cur, let n = nodes[c] {
            crumbs.insert(Crumb(id: c, name: n.summary.name), at: 0)
            cur = n.parent
        }
        let project = projectList.first { p in crumbs.first?.id == p.rootTaskId }
        return Level(
            projectId: project?.id ?? "",
            task: Crumb(id: taskId, name: node.summary.name),
            breadcrumb: crumbs,
            version: node.version,
            children: node.children.compactMap { id in
                guard var s = nodes[id]?.summary else { return nil }
                s.childCount = nodes[id]?.children.count ?? 0
                return s
            }
        )
    }

    /// The project root a task hangs under.
    private func rootOf(_ id: String) -> String {
        var cur = id
        while let p = nodes[cur]?.parent { cur = p }
        return cur
    }

    private func newId() -> String {
        nextId += 1
        return String(format: "00000000-0000-4000-8000-%012d", nextId)
    }

    private func check(_ call: String) throws {
        calls.append(call)
        if let e = failNext {
            failNext = nil
            throw e
        }
    }

    private var notFound: BackendError { .api(status: 404, code: "not_found", message: "not found") }
}

extension InMemoryBackend {
    /// The 日本旅行 sample (a subset of packages/fixtures/data/japan-trip.json).
    public static func sample() async -> InMemoryBackend {
        let b = InMemoryBackend()
        let p = try! await b.createProject(name: "日本旅行")
        let osaka = await b.add(
            parent: p.rootTaskId, name: "大阪", place: "大阪府 · 关西", address: "大阪府大阪市北区梅田3丁目1-1",
                    lat: 34.6937, lng: 135.5023,
            prerequisites: [("预订去程机票", .before), ("预订大阪住宿", .before)])
        await b.add(parent: osaka, name: "大阪城天守阁", short: "大阪城", place: "中央区 · 大阪城公园",
                    address: "大阪府大阪市中央区大阪城1-1",
                    lat: 34.6873, lng: 135.5262, prerequisites: [("购买天守阁门票", .onsite)])
        await b.add(parent: osaka, name: "日本环球影城", short: "环球影城", place: "此花区 · 樱岛",
                    address: "大阪府大阪市此花区桜島2丁目1-33",
                    lat: 34.6654, lng: 135.4323,
                    prerequisites: [("购买指定日期入园门票", .before), ("抢购快速通关券", .early)])
        await b.add(parent: osaka, name: "道顿堀", place: "中央区 · 难波", address: "大阪府大阪市中央区道頓堀1丁目",
                    lat: 34.6687, lng: 135.5013)
        await b.add(parent: osaka, name: "海游馆", place: "港区 · 天保山", address: "大阪府大阪市港区海岸通1丁目1-10",
                    lat: 34.6545, lng: 135.4290,
                    prerequisites: [("网上预约入场时段", .before)])
        await b.add(parent: osaka, name: "梅田蓝天大厦空中庭园", short: "梅田空中庭园", place: "北区 · 梅田",
                    address: "大阪府大阪市北区大淀中1丁目1-88",
                    lat: 34.7053, lng: 135.4903, prerequisites: [("购买展望台门票", .onsite)])
        await b.add(parent: osaka, name: "通天阁", place: "浪速区 · 新世界", address: "大阪府大阪市浪速区恵美須東1丁目18-6",
                    lat: 34.6525, lng: 135.5063,
                    prerequisites: [("购买展望台门票", .onsite)])
        let tokyo = await b.add(
            parent: p.rootTaskId, name: "东京", place: "东京都 · 关东", address: "東京都千代田区丸の内1丁目",
                    lat: 35.6812, lng: 139.7671,
            prerequisites: [("预订东京住宿", .before), ("购买大阪→东京新干线车票", .onsite)])
        await b.add(parent: tokyo, name: "三鹰之森吉卜力美术馆", short: "吉卜力", place: "三鹰市 · 井之头公园",
                    address: "東京都三鷹市下連雀1丁目1-83",
                    lat: 35.6962, lng: 139.5704, prerequisites: [("抢购指定日期时段门票", .early)])
        await b.add(parent: tokyo, name: "涩谷 SKY", place: "涩谷区 · 涩谷站", address: "東京都渋谷区渋谷2丁目24-12",
                    lat: 35.6585, lng: 139.7022,
                    prerequisites: [("预约指定时段门票", .before)])
        await b.add(parent: tokyo, name: "teamLab Planets", short: "teamLab", place: "江东区 · 丰洲",
                    address: "東京都江東区豊洲6丁目1-16",
                    lat: 35.6491, lng: 139.7898, prerequisites: [("预约指定时段门票", .before)])
        await b.add(parent: tokyo, name: "浅草寺", place: "台东区 · 浅草", address: "東京都台東区浅草2丁目3-1",
                    lat: 35.7148, lng: 139.7967)
        await b.add(parent: tokyo, name: "东京塔", place: "港区 · 芝公园", address: "東京都港区芝公園4丁目2-8",
                    lat: 35.6586, lng: 139.7454,
                    prerequisites: [("购买展望台门票", .onsite)])
        let hokkaido = await b.add(
            parent: p.rootTaskId, name: "北海道", place: "札幌 · 北海道", address: "北海道札幌市北区北6条西4丁目",
                    lat: 43.0618, lng: 141.3545,
            prerequisites: [("预订东京→札幌机票", .before), ("预订回程机票", .before)])
        await b.add(parent: hokkaido, name: "大通公园", place: "札幌市 · 中央区", address: "北海道札幌市中央区大通西7丁目",
                    lat: 43.0600, lng: 141.3478)
        await b.add(parent: hokkaido, name: "小樽运河", short: "小樽", place: "小樽市", address: "北海道小樽市港町5",
                    lat: 43.1984, lng: 141.0020)
        await b.add(parent: hokkaido, name: "函馆山夜景", short: "函馆山", place: "函馆市", address: "北海道函館市元町19-7",
                    lat: 41.7590,
                    lng: 140.7044, prerequisites: [("购买缆车票", .onsite)])
        await b.seedKyotoNote()
        return b
    }

    /// The spike's 京都 conversation: (start ms, speaker, text), about 6 s per line.
    static let kyotoLines: [(Int, String, String)] = [
        (0, "1", "下周去京都的行程我们定一下吧，我想第一天先去伏见稻荷大社。"),
        (6000, "2", "好啊，那我来订酒店，最好住在京都站附近，交通方便一点。"),
        (12000, "3", "伏见稻荷人很多，建议早上七点之前到，拍照比较清净。"),
        (19000, "1", "那就七点出发。之后去清水寺，中午在二年坂吃午饭。"),
        (25000, "2", "午饭要提前预约吗？我可以顺便查一下二年坂那家荞麦面店。"),
        (31000, "3", "要的，周末一般要排队。还有，岚山的小火车票也得提前在网上买。"),
        (38000, "1", "岚山放第二天吧。第二天上午小火车，下午去竹林和天龙寺。"),
        (44000, "2", "好，那小火车票我也一起买了，酒店和车票都交给我。"),
    ]

    /// What the language model makes of the 京都 conversation (the canvas's `ntExtract`): (chain, [(step, place,
    /// transcript line)]). Quotes point at those lines, wherever the recording put them.
    static let kyotoDraft: [(String, [(String, String, Int)])] = [
        ("京都第一天", [("伏见稻荷大社", "伏见稻荷大社", 0), ("清水寺", "清水寺", 3), ("二年坂吃午饭", "二年坂", 3)]),
        ("京都第二天", [("岚山小火车", "嵯峨野观光小火车", 6), ("竹林", "嵯峨野竹林", 6), ("天龙寺", "天龙寺", 6)]),
        ("订京都站附近的酒店", [("订京都站附近的酒店", "京都站", 1)]),
        ("预约二年坂荞麦面店", [("预约二年坂荞麦面店", "二年坂", 4)]),
    ]

    func kyotoChains(_ transcript: [TranscriptLine]) -> [Chain] {
        Self.kyotoDraft.map { name, steps in
            Chain(id: newId(), name: name, steps: steps.map { step, place, line in
                let l = transcript[line]
                return ChainStep(id: newId(), name: step, place: place, quote: Quote(startMs: l.startMs, endMs: l.endMs))
            })
        }
    }

    /// 京都讨论: the spike's 8-line, 3-speaker transcript (50.3 s), recorded in one segment.
    func seedKyotoNote() {
        let lines = Self.kyotoLines
        let created = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2026, month: 11, day: 20, hour: 9
        ).date!
        let transcript = lines.map { TranscriptLine(startMs: $0.0, endMs: $0.0 + 5800, text: $0.2, speaker: $0.1) }
        seed(Note(
            id: newId(), title: "京都讨论", locale: "zh-CN", durationMs: 50340, createdAt: created,
            hasTranscript: true, chainCount: 0, importedCount: 0, transcript: transcript,
            speakers: [Speaker(id: "1", name: "我"), Speaker(id: "2", name: "小林"), Speaker(id: "3", name: "3")],
            segments: [NoteSegment(index: 0, durationMs: 50340, uploaded: true)],
            extraction: .init(version: 0, chains: []), imported: []))
    }
}
