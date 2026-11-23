import AVFoundation
import FluidAudio
import Foundation
import TaktCore

/// One segment file and its recorded duration, which places it on the whole-recording timeline.
public struct SegmentAudio: Equatable, Sendable {
    public var file: URL
    public var durationMs: Int
    public init(file: URL, durationMs: Int) {
        self.file = file; self.durationMs = durationMs
    }
}

public protocol Diarizing: Sendable {
    /// Speaker turns over the segments played back to back, each occupying exactly its `durationMs`
    /// (times on the whole-recording timeline, the same one the transcript tokens use).
    func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline diarizer over the whole recording at once, so speaker ids agree across segments.
public struct FluidDiarizer: Diarizing {
    public init() {}

    public func turns(for segments: [SegmentAudio]) async throws -> [SpeakerTurn] {
        guard !segments.isEmpty else { return [] }
        let joined = try Self.concatenate(segments)
        defer { try? FileManager.default.removeItem(at: joined) }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        let result = try await manager.process(joined)
        return Self.renumber(result.segments.map {
            (id: $0.speakerId, startMs: Int((Double($0.startTimeSeconds) * 1000).rounded()),
             endMs: Int((Double($0.endTimeSeconds) * 1000).rounded()))
        })
    }

    /// Speaker ids → "1", "2", … in order of first appearance.
    static func renumber(_ segments: [(id: String, startMs: Int, endMs: Int)]) -> [SpeakerTurn] {
        var names: [String: String] = [:]
        return segments.sorted { $0.startMs < $1.startMs }.map { s in
            let name = names[s.id] ?? {
                let n = String(names.count + 1)
                names[s.id] = n
                return n
            }()
            return SpeakerTurn(speaker: name, startMs: s.startMs, endMs: s.endMs)
        }
    }

    static let sampleRate = 16000

    /// Samples padded with silence or cut to exactly `durationMs`, so decoded length (AAC priming/padding)
    /// never shifts later segments against the token timeline.
    static func fit(_ samples: [Float], durationMs: Int) -> [Float] {
        let count = max(0, durationMs) * sampleRate / 1000
        if samples.count >= count { return Array(samples.prefix(count)) }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }

    /// Writes the segments one after another into a 16 kHz mono temp file, one segment in memory at a time.
    /// An unreadable segment contributes silence of its duration.
    private static func concatenate(_ segments: [SegmentAudio]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "diarize-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let converter = AudioConverter(sampleRate: Double(sampleRate))
        for segment in segments {
            let samples = fit((try? converter.resampleAudioFile(segment.file)) ?? [], durationMs: segment.durationMs)
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            try out.write(from: buffer)
        }
        return url
    }
}
