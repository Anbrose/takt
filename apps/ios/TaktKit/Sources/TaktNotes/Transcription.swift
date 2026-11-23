import AVFoundation
import Foundation
import Speech
import TaktCore

public protocol Transcribing: Sendable {
    /// Tokens of one segment file, shifted by `offsetMs` onto the whole-recording timeline.
    func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText]
    /// True when the on-device model for `locale` is installed.
    func isReady(locale: String) async -> Bool
    /// Downloads and installs the model for `locale`.
    func prepare(locale: String) async throws
}

public enum TranscriptionError: Error, Equatable {
    case unsupportedLocale(String)
}

/// On-device transcription with SpeechTranscriber; one token per attributed run with its audio time range.
@available(iOS 26, macOS 26, *)
public struct AppleTranscriber: Transcribing {
    public init() {}

    public func isReady(locale: String) async -> Bool {
        guard let module = try? await module(locale) else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    public func prepare(locale: String) async throws {
        let module = try await module(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    public func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText] {
        let transcriber = try await module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var out: [TimedText] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    if let range = run.audioTimeRange {
                        out.append(TimedText(
                            startMs: offsetMs + Int((range.start.seconds * 1000).rounded()),
                            endMs: offsetMs + Int((range.end.seconds * 1000).rounded()),
                            text: piece))
                    } else if !out.isEmpty {
                        out[out.count - 1].text += piece
                    }
                }
            }
            return out
        }
        do {
            let audio = try AVAudioFile(forReading: file)
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        return try await collect.value
    }

    private func module(_ locale: String) async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                 attributeOptions: [.audioTimeRange])
    }
}

public enum SupportedLanguages {
    /// Locales SpeechTranscriber can transcribe on this device (installed or downloadable).
    @available(iOS 26, macOS 26, *)
    public static func all() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}
