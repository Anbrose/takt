import AVFoundation
import Foundation
import Testing
import TaktCore
@testable import TaktNotes

/// Returns two tokens per segment at fixed segment-local times; readiness can be flipped.
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _ready: Bool
    private var _calls: [(file: String, offsetMs: Int)] = []
    init(ready: Bool = true) { _ready = ready }

    var ready: Bool {
        get { lock.withLock { _ready } }
        set { lock.withLock { _ready = newValue } }
    }
    var calls: [(file: String, offsetMs: Int)] { lock.withLock { _calls } }

    func isReady(locale: String) async -> Bool { ready }
    func prepare(locale: String) async throws { ready = true }
    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        let name = file.deletingPathExtension().lastPathComponent
        lock.withLock { _calls.append((name, offsetMs)) }
        return [
            TimedText(startMs: offsetMs + 100, endMs: offsetMs + 500, text: "s\(name)a"),
            TimedText(startMs: offsetMs + 600, endMs: offsetMs + 900, text: "s\(name)b"),
        ]
    }
}

struct DiarizeFailed: Error {}

/// Its models can't be downloaded (offline).
struct OfflineDiarizer: Diarizing {
    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] { throw DiarizationError.modelsUnavailable }
}

/// Throws for the first `failures` calls (nil: always), then returns `result`.
final class FakeDiarizer: Diarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[SegmentAudio]] = []
    let result: [SpeakerTurn]
    let failures: Int?
    init(_ result: [SpeakerTurn], failures: Int? = 0) { self.result = result; self.failures = failures }
    var calls: [[SegmentAudio]] { lock.withLock { _calls } }

    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] {
        let n = lock.withLock { _calls.append(segments); return _calls.count }
        if let failures, n > failures { return result }
        throw DiarizeFailed()
    }
}


/// A PCM `.caf` as a kill leaves it: copied while the writer still has it open (no final header update),
/// then cut mid-sample. Holds `seconds` of a tone, minus the cut.
func killedRecording(at url: URL, seconds: Double, cutBytes: Int = 1001) throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "rec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let open = dir.appending(path: "open.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    var writer: AVAudioFile? = try AVAudioFile(
        forWriting: open, settings: SegmentFile.pcmSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * 16000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
    try writer!.write(from: buffer)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.copyItem(at: open, to: url)
    writer = nil
    let data = try Data(contentsOf: url)
    try data.prefix(data.count - cutBytes).write(to: url)
}

private let turns = [SpeakerTurn(speaker: "1", startMs: 0, endMs: 950), SpeakerTurn(speaker: "2", startMs: 1000, endMs: 3000)]

private func note(segments: Int, recording: Bool) -> LocalNote {
    LocalNote(
        locale: "zh-CN",
        segments: (0..<segments).map { LocalSegment(index: $0, durationMs: 1000, file: "\($0).m4a") },
        recording: recording)
}

@Suite struct NoteProcessorTests {
    @Test func transcribesSegmentsWithOffsets() async throws {
        let (store, _) = tempStore()
        var n = note(segments: 2, recording: true)
        n.segments[0].durationMs = 300_000
        try await store.save(n)
        let t = FakeTranscriber()
        await NoteProcessor(store: store, transcriber: t, diarizer: FakeDiarizer(turns)).process(n.id)

        let saved = try #require(await store.note(n.id))
        #expect(t.calls.map(\.offsetMs) == [0, 300_000])
        #expect(saved.tokens.map(\.startMs) == [100, 600, 300_100, 300_600])
        #expect(saved.tokens.map(\.text) == ["s0a", "s0b", "s1a", "s1b"])
        #expect(saved.segments.allSatisfy { $0.transcribed })
    }

    @Test func queuesTranscriptionUntilModelReady() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 2, recording: false)
        try await store.save(n)
        let t = FakeTranscriber(ready: false)
        let d = FakeDiarizer(turns)
        let processor = NoteProcessor(store: store, transcriber: t, diarizer: d)

        await processor.process(n.id)
        var saved = try #require(await store.note(n.id))
        #expect(t.calls.isEmpty)
        #expect(d.calls.isEmpty)
        #expect(saved == n)

        t.ready = true
        await processor.process(n.id)
        saved = try #require(await store.note(n.id))
        #expect(saved.segments.allSatisfy { $0.transcribed })
        #expect(saved.tokens.count == 4)
        #expect(saved.lines != nil)
    }

    @Test func diarizesOnceAfterStop() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 2, recording: true)
        try await store.save(n)
        let d = FakeDiarizer(turns)
        let processor = NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: d)

        await processor.process(n.id)
        #expect(await store.note(n.id)?.lines == nil)
        #expect(d.calls.isEmpty)

        try await store.update(n.id) { $0.recording = false }
        await processor.process(n.id)
        await processor.process(n.id)

        let saved = try #require(await store.note(n.id))
        #expect(d.calls.count == 1)
        let audio = [SegmentAudio(file: await store.segmentURL(n.id, 0), durationMs: 1000),
                     SegmentAudio(file: await store.segmentURL(n.id, 1), durationMs: 1000)]
        #expect(d.calls.first == audio)
        #expect(saved.diarized)
        #expect(saved.lines == SpeakerAlign.align(saved.tokens, turns))
        #expect(saved.lines?.map(\.speaker) == ["1", "2"])
    }

    @Test func diarizationFailureKeepsUnlabeledLines() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 1, recording: false)
        try await store.save(n)
        await NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: FakeDiarizer(turns, failures: nil)).process(n.id)

        let saved = try #require(await store.note(n.id))
        let lines = try #require(saved.lines)
        #expect(lines.map(\.text) == ["s0as0b"])
        #expect(lines.allSatisfy { $0.speaker == nil })
        #expect(!saved.diarized)
    }

    @Test func retriesDiarizationAfterFailure() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 1, recording: false)
        try await store.save(n)
        let d = FakeDiarizer(turns, failures: 1)
        let processor = NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: d)

        await processor.process(n.id)
        #expect(await store.note(n.id)?.lines?.map(\.speaker) == [nil])

        await processor.process(n.id)
        await processor.process(n.id)
        let saved = try #require(await store.note(n.id))
        #expect(d.calls.count == 2)
        #expect(saved.diarized)
        #expect(saved.lines == SpeakerAlign.align(saved.tokens, turns))
        #expect(saved.lines?.map(\.speaker) == ["1"])
    }

    @Test func stopsRetryingDiarizationAfterTheCap() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 1, recording: false)
        try await store.save(n)
        let d = FakeDiarizer(turns, failures: nil)
        let processor = NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: d)
        for _ in 0..<5 { await processor.process(n.id) }
        await processor.recoverAfterLaunch()

        let saved = try #require(await store.note(n.id))
        #expect(d.calls.count == LocalNote.maxDiarizeAttempts)
        #expect(saved.diarizeAttempts == LocalNote.maxDiarizeAttempts)
        #expect(!saved.diarized && saved.diarizationSettled)
        #expect(saved.lines?.map(\.speaker) == [nil], "the transcript stays, without speakers")
    }

    @Test func missingDiarizerModelsDoNotUseUpAttempts() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 1, recording: false)
        try await store.save(n)
        let processor = NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: OfflineDiarizer())
        for _ in 0..<5 { await processor.process(n.id) }
        let saved = try #require(await store.note(n.id))
        #expect(saved.diarizeAttempts == 0)
        #expect(!saved.diarizationSettled)
    }

    @Test func recoversNoteKilledMidRecording() async throws {
        let (store, root) = tempStore()
        var n = note(segments: 2, recording: true)
        n.segments[0].transcribed = true
        n.segments[1].transcribed = true
        n.tokens = [TimedText(startMs: 100, endMs: 500, text: "s0a"), TimedText(startMs: 1100, endMs: 1500, text: "s1a")]
        try await store.save(n)
        let finished = LocalNote(locale: "zh-CN", recording: false)
        try await store.save(finished)

        let d = FakeDiarizer(turns)
        let processor = NoteProcessor(store: NoteStore(root: root), transcriber: FakeTranscriber(), diarizer: d)
        await processor.recoverAfterLaunch()
        await processor.recoverAfterLaunch()

        let saved = try #require(await store.note(n.id))
        #expect(!saved.recording)
        #expect(saved.segments.map(\.index) == [0, 1])
        #expect(d.calls.count == 1)
        #expect(saved.diarized)
        #expect(saved.lines?.map(\.speaker) == ["1", "2"])
    }

    @Test func recoversTheSegmentAKillCutOff() async throws {
        let (store, root) = tempStore()
        var n = note(segments: 1, recording: true)
        n.segments[0].transcribed = true
        n.tokens = [TimedText(startMs: 100, endMs: 500, text: "s0a")]
        try await store.save(n)
        // Killed 2 s into segment 1: only its recording file is there, unlisted and never closed.
        let recording = SegmentFile.recordingURL(for: await store.segmentURL(n.id, 1))
        try killedRecording(at: recording, seconds: 2)

        let t = FakeTranscriber()
        let relaunched = NoteStore(root: root)
        await NoteProcessor(store: relaunched, transcriber: t, diarizer: FakeDiarizer(turns)).recoverAfterLaunch()

        let saved = try #require(await relaunched.note(n.id))
        #expect(!saved.recording)
        #expect(saved.segments.map(\.index) == [0, 1])
        let ms = saved.segments[1].durationMs
        #expect((1900...2000).contains(ms), "all but the cut-off tail: \(ms) ms")
        #expect(t.calls.map(\.file) == ["1"])
        #expect(t.calls.map(\.offsetMs) == [1000])
        #expect(saved.diarized)
        #expect(FileManager.default.fileExists(atPath: recording.path) == false)
        let encoded = try #require(SegmentFile.durationMs(await store.segmentURL(n.id, 1)))
        #expect(abs(encoded - ms) < 100, "the .m4a holds the recovered audio")
    }

    @Test func recoversASegmentEncodedButNotListed() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 1, recording: true)
        try await store.save(n)
        // Killed after segment 1 was encoded (and its recording removed) but before it was listed.
        let segment = await store.segmentURL(n.id, 1)
        let recording = SegmentFile.recordingURL(for: segment)
        try killedRecording(at: recording, seconds: 1, cutBytes: 0)
        try SegmentFile.encode(recording, to: segment)
        // A half-written encode from the same kill is thrown away.
        try Data("x".utf8).write(to: segment.deletingPathExtension().appendingPathExtension("part.m4a"))

        await NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: FakeDiarizer(turns)).recoverAfterLaunch()

        let saved = try #require(await store.note(n.id))
        #expect(saved.segments.map(\.index) == [0, 1])
        #expect((950...1050).contains(saved.segments[1].durationMs))
        let part = segment.deletingPathExtension().appendingPathExtension("part.m4a")
        #expect(FileManager.default.fileExists(atPath: part.path) == false)
    }

    @Test func recoveryLeavesTheLiveRecordingAlone() async throws {
        let (store, _) = tempStore()
        let n = note(segments: 0, recording: true)
        try await store.save(n)
        let recording = SegmentFile.recordingURL(for: await store.segmentURL(n.id, 0))
        try killedRecording(at: recording, seconds: 1)
        let processor = NoteProcessor(store: store, transcriber: FakeTranscriber(), diarizer: FakeDiarizer(turns))
        await processor.recordingStarted(n.id)
        await processor.recoverAfterLaunch()
        #expect(try #require(await store.note(n.id)).recording)
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }

    @Test func encodingKeepsTheLengthAndRemovesTheRecording() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "enc-\(UUID().uuidString)")
        let recording = dir.appending(path: "0.caf"), segment = dir.appending(path: "0.m4a")
        try killedRecording(at: recording, seconds: 3, cutBytes: 0)
        let ms = try SegmentFile.encode(recording, to: segment)
        #expect(ms == 3000)
        #expect(FileManager.default.fileExists(atPath: recording.path) == false)
        let encoded = try #require(SegmentFile.durationMs(segment))
        #expect(abs(encoded - 3000) < 100)
        let file = try AVAudioFile(forReading: segment)
        #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
    }

    @Test func resumesAfterRelaunch() async throws {
        let (store, root) = tempStore()
        // Killed after segment 0 was transcribed and recording had stopped.
        var n = note(segments: 2, recording: false)
        n.segments[0].transcribed = true
        n.tokens = [TimedText(startMs: 100, endMs: 500, text: "s0a"), TimedText(startMs: 600, endMs: 900, text: "s0b")]
        try await store.save(n)

        let relaunched = NoteStore(root: root)
        let t = FakeTranscriber()
        let d = FakeDiarizer(turns)
        await NoteProcessor(store: relaunched, transcriber: t, diarizer: d).process(n.id)

        let saved = try #require(await relaunched.note(n.id))
        #expect(t.calls.map(\.file) == ["1"])
        #expect(saved.tokens.map(\.text) == ["s0a", "s0b", "s1a", "s1b"])
        #expect(d.calls.count == 1)
        #expect(saved.lines == SpeakerAlign.align(saved.tokens, turns))
    }
}

@Suite struct FluidDiarizerTests {
    @Test func fitsSamplesToRecordedDuration() {
        #expect(FluidDiarizer.fit([1, 1, 1], durationMs: 1).count == 16)
        #expect(FluidDiarizer.fit([1, 1, 1], durationMs: 1) == [1, 1, 1] + [Float](repeating: 0, count: 13))
        #expect(FluidDiarizer.fit([Float](repeating: 1, count: 20), durationMs: 1) == [Float](repeating: 1, count: 16))
        #expect(FluidDiarizer.fit([], durationMs: 2) == [Float](repeating: 0, count: 32))
        #expect(FluidDiarizer.fit([1], durationMs: 0).isEmpty)
    }

    @Test func renumbersSpeakersByFirstAppearance() {
        let turns = FluidDiarizer.renumber([
            (id: "S3", startMs: 2000, endMs: 3000), (id: "S1", startMs: 0, endMs: 1000),
            (id: "S3", startMs: 4000, endMs: 5000), (id: "S2", startMs: 6000, endMs: 7000),
        ])
        #expect(turns.map(\.speaker) == ["1", "2", "2", "3"])
        #expect(turns.map(\.startMs) == [0, 2000, 4000, 6000])
    }
}
