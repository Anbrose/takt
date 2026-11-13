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
    /// Calls made, for tests.
    public private(set) var calls: [String] = []
    /// When set, the next call throws this error.
    private var failNext: Error?

    public init() {}

    public func failNextCall(with error: Error) { failNext = error }

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
        projectList.append(p)
        return p
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
            lat: body.lat, lng: body.lng,
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

    // MARK: Building

    /// Adds a task (or a root when `parent` is nil); returns its id.
    @discardableResult
    public func add(
        parent: String?, name: String, short: String? = nil, place: String = "",
        lat: Double? = nil, lng: Double? = nil, prerequisites: [(String, Urgency)] = []
    ) -> String {
        let id = newId()
        let pres = prerequisites.map { Prerequisite(id: newId(), action: $0.0, urgency: $0.1, done: false) }
        nodes[id] = Node(
            summary: TaskSummary(
                id: id, name: name, short: short ?? name, place: place, lat: lat, lng: lng,
                completed: false, prerequisites: pres, childCount: 0
            ),
            parent: parent
        )
        if let parent {
            nodes[parent]?.children.append(id)
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
            parent: p.rootTaskId, name: "大阪", place: "大阪府 · 关西", lat: 34.6937, lng: 135.5023,
            prerequisites: [("预订去程机票", .before), ("预订大阪住宿", .before)])
        await b.add(parent: osaka, name: "大阪城天守阁", short: "大阪城", place: "中央区 · 大阪城公园",
                    lat: 34.6873, lng: 135.5262, prerequisites: [("购买天守阁门票", .onsite)])
        await b.add(parent: osaka, name: "日本环球影城", short: "环球影城", place: "此花区 · 樱岛",
                    lat: 34.6654, lng: 135.4323,
                    prerequisites: [("购买指定日期入园门票", .before), ("抢购快速通关券", .early)])
        await b.add(parent: osaka, name: "道顿堀", place: "中央区 · 难波", lat: 34.6687, lng: 135.5013)
        await b.add(parent: osaka, name: "海游馆", place: "港区 · 天保山", lat: 34.6545, lng: 135.4290,
                    prerequisites: [("网上预约入场时段", .before)])
        await b.add(parent: osaka, name: "梅田蓝天大厦空中庭园", short: "梅田空中庭园", place: "北区 · 梅田",
                    lat: 34.7053, lng: 135.4903, prerequisites: [("购买展望台门票", .onsite)])
        await b.add(parent: osaka, name: "通天阁", place: "浪速区 · 新世界", lat: 34.6525, lng: 135.5063,
                    prerequisites: [("购买展望台门票", .onsite)])
        let tokyo = await b.add(
            parent: p.rootTaskId, name: "东京", place: "东京都 · 关东", lat: 35.6812, lng: 139.7671,
            prerequisites: [("预订东京住宿", .before), ("购买大阪→东京新干线车票", .onsite)])
        await b.add(parent: tokyo, name: "三鹰之森吉卜力美术馆", short: "吉卜力", place: "三鹰市 · 井之头公园",
                    lat: 35.6962, lng: 139.5704, prerequisites: [("抢购指定日期时段门票", .early)])
        await b.add(parent: tokyo, name: "涩谷 SKY", place: "涩谷区 · 涩谷站", lat: 35.6585, lng: 139.7022,
                    prerequisites: [("预约指定时段门票", .before)])
        await b.add(parent: tokyo, name: "teamLab Planets", short: "teamLab", place: "江东区 · 丰洲",
                    lat: 35.6491, lng: 139.7898, prerequisites: [("预约指定时段门票", .before)])
        await b.add(parent: tokyo, name: "浅草寺", place: "台东区 · 浅草", lat: 35.7148, lng: 139.7967)
        await b.add(parent: tokyo, name: "东京塔", place: "港区 · 芝公园", lat: 35.6586, lng: 139.7454,
                    prerequisites: [("购买展望台门票", .onsite)])
        let hokkaido = await b.add(
            parent: p.rootTaskId, name: "北海道", place: "札幌 · 北海道", lat: 43.0618, lng: 141.3545,
            prerequisites: [("预订东京→札幌机票", .before), ("预订回程机票", .before)])
        await b.add(parent: hokkaido, name: "大通公园", place: "札幌市 · 中央区", lat: 43.0600, lng: 141.3478)
        await b.add(parent: hokkaido, name: "小樽运河", short: "小樽", place: "小樽市", lat: 43.1984, lng: 141.0020)
        await b.add(parent: hokkaido, name: "函馆山夜景", short: "函馆山", place: "函馆市", lat: 41.7590,
                    lng: 140.7044, prerequisites: [("购买缆车票", .onsite)])
        return b
    }
}
