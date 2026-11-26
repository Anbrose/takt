import Foundation
import TaktCore

/// Turns recorded segments into a transcript: transcribe each segment once its model is ready,
/// then — after recording stopped — diarize the whole recording once and align.
/// All progress is saved after every step, so a relaunch continues where it stopped.
public actor NoteProcessor {
    private let store: NoteStore
    private let transcriber: Transcribing
    private let diarizer: Diarizing
    /// Notes being processed, and whether another call asked for a rerun meanwhile.
    private var running: [UUID: Bool] = [:]

    public init(store: NoteStore, transcriber: Transcribing, diarizer: Diarizing) {
        self.store = store; self.transcriber = transcriber; self.diarizer = diarizer
    }

    /// Transcribes every untranscribed segment (in order) whose model is ready; after recording stopped and all
    /// segments are transcribed, diarizes once and sets `lines`. Safe to call repeatedly (relaunch, model ready, network back).
    public func process(_ id: UUID) async {
        if running[id] != nil {
            running[id] = true
            return
        }
        running[id] = false
        repeat {
            running[id] = false
            await step(id)
        } while running[id] == true
        running[id] = nil
    }

    private func step(_ id: UUID) async {
        guard var note = await store.note(id) else { return }
        if note.segments.contains(where: { !$0.transcribed }) {
            if await !transcriber.supports(locale: note.locale) {
                // This device can't transcribe this language: the note keeps its audio and an empty transcript.
                guard let saved = try? await store.update(id, { n in
                    for i in n.segments.indices { n.segments[i].transcribed = true }
                }) else { return }
                note = saved
            } else {
                guard await transcriber.isReady(locale: note.locale) else { return }
                for segment in note.segments.sorted(by: { $0.index < $1.index }) where !segment.transcribed {
                    if let saved = await transcribe(id, segment, of: note) { note = saved }
                }
            }
        }
        guard !note.recording, !note.diarizationSettled, note.segments.allSatisfy(\.transcribed) else { return }
        if note.tokens.isEmpty {
            // Nothing was recognised (silence, or a language this device can't do): nothing to label.
            _ = try? await store.update(id) { n in
                n.lines = []
                n.diarized = true
            }
            return
        }

        var audio: [SegmentAudio] = []
        for segment in note.segments.sorted(by: { $0.index < $1.index }) {
            audio.append(SegmentAudio(file: await store.segmentURL(id, segment.index), durationMs: segment.durationMs))
        }
        // Counted before the run, so a run the app is killed in (memory, on a long recording) counts as well.
        guard (try? await store.update(id, { $0.diarizeAttempts += 1 })) != nil else { return }
        // Failure (e.g. offline before the models are downloaded): show unlabeled lines, retry on a later call.
        var turns: [SpeakerTurn]?
        var uncounted = false
        if audio.isEmpty {
            turns = []
        } else {
            do { turns = try await diarizer.turns(for: audio) } catch {
                uncounted = (error as? DiarizationError) == .modelsUnavailable
            }
        }
        let result = turns, refund = uncounted
        _ = try? await store.update(id) { n in
            if refund { n.diarizeAttempts -= 1 }
            guard !n.diarized else { return }
            if let turns = result {
                n.lines = SpeakerAlign.align(n.tokens, turns)
                n.diarized = true
            } else if n.lines == nil {
                n.lines = SpeakerAlign.align(n.tokens, [])
            }
        }
    }

    /// One segment's transcription, counted before it starts (a run the app is killed in counts too). A segment
    /// that fails stays untranscribed and is retried on a later call; later segments go on meanwhile (tokens are
    /// kept in time order). After `LocalSegment.maxAttempts` it is given up on, without tokens, so it never holds
    /// back diarization. Returns the saved note, nil when nothing changed.
    private func transcribe(_ id: UUID, _ segment: LocalSegment, of note: LocalNote) async -> LocalNote? {
        let index = segment.index
        let giveUp: @Sendable (inout LocalNote) -> Void = { n in
            if let i = n.segments.firstIndex(where: { $0.index == index }) { n.segments[i].transcribed = true }
        }
        // Runs the app was killed in used the attempts up.
        guard segment.attempts < LocalSegment.maxAttempts else { return try? await store.update(id, giveUp) }
        guard (try? await store.update(id, { n in
            if let i = n.segments.firstIndex(where: { $0.index == index }) { n.segments[i].attempts += 1 }
        })) != nil else { return nil }
        let offset = note.segments.filter { $0.index < index }.reduce(0) { $0 + $1.durationMs }
        let url = await store.segmentURL(id, index)
        guard let tokens = try? await transcriber.transcribe(url, locale: note.locale, offsetMs: offset) else {
            guard segment.attempts + 1 >= LocalSegment.maxAttempts else { return nil }
            return try? await store.update(id, giveUp)
        }
        return try? await store.update(id) { n in
            guard let i = n.segments.firstIndex(where: { $0.index == index }), !n.segments[i].transcribed else { return }
            n.tokens += tokens
            if tokens.first.map({ t in n.tokens.contains { $0.startMs > t.startMs } }) == true {
                n.tokens.sort { $0.startMs < $1.startMs }  // an earlier segment that failed before came through
            }
            n.segments[i].transcribed = true
        }
    }

    /// The note being recorded now: recovery leaves it (and the file it is writing) alone.
    private var live: UUID?

    public func recordingStarted(_ id: UUID) { live = id }
    public func recordingEnded(_ id: UUID) { if live == id { live = nil } }

    /// Call at launch (and when the network returns): `recoverInterrupted()`, then `processPending()`.
    public func recoverAfterLaunch() async {
        await recoverInterrupted()
        await processPending()
    }

    /// A note still marked recording was cut off by the app being killed. Its segment in progress is recovered
    /// from its `.caf` up to the last buffer written (so at most a few seconds are lost) and the note is marked
    /// stopped. Quick: only reads the folders and encodes what a kill cut off; the list can wait for it.
    public func recoverInterrupted() async {
        for note in await store.all() where note.id != live {
            let found = await store.recoverSegments(note.id, listed: Set(note.segments.map(\.index)))
            guard note.recording || !found.isEmpty, note.id != live else { continue }
            _ = try? await store.update(note.id) { n in
                n.recording = false
                n.segments.removeAll { $0.durationMs <= 0 }
                let known = Set(n.segments.map(\.index))
                n.segments += found.filter { !known.contains($0.index) }
                n.segments.sort { $0.index < $1.index }
                if !found.isEmpty, n.lines != nil {
                    // Found after the note was finished: the transcript is redone with the new audio.
                    n.lines = nil
                    n.diarized = false
                    n.diarizeAttempts = 0
                    n.synced.transcriptSent = false
                    n.synced.diarizedSent = false
                }
            }
        }
    }

    /// Transcribes and diarizes every note with work left. Slow (minutes for a long recording): run it in the
    /// background, never in front of the list.
    public func processPending() async {
        for note in await store.all() where !note.diarizationSettled && note.id != live {
            await process(note.id)
        }
    }
}
