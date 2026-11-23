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
