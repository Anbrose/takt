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
    /// Audio recorded so far, all segments together: it stands still while paused.
    var recordedMs: Int { get }
    /// Recording, but paused by an interruption (a call, Siri) that hasn't been resumed.
    var isPaused: Bool { get }
    /// Resumes a paused recording; false when the system still refuses (the call is still on).
    @discardableResult func resume() -> Bool
}

public enum RecorderError: Error {
    case couldNotStart
    case emptyRecording
}

/// The files of one segment. While it records, the audio goes to `{index}.caf` as 16 kHz 16-bit PCM: a CAF file
/// cut off by a kill is still readable up to its last written buffer (an `.m4a` has no index until it is closed and
/// is lost whole). Once the segment closes it is encoded to `{index}.m4a` (AAC mono 16 kHz 32 kbps), the file that
/// is transcribed, diarized and uploaded, and the `.caf` is removed.
public enum SegmentFile {
    static var pcmSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }

    static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ] }

    /// `{index}.caf` next to the segment's `{index}.m4a`.
    public static func recordingURL(for segment: URL) -> URL {
        segment.deletingPathExtension().appendingPathExtension("caf")
    }

    /// Encodes the PCM recording to `segment` (written beside it first, then moved in) and removes the recording.
    /// Returns the audio's length in ms; throws when the recording is unreadable or empty (it is then kept).
    @discardableResult
    public static func encode(_ recording: URL, to segment: URL) throws -> Int {
        let part = segment.deletingPathExtension().appendingPathExtension("part.m4a")
        try? FileManager.default.removeItem(at: part)
        let ms = try write(recording, to: part)
        _ = try FileManager.default.replaceItemAt(segment, withItemAt: part)
        try FileManager.default.removeItem(at: recording)
        return ms
    }

    /// Length in ms of a readable audio file; nil when it can't be opened.
    public static func durationMs(_ url: URL) -> Int? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Int((Double(f.length) * 1000 / f.fileFormat.sampleRate).rounded())
    }

    /// Both files close when this returns (AVAudioFile finishes the `.m4a` on release).
    private static func write(_ recording: URL, to part: URL) throws -> Int {
        let input = try AVAudioFile(forReading: recording)
        guard input.length > 0, input.fileFormat.sampleRate > 0 else { throw RecorderError.emptyRecording }
        let output = try AVAudioFile(
            forWriting: part, settings: aacSettings, commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved)
        let chunk: AVAudioFrameCount = 16000 * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
            throw RecorderError.emptyRecording
        }
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(input.length - input.framePosition)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
        return Int((Double(input.length) * 1000 / input.fileFormat.sampleRate).rounded())
    }
}

/// AVAudioRecorder writing one segment per `segmentSeconds` (default 300) of recorded audio, see `SegmentFile`.
/// An interruption (call, Siri) pauses the current segment. It resumes when the interruption ends, or — iOS doesn't
/// always say it ended — when `resume()` is called (the app coming back to the foreground).
public final class SegmentRecorder: AudioCapture {
    public static let defaultSegmentSeconds = 300

    private var recorder: AVAudioRecorder?
    private var index = 0
    private var segmentURL: ((Int) -> URL)?
    private var segmentSeconds = SegmentRecorder.defaultSegmentSeconds
    private var onSegment: ((Int, Int) -> Void)?
    private var onError: ((Error) -> Void)?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// Encoding of the segments closed so far, chained so they are reported in order.
    private var encoding: Task<Void, Never>?
    private var stopping = false
    /// Recorded seconds of the segments already closed.
    private var closedSeconds: TimeInterval = 0

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
        stopping = false
        closedSeconds = 0
        try begin(0)
        // Rotation follows recorded time (currentTime stops while paused), checked once a second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateIfFull() }
        }
        observeInterruptions()
    }

    public var recordedMs: Int { Self.ms(closedSeconds + (recorder?.currentTime ?? 0)) }

    public var isPaused: Bool { recorder.map { !$0.isRecording } ?? false }

    @discardableResult
    public func resume() -> Bool {
        guard let recorder else { return false }
        if recorder.isRecording { return true }
        Self.reactivateSession()
        return recorder.record()
    }

    public func stop() async -> (index: Int, durationMs: Int)? {
        guard let recorder else { return nil }
        stopping = true
        recorder.stop()
        self.recorder = nil
        end()
        let last = index
        await encoding?.value
        encoding = nil
        // Not encoded: the `.caf` stays and is recovered at the next launch.
        guard let ms = await encode(last) else { return nil }
        return (last, ms)
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
        let r = try AVAudioRecorder(url: SegmentFile.recordingURL(for: url), settings: SegmentFile.pcmSettings)
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        index = i
    }

    /// Closes the full segment and starts the next one at once; the closed one is encoded meanwhile and then
    /// reported. If the next can't start, or the closed one can't be encoded, recording ends (what is on disk is
    /// recovered at the next launch).
    private func rotateIfFull() {
        guard let recorder, recorder.currentTime >= TimeInterval(segmentSeconds) else { return }
        let finished = index
        closedSeconds += recorder.currentTime
        recorder.stop()
        self.recorder = nil
        var failure: Error?
        do { try begin(finished + 1) } catch { failure = error }
        if failure != nil { end() }
        let previous = encoding
        encoding = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let ms = await self.encode(finished) {
                self.onSegment?(finished, ms)
            } else if failure == nil {
                failure = RecorderError.couldNotStart
                self.recorder?.stop()
                self.recorder = nil
                self.end()
            }
            if let failure, !self.stopping { self.onError?(failure) }
        }
    }

    /// Encodes segment `i` off the main actor; its length in ms, or nil when it failed.
    private func encode(_ i: Int) async -> Int? {
        guard let url = segmentURL?(i) else { return nil }
        let recording = SegmentFile.recordingURL(for: url)
        return await Task.detached { try? SegmentFile.encode(recording, to: url) }.value
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

    private static func reactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeInterruptions() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                if began {
                    recorder.pause()
                } else {
                    // Refused (still interrupted): stays paused until the app is active again.
                    self.resume()
                }
            }
        }
    }
    #else
    private static func activateSession() throws {}
    private static func deactivateSession() {}
    private static func reactivateSession() {}
    private func observeInterruptions() {}
    #endif
}
