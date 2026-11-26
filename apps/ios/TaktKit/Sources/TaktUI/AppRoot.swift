import AVFoundation
import Foundation
import Network
import SwiftUI
import TaktAPI
import TaktNotes

/// Entry view for the app target. Picks the backend from the launch environment:
/// - `-demo` launch argument → in-memory 日本旅行 sample, no server needed
/// - `TAKT_API_URL` environment variable → that server (Xcode scheme / simctl)
/// - `TaktAPIURL` in Info.plist, set at build time from the `TAKT_API_URL` build setting
///   (so a device build launched from the home screen still finds the Mac on the LAN)
/// - otherwise http://127.0.0.1:3000 (the simulator reaches the Mac's localhost)
/// On iOS 26 it also sets up note taking (in `-demo` with fake recording, transcription and diarization).
public struct AppRoot: View {
    @State private var backend: (any TaktBackend)?
    @State private var notes: NotesModel?
    @State private var splash = true
    /// First launch shows 重播 / 开始; afterwards the splash plays and hands over by itself.
    @AppStorage("splash.seen") private var splashSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let info: ProcessInfo

    public init(info: ProcessInfo = .processInfo) {
        self.info = info
    }

    public static let defaultServer = URL(string: "http://127.0.0.1:3000")!

    public var body: some View {
        ZStack {
            // Loads underneath while the splash plays.
            if let backend {
                RootView(backend: backend, notes: notes, allowRecording: allowRecording)
            } else {
                Palette.bg.ignoresSafeArea()
            }
            if splash && !info.arguments.contains("-skip-splash") {
                SplashView(interactive: !splashSeen) {
                    splashSeen = true
                    Motion.with(Motion.nav, reduce: reduce) { splash = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task {
            guard backend == nil else { return }
            // -demo: offline sample data (deterministic for UI tests).
            if demo {
                let sample = await InMemoryBackend.sample()
                // The 「长按拖到项目」 tip shows again on every demo launch.
                UserDefaults.standard.removeObject(forKey: "notes.dragTipDone")
                if #available(iOS 26, macOS 26, *) { notes = DemoNotes.model(backend: sample) }
                backend = sample
            } else {
                let fromEnv = info.environment["TAKT_API_URL"].flatMap(URL.init(string:))
                let fromPlist = (Bundle.main.object(forInfoDictionaryKey: "TaktAPIURL") as? String)
                    .flatMap { $0.isEmpty ? nil : URL(string: $0) }
                let live = LiveBackend(baseURL: fromEnv ?? fromPlist ?? Self.defaultServer)
                if #available(iOS 26, macOS 26, *) { notes = Self.liveNotes(live) }
                backend = live
            }
        }
        // Launch work (recovery, sync) runs in NotesModel.load(); this picks it up again when the network returns.
        .task(id: notes == nil) {
            guard let notes else { return }
            var offline = false
            for await online in Self.network() {
                if online, offline { await notes.resume() }
                offline = !online
            }
        }
    }

    private var demo: Bool { info.arguments.contains("-demo") }

    private var allowRecording: @MainActor () async -> Bool {
        if demo { return { true } }
        return { await AVAudioApplication.requestRecordPermission() }
    }

    @available(iOS 26, macOS 26, *)
    @MainActor
    private static func liveNotes(_ backend: any TaktBackend) -> NotesModel {
        let store = NoteStore(root: NoteStore.defaultRoot)
        let transcriber = AppleTranscriber()
        return NotesModel(
            backend: backend, store: store,
            processor: NoteProcessor(store: store, transcriber: transcriber, diarizer: FluidDiarizer()),
            sync: NoteSync(store: store, backend: backend, uploader: GCSUploader()),
            capture: SegmentRecorder(), transcriber: transcriber)
    }

    /// Whether the device is online, on every change.
    private static func network() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.takt.network"))
        }
    }
}
