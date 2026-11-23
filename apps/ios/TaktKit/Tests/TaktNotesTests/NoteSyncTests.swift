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
        let backend = InMemoryBackend()
        let up = FakeUploader(failing: true)
        let sync = NoteSync(store: store, backend: backend, uploader: up)
        let n = try await seed(store, segments: 1)
        await sync.sync(n.id)
        #expect(await store.note(n.id)?.synced.created == true)
        up.failing = false
        await sync.sync(n.id)
        #expect(try await backend.notes().count == 1)
        #expect(await store.note(n.id)?.segments[0].uploaded == true)
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
