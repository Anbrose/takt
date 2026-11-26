import Foundation
import TaktCore
import TaktNotes

/// `-demo` note taking: no microphone, speech model or diarizer. A "recording" writes its length into the
/// segment file; the transcriber spreads the 京都 conversation over that length and the diarizer hands out
/// its speakers, so every demo recording ends with the same transcript (and, from the in-memory extractor,
/// the same chains).
@MainActor
public enum DemoNotes {
    /// The languages the demo offers; 中 and EN are installed, the rest "download" in a moment.
    public nonisolated static let locales = ["zh_CN", "zh_TW", "yue_CN", "ja_JP", "ko_KR", "en_US", "fr_FR", "de_DE", "es_ES"]

    /// A fresh notes model over `backend`: local notes and the intro / 自动生成任务 settings start empty on
    /// every launch, so UI tests are deterministic.
    public static func model(backend: InMemoryBackend) -> NotesModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "takt-demo-notes")
        try? FileManager.default.removeItem(at: root)
        let suite = "dev.takt.demo.notes"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = NoteStore(root: root)
        let transcriber = DemoTranscriber()
        return NotesModel(
            backend: backend, store: store,
            processor: NoteProcessor(store: store, transcriber: transcriber, diarizer: DemoDiarizer()),
            sync: NoteSync(store: store, backend: backend, uploader: DemoUploader()),
            capture: DemoCapture(), transcriber: transcriber, defaults: defaults,
            deviceLocale: "zh_CN", supportedLocales: { locales })
    }

    /// Where line `i` of `n` starts and ends inside a recording of `durationMs`.
    nonisolated static func slot(_ i: Int, of n: Int, in durationMs: Int) -> (Int, Int) {
        let width = max(durationMs, n) / n
        return (i * width, i * width + max(width * 9 / 10, 1))
    }
}

/// Pretends to record: one segment, as long as the time between start and stop.
@MainActor
final class DemoCapture: AudioCapture {
    private var started: Date?
    private var url: URL?

    func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int, onSegment: @escaping (Int, Int) -> Void,
               onError: @escaping (Error) -> Void) throws {
        url = segmentURL(0)
        started = Date()
        try Data("0".utf8).write(to: segmentURL(0))
    }

    func stop() async -> (index: Int, durationMs: Int)? {
        guard let started, let url else { return nil }
        self.started = nil
        let ms = max(1000, Int(Date().timeIntervalSince(started) * 1000))
        try? Data(String(ms).utf8).write(to: url)
        return (0, ms)
    }
}

/// The 京都 conversation spread over the segment's recorded length.
actor DemoTranscriber: Transcribing {
    private var ready: Set<String> = ["zh_CN", "en_US"]

    func isReady(locale: String) async -> Bool { ready.contains(locale.replacingOccurrences(of: "-", with: "_")) }

    func prepare(locale: String) async throws {
        try await Task.sleep(for: .milliseconds(1500))
        ready.insert(locale.replacingOccurrences(of: "-", with: "_"))
    }

    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        let ms = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int($0) } ?? 1000
        let lines = InMemoryBackend.kyotoLines
        return lines.enumerated().map { i, l in
            let (start, end) = DemoNotes.slot(i, of: lines.count, in: ms)
            return TimedText(startMs: offsetMs + start, endMs: offsetMs + end, text: l.2)
        }
    }
}

/// The conversation's speakers, one turn per line.
struct DemoDiarizer: Diarizing {
    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] {
        let total = segments.reduce(0) { $0 + $1.durationMs }
        let lines = InMemoryBackend.kyotoLines
        return lines.enumerated().map { i, l in
            let (start, _) = DemoNotes.slot(i, of: lines.count, in: total)
            let (next, _) = DemoNotes.slot(i + 1, of: lines.count, in: total)
            return SpeakerTurn(speaker: l.1, startMs: start, endMs: next)
        }
    }
}

/// The in-memory backend keeps no audio; uploads succeed at once.
struct DemoUploader: SegmentUploading {
    func upload(_ file: URL, to sessionURL: URL) async throws {}
}
