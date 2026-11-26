import Foundation
import Testing
import TaktAPI
import TaktCore
import TaktUI
@testable import TaktNotes

struct Offline: Error {}

final class FakeUploader: SegmentUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _failing: Bool
    private var _uploads: [String] = []
    init(failing: Bool = false) { _failing = failing }
    var failing: Bool { get { lock.withLock { _failing } } set { lock.withLock { _failing = newValue } } }
    var uploads: [String] { lock.withLock { _uploads } }
    func upload(_ file: URL, to sessionURL: URL) async throws {
        if failing { throw Offline() }
        lock.withLock { _uploads.append(file.lastPathComponent) }
    }
}

private let lines = [
    AlignedLine(startMs: 0, endMs: 900, text: "你好", speaker: "1"),
    AlignedLine(startMs: 1000, endMs: 2000, text: "好", speaker: "2"),
    AlignedLine(startMs: 2100, endMs: 3000, text: "嗯", speaker: "1"),
]

/// A stopped note with `segments` audio files on disk.
private func seed(
    _ store: NoteStore, segments: Int = 2, lines: [AlignedLine]? = nil, diarized: Bool = false
) async throws -> LocalNote {
    var n = LocalNote(
        title: "t", locale: "zh-CN",
        segments: (0..<segments).map { LocalSegment(index: $0, durationMs: 1000, file: "\($0).m4a", transcribed: true) },
        lines: lines, diarized: diarized, recording: false)
    n.id = UUID()
    try await store.save(n)
    for i in 0..<segments { try Data("a".utf8).write(to: await store.segmentURL(n.id, i)) }
    return n
}

private func exists(_ store: NoteStore, _ n: LocalNote, _ i: Int) async -> Bool {
    FileManager.default.fileExists(atPath: await store.segmentURL(n.id, i).path)
}

@Suite struct NoteSyncTests {
    @Test func syncsInOrderAndDeletesLocalAudio() async throws {
        let (store, _) = tempStore()
        let backend = InMemoryBackend()
        let up = FakeUploader()
        let n = try await seed(store, lines: lines, diarized: true)
        await NoteSync(store: store, backend: backend, uploader: up).sync(n.id)

        let calls = await backend.calls.filter { $0.contains(n.id.uuidString) }.map { $0.split(separator: " ").first.map(String.init)! }
        #expect(calls == ["createNote", "uploadTicket", "completeSegment", "uploadTicket", "completeSegment", "updateNote"])
        #expect(up.uploads == ["0.m4a", "1.m4a"])
        let server = try await backend.note(n.id.uuidString)
        #expect(server.segments.map(\.uploaded) == [true, true])
        #expect(server.transcript.map(\.text) == ["你好", "好", "嗯"])
        #expect(server.transcript.map(\.speaker) == ["1", "2", "1"])
        #expect(server.speakers.map(\.id) == ["1", "2"])
        #expect(server.speakers.map(\.name) == ["1", "2"])
        #expect(server.durationMs == 2000)
        #expect(await exists(store, n, 0) == false)
        #expect(await exists(store, n, 1) == false)
        let saved = try #require(await store.note(n.id))
        #expect(saved.segments.allSatisfy { $0.uploaded })
        #expect(saved.synced == SyncState(created: true, transcriptSent: true, diarizedSent: true))
    }

    @Test func keepsAudioUntilDiarized() async throws {
        let (store, _) = tempStore()
        let backend = InMemoryBackend()
        let sync = NoteSync(store: store, backend: backend, uploader: FakeUploader())
        let unlabeled = lines.map { AlignedLine(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: nil) }
        let n = try await seed(store, lines: unlabeled, diarized: false)
        await sync.sync(n.id)

        let kept0 = await exists(store, n, 0), kept1 = await exists(store, n, 1)
        #expect(kept0 && kept1)
        #expect(await store.note(n.id)?.segments.allSatisfy { $0.uploaded } == true)
        var server = try await backend.note(n.id.uuidString)
        #expect(server.transcript.count == 3)
        #expect(server.transcript.allSatisfy { $0.speaker == nil })
        #expect(server.speakers.isEmpty)

        // Diarization finishes later: speakers are sent again and the audio goes.
        try await store.update(n.id) { $0.lines = lines; $0.diarized = true }
        await sync.sync(n.id)
        server = try await backend.note(n.id.uuidString)
        #expect(server.transcript.map(\.speaker) == ["1", "2", "1"])
        #expect(await exists(store, n, 0) == false)
        #expect(await exists(store, n, 1) == false)
        // Nothing left to send.
        let before = await backend.calls.count
        await sync.sync(n.id)
        #expect(await backend.calls.count == before)
    }

    @Test func offlineKeepsEverythingAndRetries() async throws {
        let (store, _) = tempStore()
        let backend = InMemoryBackend()
        let up = FakeUploader(failing: true)
        let sync = NoteSync(store: store, backend: backend, uploader: up)
        let n = try await seed(store, lines: lines, diarized: true)
        await sync.sync(n.id)

        let kept0 = await exists(store, n, 0), kept1 = await exists(store, n, 1)
        #expect(kept0 && kept1)
        #expect(await store.note(n.id)?.segments.contains { $0.uploaded } == false)
        #expect(try await backend.note(n.id.uuidString).transcript.isEmpty)

        up.failing = false
        await sync.sync(n.id)
        #expect(await exists(store, n, 0) == false)
        #expect(try await backend.note(n.id.uuidString).transcript.count == 3)
    }

    @Test func doesNotDuplicateOnRetryAfterCreate() async throws {
        let (store, _) = tempStore()
        let memory = InMemoryBackend()
        let backend = LostCreateResponse(memory)
        let sync = NoteSync(store: store, backend: backend, uploader: FakeUploader())
        let n = try await seed(store, segments: 1)
        await sync.sync(n.id)  // server created the note, the response was lost
        #expect(await store.note(n.id)?.synced.created == false)
        await sync.sync(n.id)
        #expect(try await memory.notes().count == 1)
        #expect(backend.createCalls == 2)
        #expect(await store.note(n.id)?.segments[0].uploaded == true)
    }

    @Test func resumesAfterRelaunch() async throws {
        let (store, root) = tempStore()
        let backend = InMemoryBackend()
        // (a) created, nothing uploaded.
        let a = try await seed(store, segments: 1, lines: lines, diarized: true)
        try await store.update(a.id) { $0.synced.created = true }
        _ = try await backend.createNote(id: a.id.uuidString, title: "t", locale: "zh-CN", createdAt: a.createdAt)
        // (b) fully uploaded, unlabeled transcript sent, diarization finished afterwards.
        let b = try await seed(store, segments: 1, lines: lines, diarized: true)
        _ = try await backend.createNote(id: b.id.uuidString, title: "t", locale: "zh-CN", createdAt: b.createdAt)
        _ = try await backend.uploadTicket(note: b.id.uuidString, segment: 0)
        _ = try await backend.completeSegment(note: b.id.uuidString, segment: 0, durationMs: 1000)
        try await store.update(b.id) {
            $0.synced = SyncState(created: true, transcriptSent: true, diarizedSent: false)
            $0.segments[0].uploaded = true
        }

        // Fresh store and sync on the same folder, as after a relaunch.
        let store2 = NoteStore(root: root)
        await NoteSync(store: store2, backend: backend, uploader: FakeUploader()).syncAll()

        for n in [a, b] {
            let local = try #require(await store2.note(n.id))
            #expect(local.segments.allSatisfy { $0.uploaded })
            #expect(await exists(store2, n, 0) == false)
            let server = try await backend.note(n.id.uuidString)
            #expect(server.segments.map(\.uploaded) == [true])
            #expect(server.transcript.map(\.speaker) == ["1", "2", "1"])
            #expect(server.speakers.map(\.id) == ["1", "2"])
        }
        #expect(try await backend.notes().count == 2)
    }

    @Test func sendsTranscriptOnlyAfterLines() async throws {
        let (store, _) = tempStore()
        let backend = InMemoryBackend()
        let sync = NoteSync(store: store, backend: backend, uploader: FakeUploader())
        let n = try await seed(store, segments: 1, lines: nil)
        await sync.sync(n.id)
        #expect(await backend.calls.contains { $0.hasPrefix("updateNote") } == false)
        #expect(await store.note(n.id)?.synced.transcriptSent == false)

        try await store.update(n.id) { $0.lines = lines; $0.diarized = true }
        await sync.sync(n.id)
        #expect(await backend.calls.filter { $0.hasPrefix("updateNote") }.count == 1)
    }

    @Test func syncAllCoversEveryNote() async throws {
        let (store, _) = tempStore()
        let backend = InMemoryBackend()
        let a = try await seed(store, segments: 1)
        let b = try await seed(store, segments: 1)
        await NoteSync(store: store, backend: backend, uploader: FakeUploader()).syncAll()
        #expect(try await backend.notes().count == 2)
        #expect(await store.note(a.id)?.synced.created == true)
        #expect(await store.note(b.id)?.synced.created == true)
    }

    @Test func oldSavedSyncStateStillLoads() throws {
        let json = #"{"created":true,"transcriptSent":true}"#
        let s = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        #expect(s == SyncState(created: true, transcriptSent: true, diarizedSent: false))
    }

    @Test func resumeDecision() {
        #expect(UploadResume.decide(status: 200, range: nil) == .done)
        #expect(UploadResume.decide(status: 201, range: nil) == .done)
        #expect(UploadResume.decide(status: 308, range: "bytes=0-41") == .resume(from: 42))
        #expect(UploadResume.decide(status: 308, range: nil) == .resume(from: 0))
        #expect(UploadResume.decide(status: 404, range: nil) == .failed(status: 404))
    }
}

/// Forwards to a memory backend, but the first createNote's response is lost after the server handled it.
final class LostCreateResponse: TaktBackend, @unchecked Sendable {
    let inner: InMemoryBackend
    private let lock = NSLock()
    private var _createCalls = 0
    init(_ inner: InMemoryBackend) { self.inner = inner }
    var createCalls: Int { lock.withLock { _createCalls } }

    func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note {
        let n = lock.withLock { _createCalls += 1; return _createCalls }
        let note = try await inner.createNote(id: id, title: title, locale: locale, createdAt: createdAt)
        if n == 1 { throw Offline() }
        return note
    }
    func projects() async throws -> [Project] { try await inner.projects() }
    func createProject(name: String) async throws -> Project { try await inner.createProject(name: name) }
    func renameProject(_ id: String, name: String) async throws -> Project { try await inner.renameProject(id, name: name) }
    func deleteProject(_ id: String) async throws { try await inner.deleteProject(id) }
    func level(_ taskId: String) async throws -> Level { try await inner.level(taskId) }
    func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary { try await inner.createTask(in: parentId, body) }
    func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level { try await inner.reorder(parentId, ids: ids, version: version) }
    func deleteTask(_ id: String) async throws -> Level { try await inner.deleteTask(id) }
    func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite { try await inner.setPrerequisite(id, done: done) }
    func notes() async throws -> [NoteSummary] { try await inner.notes() }
    func note(_ id: String) async throws -> Note { try await inner.note(id) }
    func updateNote(_ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?) async throws -> Note {
        try await inner.updateNote(id, title: title, durationMs: durationMs, transcript: transcript, speakers: speakers)
    }
    func deleteNote(_ id: String) async throws { try await inner.deleteNote(id) }
    func uploadTicket(note: String, segment: Int) async throws -> UploadTicket { try await inner.uploadTicket(note: note, segment: segment) }
    func completeSegment(note: String, segment: Int, durationMs: Int) async throws -> Note {
        try await inner.completeSegment(note: note, segment: segment, durationMs: durationMs)
    }
    func noteAudio(_ id: String) async throws -> AudioUrls { try await inner.noteAudio(id) }
    func extract(note: String) async throws -> Note { try await inner.extract(note: note) }
    func updateExtraction(note: String, version: Int, chains: [Chain]) async throws -> Note {
        try await inner.updateExtraction(note: note, version: version, chains: chains)
    }
    func moveTask(_ id: String, to parent: String, before: String?) async throws -> (from: Level, to: Level) {
        try await inner.moveTask(id, to: parent, before: before)
    }
    func search(_ q: String) async throws -> SearchResult { try await inner.search(q) }
    func importNote(_ id: String, parent: String, picks: [ImportPick], before: String?) async throws -> (level: Level, note: Note) {
        try await inner.importNote(id, parent: parent, picks: picks, before: before)
    }
}

/// Scripted GCS: answers each request in order from `replies` and records them.
final class StubGCS: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(status: Int, range: String?)] = []
    nonisolated(unsafe) static var requests: [String?] = []  // Content-Range of each request
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.value(forHTTPHeaderField: "Content-Range"))
        let r = Self.replies.isEmpty ? (status: 500, range: nil) : Self.replies.removeFirst()
        var headers: [String: String] = [:]
        if let range = r.range { headers["Range"] = range }
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct GCSUploaderTests {
    private func run(_ replies: [(Int, String?)]) async -> (Error?, [String?]) {
        StubGCS.replies = replies.map { (status: $0.0, range: $0.1) }
        StubGCS.requests = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubGCS.self]
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try? Data(count: 10).write(to: file)
        do {
            try await GCSUploader(session: URLSession(configuration: cfg), attempts: 3)
                .upload(file, to: URL(string: "https://gcs.test/session")!)
            return (nil, StubGCS.requests)
        } catch { return (error, StubGCS.requests) }
    }

    @Test func permanentFailureIsNotRetried() async {
        let (error, requests) = await run([(404, nil)])
        #expect(error as? UploadFailed == UploadFailed(status: 404))
        #expect(requests.count == 1)
    }

    @Test func resumesFromReportedOffset() async {
        // PUT dropped (500), status says 4 bytes arrived, resumed PUT finishes.
        let (error, requests) = await run([(500, nil), (308, "bytes=0-3"), (200, nil)])
        #expect(error == nil)
        #expect(requests == [nil, "bytes */10", "bytes 4-9/10"])
    }

    @Test func fullyReceivedAsksStatusInsteadOfEmptyPut() async {
        let (error, requests) = await run([(500, nil), (308, "bytes=0-9"), (200, nil)])
        #expect(error == nil)
        #expect(requests == [nil, "bytes */10", "bytes */10"])
    }
}

/// Forwards to an InMemoryBackend; the first updateNote waits until the gate opens.
private actor Gate {
    var entered = false
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pass() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { isOpen = true; waiter?.resume(); waiter = nil }
    func waitEntered() async { while !entered { await Task.yield() } }
}

private struct GatedBackend: TaktBackend {
    let inner: InMemoryBackend
    let gate: Gate
    func projects() async throws -> [Project] { try await inner.projects() }
    func createProject(name: String) async throws -> Project { try await inner.createProject(name: name) }
    func renameProject(_ id: String, name: String) async throws -> Project { try await inner.renameProject(id, name: name) }
    func deleteProject(_ id: String) async throws { try await inner.deleteProject(id) }
    func level(_ taskId: String) async throws -> Level { try await inner.level(taskId) }
    func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary { try await inner.createTask(in: parentId, body) }
    func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level { try await inner.reorder(parentId, ids: ids, version: version) }
    func deleteTask(_ id: String) async throws -> Level { try await inner.deleteTask(id) }
    func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite { try await inner.setPrerequisite(id, done: done) }
    func notes() async throws -> [NoteSummary] { try await inner.notes() }
    func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note {
        try await inner.createNote(id: id, title: title, locale: locale, createdAt: createdAt)
    }
    func note(_ id: String) async throws -> Note { try await inner.note(id) }
    func updateNote(_ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?) async throws -> Note {
        await gate.pass()
        return try await inner.updateNote(id, title: title, durationMs: durationMs, transcript: transcript, speakers: speakers)
    }
    func deleteNote(_ id: String) async throws { try await inner.deleteNote(id) }
    func uploadTicket(note: String, segment: Int) async throws -> UploadTicket { try await inner.uploadTicket(note: note, segment: segment) }
    func completeSegment(note: String, segment: Int, durationMs: Int) async throws -> Note {
        try await inner.completeSegment(note: note, segment: segment, durationMs: durationMs)
    }
    func noteAudio(_ id: String) async throws -> AudioUrls { try await inner.noteAudio(id) }
    func extract(note: String) async throws -> Note { try await inner.extract(note: note) }
    func updateExtraction(note: String, version: Int, chains: [Chain]) async throws -> Note {
        try await inner.updateExtraction(note: note, version: version, chains: chains)
    }
    func moveTask(_ id: String, to parent: String, before: String?) async throws -> (from: Level, to: Level) {
        try await inner.moveTask(id, to: parent, before: before)
    }
    func search(_ q: String) async throws -> SearchResult { try await inner.search(q) }
    func importNote(_ id: String, parent: String, picks: [ImportPick], before: String?) async throws -> (level: Level, note: Note) {
        try await inner.importNote(id, parent: parent, picks: picks, before: before)
    }
}

@Suite struct NoteSyncRerunTests {
    @Test func syncRequestedMidPassRunsAgain() async throws {
        let (store, _) = tempStore()
        let inner = InMemoryBackend()
        let gate = Gate()
        let sync = NoteSync(store: store, backend: GatedBackend(inner: inner, gate: gate), uploader: FakeUploader())
        let unlabeled = lines.map { AlignedLine(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: nil) }
        let n = try await seed(store, segments: 1, lines: unlabeled, diarized: false)

        let first = Task { await sync.sync(n.id) }
        await gate.waitEntered() // pass 1 is sending the unlabeled transcript
        try await store.update(n.id) { $0.lines = lines; $0.diarized = true }
        await sync.sync(n.id) // asked while pass 1 runs: must not be dropped
        await gate.open()
        await first.value

        let server = try await inner.note(n.id.uuidString)
        #expect(server.transcript.map(\.speaker) == ["1", "2", "1"])
        #expect(await store.note(n.id)?.synced.diarizedSent == true)
    }
}
