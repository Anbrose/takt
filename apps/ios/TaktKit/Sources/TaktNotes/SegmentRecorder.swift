import AVFoundation
import Foundation

/// Records audio into consecutive segment files.
@MainActor
public protocol AudioCapture: AnyObject {
    /// Starts segment 0 at `segmentURL(0)`; every `segmentSeconds` of recorded audio the current file is closed,
    /// `onSegment(index, durationMs)` is called and the next index starts. If the next segment can't start,
    /// recording ends: `onError` is called (the finished segment was already reported) and stop() returns nil.
    func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int, onSegment: @escaping (Int, Int) -> Void,
               onError: @escaping (Error) -> Void) throws
    /// Closes the current segment and returns it; nil when nothing was recording.
    func stop() async -> (index: Int, durationMs: Int)?
}

public enum RecorderError: Error {
    case couldNotStart
}

/// AVAudioRecorder writing AAC mono 16 kHz 32 kbps, one file per `segmentSeconds` (default 300) of audio.
/// An interruption (call, Siri) pauses the current segment; it resumes when the system allows.
public final class SegmentRecorder: AudioCapture {
    public static let defaultSegmentSeconds = 300

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ]

    private var recorder: AVAudioRecorder?
    private var index = 0
    private var segmentURL: ((Int) -> URL)?
    private var segmentSeconds = SegmentRecorder.defaultSegmentSeconds
    private var onSegment: ((Int, Int) -> Void)?
    private var onError: ((Error) -> Void)?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    public init() {}

    public func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int = SegmentRecorder.defaultSegmentSeconds,
                      onSegment: @escaping (Int, Int) -> Void, onError: @escaping (Error) -> Void) throws {
        guard recorder == nil else { return }
        try Self.activateSession()
        self.segmentURL = segmentURL
        self.segmentSeconds = segmentSeconds
        self.onSegment = onSegment
        self.onError = onError
        index = 0
        try begin(0)
        // Rotation follows recorded time (currentTime stops while paused), checked once a second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateIfFull() }
        }
        observeInterruptions()
    }

    public func stop() async -> (index: Int, durationMs: Int)? {
        guard let recorder else { return nil }
        let durationMs = Self.ms(recorder.currentTime)
        recorder.stop()
        self.recorder = nil
        end()
        return (index, durationMs)
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.deactivateSession()
    }

    private func begin(_ i: Int) throws {
        guard let url = segmentURL?(i) else { throw RecorderError.couldNotStart }
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        index = i
    }

    private func rotateIfFull() {
        guard let recorder, recorder.currentTime >= TimeInterval(segmentSeconds) else { return }
        let finished = (index, Self.ms(recorder.currentTime))
        recorder.stop()
        self.recorder = nil
        onSegment?(finished.0, finished.1)
        do {
            try begin(finished.0 + 1)
        } catch {
            end()
            onError?(error)
        }
    }

    private static func ms(_ t: TimeInterval) -> Int { Int((t * 1000).rounded()) }

    #if os(iOS)
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
    }

    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeInterruptions() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated {
                guard let recorder = self?.recorder else { return }
                if began {
                    recorder.pause()
                } else {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    recorder.record()
                }
            }
        }
    }
    #else
    private static func activateSession() throws {}
    private static func deactivateSession() {}
    private func observeInterruptions() {}
    #endif
}
