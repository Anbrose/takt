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
        guard !note.recording, note.lines == nil, note.segments.allSatisfy(\.transcribed) else { return }

        var files: [URL] = []
        for segment in note.segments.sorted(by: { $0.index < $1.index }) {
            files.append(await store.segmentURL(id, segment.index))
        }
        let turns = files.isEmpty ? [] : ((try? await diarizer.turns(for: files)) ?? [])
        _ = try? await store.update(id) { n in
            guard n.lines == nil else { return }
            n.lines = SpeakerAlign.align(n.tokens, turns)
        }
    }
}
