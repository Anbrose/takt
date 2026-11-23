import XCTest
@testable import TaktCore

final class SpeakerAlignTests: XCTestCase {
    private func tok(_ s: Int, _ e: Int, _ t: String = "w") -> TimedText { TimedText(startMs: s, endMs: e, text: t) }
    private func turn(_ sp: String, _ s: Int, _ e: Int) -> SpeakerTurn { SpeakerTurn(speaker: sp, startMs: s, endMs: e) }

    func testAlternatingSpeakers() {
        let turns = [
            turn("S1", 0, 2630), turn("S1", 2730, 5400), turn("S3", 7050, 8230), turn("S3", 8470, 10240),
            turn("S3", 10460, 11750), turn("S2", 12870, 18030), turn("S1", 19080, 20460), turn("S1", 20830, 24350),
            turn("S3", 25380, 26890), turn("S3", 27300, 30650), turn("S2", 31680, 33740), turn("S2", 34110, 37880),
            turn("S1", 38850, 40320), turn("S1", 40760, 42410), turn("S1", 42560, 44470), turn("S3", 45520, 48010),
            turn("S3", 48230, 49850),
        ]
        let sentences = [(0, 5700), (5700, 12060), (12780, 18660), (18660, 24660),
                         (25440, 31020), (31020, 38280), (38940, 44700), (44700, 50340)]
        var tokens: [TimedText] = []
        for (s, e) in sentences {
            let step = (e - s) / 6
            for i in 0..<6 {
                let a = s + i * step
                tokens.append(tok(a, i == 5 ? e : a + step - 200, "t\(tokens.count)"))
            }
        }
        let lines = SpeakerAlign.align(tokens, turns)
        XCTAssertEqual(lines.map(\.speaker), ["S1", "S3", "S2", "S1", "S3", "S2", "S1", "S3"])
    }

    func testTokenInGapTakesNearestTurn() {
        let turns = [turn("A", 0, 1000), turn("B", 5000, 6000)]
        XCTAssertEqual(SpeakerAlign.align([tok(1500, 2000)], turns).first?.speaker, "A")
        XCTAssertEqual(SpeakerAlign.align([tok(4000, 4500)], turns).first?.speaker, "B")
    }

    func testMostOverlapWins() {
        let turns = [turn("A", 0, 400), turn("B", 400, 1000)]
        XCTAssertEqual(SpeakerAlign.align([tok(0, 1000)], turns).first?.speaker, "B")
    }

    func testNoTurnsGivesNilSpeaker() {
        let lines = SpeakerAlign.align([tok(0, 500, "a"), tok(600, 900, " b"), tok(5000, 5400, "c")], [])
        XCTAssertEqual(lines.map(\.text), ["a b", "c"])
        XCTAssertTrue(lines.allSatisfy { $0.speaker == nil })
    }

    func testLongPauseSplitsSameSpeaker() {
        let turns = [turn("A", 0, 10000)]
        let lines = SpeakerAlign.align([tok(0, 500, "a"), tok(600, 900, " b"), tok(3000, 3500, "c")], turns)
        XCTAssertEqual(lines.map(\.text), ["a b", "c"])
        XCTAssertEqual(lines.map(\.speaker), ["A", "A"])
    }

    func testChineseTokensJoinWithoutSpaces() {
        let turns = [turn("1", 0, 2000)]
        let lines = SpeakerAlign.align([tok(0, 300, "先去"), tok(300, 600, "伏见"), tok(600, 900, "稻荷")], turns)
        XCTAssertEqual(lines.map(\.text), ["先去伏见稻荷"])
    }
}
