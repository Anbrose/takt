import AVFoundation
import FluidAudio
import Foundation
import TaktCore

public protocol Diarizing: Sendable {
    /// Speaker turns over the files played back to back (times on the whole-recording timeline).
    func turns(for files: [URL]) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline diarizer over the whole recording at once, so speaker ids agree across segments.
public struct FluidDiarizer: Diarizing {
    public init() {}

    public func turns(for files: [URL]) async throws -> [SpeakerTurn] {
        guard !files.isEmpty else { return [] }
        let joined = try Self.concatenate(files)
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

    /// Writes the files one after another into a 16 kHz mono temp file, one segment in memory at a time.
    private static func concatenate(_ files: [URL]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "diarize-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let converter = AudioConverter(sampleRate: 16000)
        for file in files {
            let samples = try converter.resampleAudioFile(file)
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
