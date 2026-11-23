import Foundation
import Testing
import TaktAPI
import TaktCore
import TaktNotes
@testable import TaktUI

private let noteId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

final class StubTranscriber: Transcribing, @unchecked Sendable {
    func isReady(locale: String) async -> Bool { true }
    func prepare(locale: String) async throws {}
    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        [TimedText(startMs: offsetMs + 100, endMs: offsetMs + 900, text: "先去伏见稻荷")]
    }
}

struct StubDiarizer: Diarizing {
    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] {
        [SpeakerTurn(speaker: "1", startMs: 0, endMs: 5000)]
    }
}

struct StubUploader: SegmentUploading {
    func upload(_ file: URL, to sessionURL: URL) async throws {}
}

/// Records nothing; writes a file for the segment it "closes" on stop.
@MainActor
final class FakeCapture: AudioCapture {
    var url: ((Int) -> URL)?
    var onSegment: ((Int, Int) -> Void)?
    var onError: ((Error) -> Void)?
    var recording = false
    var stopResult: (index: Int, durationMs: Int)? = (0, 2000)

    func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int, onSegment: @escaping (Int, Int) -> Void,
               onError: @escaping (Error) -> Void) throws {
        url = segmentURL; self.onSegment = onSegment; self.onError = onError; recording = true
        try Data("a".utf8).write(to: segmentURL(0))
    }

    func stop() async -> (index: Int, durationMs: Int)? {
        defer { recording = false }
        return recording ? stopResult : nil
    }
}

@MainActor
private struct Rig {
    let backend = InMemoryBackend()
    let syncBackend: InMemoryBackend
    let store: NoteStore
    let capture = FakeCapture()
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let model: NotesModel

    init(syncBackend: InMemoryBackend? = nil) {
        let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        store = NoteStore(root: root)
        let sb = syncBackend ?? backend
        self.syncBackend = sb
        model = NotesModel(
            backend: backend, store: store,
            processor: NoteProcessor(store: store, transcriber: StubTranscriber(), diarizer: StubDiarizer()),
            sync: NoteSync(store: store, backend: sb, uploader: StubUploader()),
            capture: capture, defaults: defaults)
    }

    func detail(_ id: UUID = noteId) -> NoteDetailModel {
        NoteDetailModel(id: id, backend: backend, store: store)
    }
}

private func line(_ i: Int, _ text: String) -> TranscriptLine {
    TranscriptLine(startMs: i * 6000, endMs: i * 6000 + 5800, text: text, speaker: "1")
}

private func serverNote(_ b: InMemoryBackend, lines: [TranscriptLine]? = nil) async throws {
    _ = try await b.createNote(id: noteId.uuidString, title: nil, locale: "zh-CN", createdAt: Date())
    if let lines {
        _ = try await b.updateNote(
            noteId.uuidString, title: nil, durationMs: nil, transcript: lines,
            speakers: [Speaker(id: "1", name: "1"), Speaker(id: "2", name: "2")])
    }
}

@MainActor
@Suite struct NotesModelTests {
    @Test func localeRemembered() {
        let r = Rig()
        r.model.locale = "en-US"
        let again = NotesModel(
            backend: r.backend, store: r.store,
            processor: NoteProcessor(store: r.store, transcriber: StubTranscriber(), diarizer: StubDiarizer()),
            sync: NoteSync(store: r.store, backend: r.backend, uploader: StubUploader()),
            capture: r.capture, defaults: r.defaults)
        #expect(again.locale == "en-US")
        #expect(r.defaults.string(forKey: "notes.locale") == "en-US")
    }

    @Test func demoNoteIdIsUUID() async throws {
        let list = try await InMemoryBackend.sample().notes()
        #expect(list.contains { UUID(uuidString: $0.id) != nil })
        #expect(list.allSatisfy { UUID(uuidString: $0.id) != nil })
    }

    @Test func stopRecordingProcessesAndSyncs() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        #expect(r.model.items.first?.id == id)
        #expect(r.model.items.first?.processing == true)

        await r.model.stopRecording()
        #expect(r.model.recording == nil)
        let local = try #require(await r.store.note(id))
        #expect(local.recording == false)
        #expect(local.diarized)
        #expect(local.segments.map(\.durationMs) == [2000])
        let server = try await r.backend.note(id.uuidString)
        #expect(server.transcript.map(\.text) == ["先去伏见稻荷"])
        #expect(server.segments.map(\.uploaded) == [true])
        #expect(r.model.items.map(\.id) == [id])
        #expect(r.model.items.first?.processing == false)
    }

    @Test func recorderErrorKeepsFinishedSegments() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        r.capture.onSegment?(0, 300_000)
        r.capture.recording = false // the recorder ended itself
        r.capture.onError?(RecorderError.couldNotStart)
        #expect(r.model.recording == nil)
        #expect(r.model.notice == "录音中断")
        await r.model.finishPendingWork()
        let local = try #require(await r.store.note(id))
        #expect(local.recording == false)
        #expect(local.segments.map(\.durationMs) == [300_000])
    }

    @Test func localOnlyNoteListedBeforeSync() async throws {
        let offline = InMemoryBackend()
        let r = Rig(syncBackend: offline)
        await offline.failNextCall(with: URLError(.notConnectedToInternet))
        let local = LocalNote(
            id: noteId, title: "京都", locale: "zh-CN", segments: [LocalSegment(index: 0, durationMs: 4000, file: "0.m4a", transcribed: true)],
            recording: false)
        try await r.store.save(local)
        await r.model.load()
        let item = try #require(r.model.items.first)
        #expect(r.model.items.count == 1)
        #expect(item.id == noteId)
        #expect(item.durationMs == 4000)
        #expect(item.processing)
    }

    @Test func serverNotesMergeNewestFirstAndDelete() async throws {
        let r = Rig()
        _ = try await r.backend.createNote(id: noteId.uuidString, title: "a", locale: "zh-CN", createdAt: Date(timeIntervalSince1970: 100))
        let other = UUID()
        _ = try await r.backend.createNote(id: other.uuidString, title: "b", locale: "zh-CN", createdAt: Date(timeIntervalSince1970: 200))
        await r.model.load()
        await r.model.syncTask?.value
        #expect(r.model.items.map(\.id) == [other, noteId])

        await r.backend.failNextCall(with: URLError(.timedOut))
        await r.model.delete(other)
        #expect(r.model.items.map(\.id) == [other, noteId])
        #expect(r.model.notice == "删除失败")

        await r.model.delete(other)
        #expect(r.model.items.map(\.id) == [noteId])
        #expect(try await r.backend.notes().map(\.id) == [noteId.uuidString])
    }

    @Test func extractLimitShowsNotice() async throws {
        let r = Rig()
        try await serverNote(r.backend, lines: [line(0, "先去伏见稻荷")])
        let d = await r.model.open(noteId)
        await r.backend.failNextExtract(with: "extract_limit", status: 429)
        await d.extract()
        #expect(d.notice == "已达上限")
        await r.backend.failNextExtract(with: "llm_failed", status: 502)
        await d.extract()
        #expect(d.notice == "提取失败")
        await d.extract()
        #expect(d.note?.extraction.chains.count == 1)
    }

    @Test func extractOnEmptyTranscriptIsSilent() async throws {
        let r = Rig()
        try await serverNote(r.backend)
        let d = await r.model.open(noteId)
        await d.extract()
        #expect(d.notice == nil)
    }

    @Test func staleImportReloads() async throws {
        let r = Rig()
        let project = try await r.backend.createProject(name: "京都")
        try await serverNote(r.backend, lines: [line(0, "先去伏见稻荷")])
        _ = try await r.backend.extract(note: noteId.uuidString)
        let d = await r.model.open(noteId)
        let chain = try #require(d.note?.extraction.chains.first)
        let step = try #require(chain.steps.first)

        // Another device re-extracted: the chain and step ids this screen shows are gone.
        _ = try await r.backend.updateExtraction(
            note: noteId.uuidString, version: d.note!.extraction.version,
            chains: [Chain(id: "00000000-0000-4000-8000-0000000000aa", name: "x", steps: [])])
        let ok = await d.importPicks([ImportPick(chainId: chain.id, stepIds: [step.id], places: nil)], into: project.rootTaskId)
        #expect(ok == false)
        #expect(d.notice == "已在别处修改")
        #expect(d.note?.extraction.chains.map(\.name) == ["x"])
        #expect(try await r.backend.level(project.rootTaskId).children.isEmpty)
    }

    @Test func editConflictReloads() async throws {
        let r = Rig()
        try await serverNote(r.backend, lines: [line(0, "先去伏见稻荷")])
        _ = try await r.backend.extract(note: noteId.uuidString)
        let d = await r.model.open(noteId)
        _ = try await r.backend.updateExtraction(note: noteId.uuidString, version: d.note!.extraction.version, chains: [])
        await d.edit([])
        #expect(d.notice == "已在别处修改")
        #expect(d.note?.extraction.version == 2)
    }

    @Test func renameSpeakerChangesOnlyThatName() async throws {
        let r = Rig()
        try await serverNote(r.backend, lines: [line(0, "x")])
        let d = await r.model.open(noteId)
        await d.renameSpeaker("2", to: "小林")
        #expect(d.note?.speakers == [Speaker(id: "1", name: "1"), Speaker(id: "2", name: "小林")])
    }

    @Test func audioURLPicksSegmentAndOffset() async throws {
        let r = Rig()
        try await serverNote(r.backend)
        for i in 0..<3 {
            _ = try await r.backend.uploadTicket(note: noteId.uuidString, segment: i)
            _ = try await r.backend.completeSegment(note: noteId.uuidString, segment: i, durationMs: 300_000)
        }
        let d = await r.model.open(noteId)
        let hit = try #require(await d.audioURL(at: 310_000))
        #expect(hit.0.absoluteString == "memory://notes/\(noteId.uuidString)/1.m4a")
        #expect(hit.1 == 10)
        let first = try #require(await d.audioURL(at: 0))
        #expect(first.0.lastPathComponent == "0.m4a")
        let past = try #require(await d.audioURL(at: 9_000_000))
        #expect(past.0.lastPathComponent == "2.m4a")
        #expect(past.1 == 300)
    }

    @Test func audioURLPrefersLocalFile() async throws {
        let r = Rig()
        try await serverNote(r.backend)
        _ = try await r.backend.uploadTicket(note: noteId.uuidString, segment: 0)
        _ = try await r.backend.completeSegment(note: noteId.uuidString, segment: 0, durationMs: 300_000)
        let d = await r.model.open(noteId)
        let local = r.store.segmentFileURL(noteId, 0)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: local)
        let hit = try #require(await d.audioURL(at: 5_000))
        #expect(hit.0 == local)
    }
}
