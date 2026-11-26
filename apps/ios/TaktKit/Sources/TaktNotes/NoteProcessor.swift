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
            guard await transcriber.isReady(locale: note.locale) else { return }
            for segment in note.segments.sorted(by: { $0.index < $1.index }) where !segment.transcribed {
                let offset = note.segments.filter { $0.index < segment.index }.reduce(0) { $0 + $1.durationMs }
                let url = await store.segmentURL(id, segment.index)
                // A failed segment stays untranscribed; later segments wait so tokens stay in order.
                guard let tokens = try? await transcriber.transcribe(url, locale: note.locale, offsetMs: offset),
                      let saved = try? await store.update(id, { n in
                          guard let i = n.segments.firstIndex(where: { $0.index == segment.index }),
                                !n.segments[i].transcribed else { return }
                          n.tokens += tokens
                          n.segments[i].transcribed = true
                      })
                else { return }
                note = saved
            }
        }
        guard !note.recording, !note.diarizationSettled, note.segments.allSatisfy(\.transcribed) else { return }

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
