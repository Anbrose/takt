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

/// Its model is missing until `prepare` installs it.
actor LateModelTranscriber: Transcribing {
    private var ready = false
    func isReady(locale: String) async -> Bool { ready }
    func prepare(locale: String) async throws { ready = true }
    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        [TimedText(startMs: offsetMs + 100, endMs: offsetMs + 900, text: "先去伏见稻荷")]
    }
}

/// Transcribes only once `open()` is called.
actor GatedTranscriber: Transcribing {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var started = 0
    func isReady(locale: String) async -> Bool { true }
    func prepare(locale: String) async throws {}
    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        started += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return [TimedText(startMs: offsetMs + 100, endMs: offsetMs + 900, text: "先去伏见稻荷")]
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

struct StubDiarizer: Diarizing {
    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] {
        [SpeakerTurn(speaker: "1", startMs: 0, endMs: segments.reduce(0) { $0 + $1.durationMs })]
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
    var starts = 0

    func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int, onSegment: @escaping (Int, Int) -> Void,
               onError: @escaping (Error) -> Void) throws {
        url = segmentURL; self.onSegment = onSegment; self.onError = onError; recording = true
        starts += 1
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

    init(syncBackend: InMemoryBackend? = nil, device: String = "zh_CN", supported: [String] = [],
         transcriber: any Transcribing = StubTranscriber()) {
        let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        store = NoteStore(root: root)
        let sb = syncBackend ?? backend
        self.syncBackend = sb
        model = NotesModel(
            backend: backend, store: store,
            processor: NoteProcessor(store: store, transcriber: transcriber, diarizer: StubDiarizer()),
            sync: NoteSync(store: store, backend: sb, uploader: StubUploader()),
            capture: capture, transcriber: transcriber, defaults: defaults, deviceLocale: device,
            supportedLocales: { supported })
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

/// A server note whose draft is one chain 「京都一日」 with two steps.
private func twoStepChain(_ b: InMemoryBackend) async throws -> Chain {
    try await serverNote(b, lines: [line(0, "先去伏见稻荷"), line(1, "再订旅馆")])
    let chain = Chain(
        id: UUID().uuidString, name: "京都一日",
        steps: [ChainStep(id: UUID().uuidString, name: "去伏见稻荷", quote: Quote(startMs: 0, endMs: 5800)),
                ChainStep(id: UUID().uuidString, name: "订旅馆", quote: Quote(startMs: 6000, endMs: 11800))])
    let n = try await b.note(noteId.uuidString)
    _ = try await b.updateExtraction(note: noteId.uuidString, version: n.extraction.version, chains: [chain])
    return chain
}

@MainActor
@Suite struct NotesModelTests {
    @Test func localeRemembered() {
        let r = Rig()
        r.model.locale = "en_US"
        let again = NotesModel(
            backend: r.backend, store: r.store,
            processor: NoteProcessor(store: r.store, transcriber: StubTranscriber(), diarizer: StubDiarizer()),
            sync: NoteSync(store: r.store, backend: r.backend, uploader: StubUploader()),
            capture: r.capture, defaults: r.defaults)
        #expect(again.locale == "en_US")
        #expect(r.defaults.string(forKey: "notes.locale") == "en_US")
    }

    @Test func deviceLocaleIsDefaultWhenSupported() async {
        let r = Rig(device: "ja_JP", supported: ["ja_JP", "en_US"])
        #expect(r.model.locale == "zh_CN")
        await r.model.load()
        #expect(r.model.locale == "ja_JP")
        #expect(r.defaults.string(forKey: "notes.locale") == nil)
        let unsupported = Rig(device: "fr_FR", supported: ["ja_JP"])
        await unsupported.model.load()
        #expect(unsupported.model.locale == "zh_CN")
    }

    @Test func rememberedLocaleBeatsDevice() async {
        let r = Rig(device: "ja_JP", supported: ["ja_JP"])
        r.model.locale = "en_US"
        await r.model.load()
        #expect(r.model.locale == "en_US")
    }

    @Test func loadDuringRecordingDoesNotCutItShort() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        await r.model.load()
        r.capture.onSegment?(0, 300_000)
        r.capture.stopResult = (1, 2000)
        try Data("a".utf8).write(to: r.store.segmentFileURL(id, 1))
        await r.model.stopRecording()
        let local = try #require(await r.store.note(id))
        #expect(local.segments.map(\.index) == [0, 1])
        #expect(local.recording == false)
        #expect(local.diarized)
        // Diarization ran once, after stop: the lines cover the tokens of both segments.
        #expect(local.tokens.count == 2)
        #expect(local.lines?.map(\.text).joined().components(separatedBy: "先去伏见稻荷").count == 3)
    }

    @Test func offlineLocalNoteOpensAndPlays() async throws {
        let r = Rig()
        let lines = [AlignedLine(startMs: 0, endMs: 900, text: "你好", speaker: "1"),
                     AlignedLine(startMs: 1000, endMs: 2000, text: "好", speaker: "2")]
        try await r.store.save(LocalNote(
            id: noteId, title: "t", locale: "zh_CN",
            segments: [LocalSegment(index: 0, durationMs: 4000, file: "0.m4a", transcribed: true)],
            lines: lines, diarized: true, recording: false))
        let file = r.store.segmentFileURL(noteId, 0)
        try Data("a".utf8).write(to: file)
        let d = await r.model.open(noteId)
        #expect(d.isLocalOnly)
        #expect(d.notice == nil)
        #expect(d.note?.transcript.map(\.text) == ["你好", "好"])
        #expect(d.note?.speakers.map(\.id) == ["1", "2"])
        #expect(d.note?.extraction.version == 0)
        await d.extract()
        #expect(await r.backend.calls.contains { $0.hasPrefix("extract") } == false)
        let hit = try #require(await d.audioURL(at: 1500))
        #expect(hit.0 == file)
        #expect(hit.1 == 1.5)
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

    @Test func loadListsAndSyncsBeforeProcessing() async throws {
        let t = GatedTranscriber()
        let r = Rig(transcriber: t)
        // Killed mid-recording: segment 0 listed but not transcribed yet.
        try await r.store.save(LocalNote(
            id: noteId, title: "t", locale: "zh_CN",
            segments: [LocalSegment(index: 0, durationMs: 4000, file: "0.m4a")], recording: true))
        try Data("a".utf8).write(to: r.store.segmentFileURL(noteId, 0))

        await r.model.load() // returns while transcription is still held
        #expect(r.model.items.map(\.id) == [noteId])
        #expect(try #require(await r.store.note(noteId)).recording == false)
        for _ in 0..<1000 where await t.started == 0 { await Task.yield() }
        #expect(await t.started == 1)
        #expect(try await r.backend.note(noteId.uuidString).segments.map(\.uploaded) == [true], "uploaded before transcription")

        await t.open()
        await r.model.syncTask?.value
        #expect(try #require(await r.store.note(noteId)).diarized)
        #expect(try await r.backend.note(noteId.uuidString).transcript.map(\.text) == ["先去伏见稻荷"])
        #expect(r.model.items.first?.processing == false)
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
        #expect(try await r.backend.notes().map(\.id) == [noteId.uuidString.lowercased()])
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

    @Test func importedRowsNameTheirTarget() async throws {
        let r = Rig()
        let project = try await r.backend.createProject(name: "京都")
        let level = try await r.backend.level(project.rootTaskId)
        try await serverNote(r.backend, lines: [line(0, "先去伏见稻荷"), line(6000, "我来订酒店")])
        _ = try await r.backend.extract(note: noteId.uuidString)
        let d = await r.model.open(noteId)
        let chains = try #require(d.note?.extraction.chains)
        let merged = Chain(id: chains[0].id, name: "第一天", steps: chains.flatMap(\.steps))
        await d.edit([merged])
        // Both steps go in as a group 「第一天」 at the Project's first level.
        #expect(await d.importDragged(chain: merged.id, step: nil, to: .end(parent: level.task.id)) == "京都")
        await d.loadTargets()
        let parents = Set(d.note?.imported.map(\.parentTaskId) ?? [])
        #expect(parents.count == 1)
        #expect(parents.map { d.targets[$0] } == ["京都"], "the group's level, not the group")
    }

    @Test func firstRecordingNeedsIntro() async throws {
        let r = Rig()
        #expect(r.model.introSeen == false)
        #expect(r.model.autoExtract)
        #expect(try await r.model.requestRecording() == false)
        #expect(r.model.recording == nil)

        try await r.model.finishIntro(autoExtract: false)
        #expect(r.model.recording != nil)
        #expect(r.model.introSeen && !r.model.autoExtract)
        #expect(r.defaults.bool(forKey: "notes.introSeen"))
        #expect(r.defaults.object(forKey: "notes.autoExtract") as? Bool == false)
        await r.model.stopRecording()

        #expect(try await r.model.requestRecording())
        #expect(r.model.recording != nil)
        await r.model.stopRecording()
        let again = NotesModel(
            backend: r.backend, store: r.store,
            processor: NoteProcessor(store: r.store, transcriber: StubTranscriber(), diarizer: StubDiarizer()),
            sync: NoteSync(store: r.store, backend: r.backend, uploader: StubUploader()),
            capture: r.capture, defaults: r.defaults)
        #expect(again.introSeen && !again.autoExtract)
    }

    @Test func autoExtractRunsOncePerNote() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        await r.model.stopRecording()
        await r.model.autoExtractTask?.value
        #expect(await r.backend.calls.filter { $0 == "extract \(id.uuidString.lowercased())" }.count == 1)
        #expect(r.model.items.first?.chainCount == 1)
        #expect(r.defaults.stringArray(forKey: "notes.autoPending") ?? [] == [])
        await r.model.load()
        await r.model.syncTask?.value
        await r.model.autoExtractTask?.value
        #expect(await r.backend.calls.filter { $0.hasPrefix("extract") }.count == 1)
    }

    @Test func autoExtractOffSkips() async throws {
        let r = Rig()
        r.model.autoExtract = false
        try await r.model.startRecording()
        await r.model.stopRecording()
        await r.model.autoExtractTask?.value
        await r.model.load()
        await r.model.syncTask?.value
        await r.model.autoExtractTask?.value
        #expect(await r.backend.calls.contains { $0.hasPrefix("extract") } == false)
        #expect(r.defaults.stringArray(forKey: "notes.autoPending") ?? [] == [])
        #expect(r.model.items.first?.chainCount == 0)
    }

    @Test func autoExtractFailureNotRetried() async throws {
        let r = Rig()
        await r.backend.failNextExtract(with: "llm_failed", status: 502)
        try await r.model.startRecording()
        await r.model.stopRecording()
        await r.model.autoExtractTask?.value
        #expect(await r.backend.calls.filter { $0.hasPrefix("extract") }.count == 1)
        #expect(r.model.notice == nil)
        await r.model.load()
        await r.model.syncTask?.value
        await r.model.autoExtractTask?.value
        #expect(await r.backend.calls.filter { $0.hasPrefix("extract") }.count == 1)
        #expect(r.model.items.first?.chainCount == 0)
    }

    @Test func autoExtractDoesNotHoldUpTheList() async throws {
        let r = Rig()
        let (gate, open) = AsyncStream<Void>.makeStream()
        await r.backend.delayExtract { for await _ in gate { return } }
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        await r.model.stopRecording()
        // stop (and the refresh after it) returned while the extract call is still waiting.
        #expect(r.model.items.first?.id == id)
        #expect(r.model.items.first?.processing == false)
        #expect(r.model.items.first?.chainCount == 0)
        for _ in 0..<1000 where await !r.backend.calls.contains("extract \(id.uuidString.lowercased())") { await Task.yield() }
        #expect(r.model.autoExtracting == [id], "the detail's spinner shows while the call runs")
        open.yield()
        open.finish()
        await r.model.autoExtractTask?.value
        #expect(r.model.items.first?.chainCount == 1)
        #expect(r.model.autoExtracting.isEmpty)
    }

    @Test func missingModelDownloadsThenTranscribes() async throws {
        let t = LateModelTranscriber()
        let r = Rig(transcriber: t)
        let note = LocalNote(
            id: noteId, title: "t", locale: "ja_JP",
            segments: [LocalSegment(index: 0, durationMs: 2000, file: "0.m4a")], recording: false)
        try await r.store.save(note)
        try Data("a".utf8).write(to: r.store.segmentFileURL(noteId, 0))
        await r.model.checkInstalled(["ja_JP"])
        #expect(r.model.installed.isEmpty)
        await r.model.prepare("ja_JP")
        #expect(r.model.installed == ["ja_JP"])
        #expect(r.model.preparing.isEmpty)
        let local = try #require(await r.store.note(noteId))
        #expect(local.diarized)
        #expect(try await r.backend.note(noteId.uuidString).transcript.map(\.text) == ["先去伏见稻荷"])
    }

    @Test func localeChosenWhileRecordingAppliesToThatNote() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        await r.model.chooseLocale("ja_JP")
        #expect(r.model.locale == "ja_JP")
        #expect(r.model.items.first?.locale == "ja_JP")
        await r.model.stopRecording()
        #expect(try await r.backend.note(id.uuidString).locale == "ja_JP")
    }

    @Test func doubleTapStartsOneRecording() async throws {
        let r = Rig()
        async let a: Void = r.model.startRecording()
        async let b: Void = r.model.startRecording()
        _ = try await (a, b)
        let id = try #require(r.model.recording?.id)
        #expect(r.capture.starts == 1)
        #expect(await r.store.all().map(\.id) == [id])
        await r.model.stopRecording()
        #expect(try #require(await r.store.note(id)).recording == false)
    }

    @Test func titleIsLocalStartTime() async throws {
        let at = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 11:06:40 UTC
        #expect(NotesModel.defaultTitle(at, timeZone: TimeZone(identifier: "Australia/Sydney")!) == "11-18 22:06")
        #expect(NotesModel.defaultTitle(at, timeZone: TimeZone(identifier: "UTC")!) == "11-18 11:06")
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        let local = try #require(await r.store.note(id))
        #expect(local.title == NotesModel.defaultTitle(local.createdAt))
        #expect(r.model.items.first?.title == local.title)
        await r.model.stopRecording()
        #expect(try await r.backend.note(id.uuidString).title == local.title)
    }

    @Test func resumeWaitsWhileRecording() async throws {
        let r = Rig()
        try await r.model.startRecording()
        let id = try #require(r.model.recording?.id)
        await r.model.resume()
        #expect(try #require(await r.store.note(id)).recording)
        await r.model.stopRecording()
    }

    @Test func importDraggedStepBefore() async throws {
        let r = Rig()
        let project = try await r.backend.createProject(name: "京都")
        await r.backend.add(parent: project.rootTaskId, name: "A")
        let b = await r.backend.add(parent: project.rootTaskId, name: "B")
        let chain = try await twoStepChain(r.backend)
        let d = await r.model.open(noteId)
        let name = await d.importDragged(chain: chain.id, step: chain.steps[1].id, to: .before(parent: project.rootTaskId, task: b))
        #expect(name == "京都")
        #expect(d.notice == nil)
        #expect(try await r.backend.level(project.rootTaskId).children.map(\.name) == ["A", "订旅馆", "B"])
        #expect(d.note?.extraction.chains.first?.steps.map(\.name) == ["去伏见稻荷"])
        #expect(d.note?.imported.map(\.stepName) == ["订旅馆"])
    }

    @Test func importDraggedChainInto() async throws {
        let r = Rig()
        let project = try await r.backend.createProject(name: "京都")
        let a = await r.backend.add(parent: project.rootTaskId, name: "A")
        let chain = try await twoStepChain(r.backend)
        let d = await r.model.open(noteId)
        #expect(await d.importDragged(chain: chain.id, step: nil, to: .into(task: a)) == "A")
        let inA = try await r.backend.level(a)
        #expect(inA.children.map(\.name) == ["京都一日"])
        #expect(try await r.backend.level(inA.children[0].id).children.map(\.name) == ["去伏见稻荷", "订旅馆"])
        #expect(d.note?.extraction.chains.isEmpty == true)
        // The chain is gone from the draft now: dragging it again writes nothing.
        #expect(await d.importDragged(chain: chain.id, step: nil, to: .end(parent: project.rootTaskId)) == nil)
        #expect(try await r.backend.level(project.rootTaskId).children.map(\.name) == ["A"])
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
