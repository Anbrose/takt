import AVFoundation
import Foundation
import Observation

/// One segment file playing (an `AVPlayer` in the app, a fake in tests).
@MainActor
protocol PlaybackTrack: AnyObject {
    func play()
    /// Stops for good: a stopped track never plays again and never reports its end.
    func stop()
}

/// The shared audio session: playback needs an output route, which the recorder's `.record` category lacks.
@MainActor
protocol PlaybackSession: AnyObject {
    func activate()
    func deactivate()
}

/// Plays the recording from a transcript time. The clock runs on its own so the outlined line follows along
/// across segments (each segment is its own file); the audio, where there is one, plays alongside.
@MainActor
@Observable
final class NotePlayer {
    /// Where to play `ms`: the segment file and the offset inside it.
    typealias Locate = @MainActor (_ ms: Int) async -> (URL, TimeInterval)?
    /// Opens `url` at `offset`, ready to play; `onEnd` fires when it plays to its end.
    typealias MakeTrack = @MainActor (_ url: URL, _ offset: TimeInterval, _ onEnd: @escaping @MainActor () -> Void) async
        -> PlaybackTrack?

    /// Current position in ms; nil = closed.
    private(set) var at: Int?
    private(set) var playing = false
    /// Bumped when a step's time chip asks the transcript to scroll to the line.
    var jumpSeq = 0
    /// The track playing now (tests).
    private(set) var track: PlaybackTrack?

    private var duration = 0
    private var startedAt = Date()
    private var startMs = 0
    private var ticker: Task<Void, Never>?
    /// Bumped on every play / pause / close: a track opened for an older request is stopped, not played.
    private var generation = 0
    private var sessionActive = false
    private var locate: Locate = { _ in nil }
    private let makeTrack: MakeTrack
    private let session: PlaybackSession?
    /// A recording is in progress: its `.record` session must not be switched to playback.
    private let isRecording: () -> Bool

    init(
        makeTrack: @escaping MakeTrack = AVTrack.make, session: PlaybackSession? = SystemPlaybackSession.shared,
        isRecording: @escaping () -> Bool = { false }
    ) {
        self.makeTrack = makeTrack
        self.session = session
        self.isRecording = isRecording
    }

    func play(from ms: Int, duration: Int, locate: @escaping Locate) {
        self.locate = locate
        self.duration = duration
        startMs = max(0, min(ms, duration))
        startedAt = Date()
        at = startMs
        playing = true
        if !sessionActive, !isRecording() {
            session?.activate()
            sessionActive = true
        }
        tick()
        loadAudio(at: startMs)
    }

    func toggle() {
        guard let at else { return }
        if playing {
            playing = false
            generation += 1
            ticker?.cancel()
            track?.stop()
            track = nil
        } else {
            play(from: at >= duration ? 0 : at, duration: duration, locate: locate)
        }
    }

    func close() {
        generation += 1
        ticker?.cancel()
        track?.stop()
        track = nil
        playing = false
        at = nil
        if sessionActive {
            session?.deactivate()
            sessionActive = false
        }
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.playing else { return }
                let now = self.startMs + Int(Date().timeIntervalSince(self.startedAt) * 1000)
                if now >= self.duration {
                    self.at = self.duration
                    self.playing = false
                    self.track?.stop()
                    self.track = nil
                    return
                }
                self.at = now
            }
        }
    }

    private func loadAudio(at ms: Int) {
        generation += 1
        let mine = generation
        track?.stop()
        track = nil
        Task { [weak self] in
            guard let self, let (url, offset) = await self.locate(ms), mine == self.generation else { return }
            let next = await self.makeTrack(url, offset) { [weak self] in
                // The next segment carries on from the clock.
                guard let self, mine == self.generation, self.playing, let at = self.at, at < self.duration else { return }
                self.loadAudio(at: at + 50)
            }
            // Another tap (or pause / close) came in while this one was opening: drop it.
            guard mine == self.generation, self.playing else {
                next?.stop()
                return
            }
            self.track = next
            next?.play()
        }
    }
}

/// A segment file in an `AVPlayer`.
@MainActor
final class AVTrack: PlaybackTrack {
    private let player: AVPlayer
    private var observer: NSObjectProtocol?

    private init(player: AVPlayer) { self.player = player }

    static func make(_ url: URL, _ offset: TimeInterval, _ onEnd: @escaping @MainActor () -> Void) async -> PlaybackTrack? {
        let item = AVPlayerItem(url: url)
        let t = AVTrack(player: AVPlayer(playerItem: item))
        await t.player.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        t.observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { _ in MainActor.assumeIsolated { onEnd() } }
        return t
    }

    func play() { player.play() }

    func stop() {
        player.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// `AVAudioSession` on iOS: `.playback` while the player is open, released afterwards. The recorder sets
/// `.record` again when it starts.
@MainActor
final class SystemPlaybackSession: PlaybackSession {
    static let shared = SystemPlaybackSession()

    func activate() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
