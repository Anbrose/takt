#if os(macOS)
import Foundation
import Testing
@testable import TaktNotes

/// Real SpeechTranscriber on the Mac; needs macOS 26+ with zh_CN speech assets. Run with TAKT_SPEECH_HOST=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAKT_SPEECH_HOST"] == "1"))
struct AppleTranscriberHostTests {
    @Test func transcribesChineseFixture() async throws {
        guard #available(macOS 26, *) else { return }
        let file = try #require(Bundle.module.url(forResource: "zh-dialogue", withExtension: "wav", subdirectory: "Fixtures"))
        let transcriber = AppleTranscriber()
        if await !transcriber.isReady(locale: "zh-CN") { try await transcriber.prepare(locale: "zh-CN") }

        let tokens = try await transcriber.transcribe(file, locale: "zh-CN", offsetMs: 300_000)
        print("host transcript:", tokens.count, "tokens:", tokens.map(\.text).joined())
        #expect(!tokens.isEmpty)
        #expect(tokens.first.map { $0.startMs >= 300_000 } == true)
        #expect(zip(tokens, tokens.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        #expect(tokens.allSatisfy { $0.startMs <= $0.endMs })
        #expect(tokens.last.map { $0.endMs > $0.startMs && $0.endMs <= 300_000 + 11_000 } == true)
    }
}
#endif
