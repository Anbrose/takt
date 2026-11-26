import Foundation
import Testing
@testable import TaktUI

@MainActor
private final class FakeTrack: PlaybackTrack {
    let url: URL
    var playing = false
    var stopped = false
    init(_ url: URL) { self.url = url }
    func play() { if !stopped { playing = true } }
    func stop() { stopped = true; playing = false }
}

@MainActor
private final class FakeSession: PlaybackSession {
    var log: [String] = []
    func activate() { log.append("on") }
    func deactivate() { log.append("off") }
}

/// Opens tracks only when told to, so a test can let a later request finish before an earlier one.
@MainActor
private final class Opener {
    var made: [FakeTrack] = []
    var waiting: [(URL, CheckedContinuation<Void, Never>)] = []

    func make(_ url: URL, _ offset: TimeInterval, _ onEnd: @escaping @MainActor () -> Void) async -> PlaybackTrack? {
        await withCheckedContinuation { waiting.append((url, $0)) }
        let t = FakeTrack(url)
        made.append(t)
        return t
    }

    func waitFor(_ url: URL) async {
        for _ in 0..<1000 where !waiting.contains(where: { $0.0 == url }) { await Task.yield() }
    }

    func release(_ url: URL) async {
        await waitFor(url)
        guard waiting.contains(where: { $0.0 == url }) else { Issue.record("never opened \(url)"); return }
        let i = waiting.firstIndex { $0.0 == url }!
        waiting.remove(at: i).1.resume()
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite struct NotePlayerTests {
    private func url(_ ms: Int) -> URL { URL(fileURLWithPath: "/seg/\(ms)") }

    @Test func quickRetapsPlayOnlyTheLastLine() async {
        let opener = Opener()
        let p = NotePlayer(makeTrack: opener.make, session: nil)
        let locate: NotePlayer.Locate = { ms in (self.url(ms), 0) }
        p.play(from: 1000, duration: 60000, locate: locate)
        // The first tap's file is opening (past every check before the await) when the second tap comes.
        await opener.waitFor(url(1000))
        p.play(from: 9000, duration: 60000, locate: locate)
        // The second tap's file opens first, then the first tap's.
        await opener.release(url(9000))
        await opener.release(url(1000))
        #expect(opener.made.count == 2)
        let first = opener.made.first { $0.url == url(1000) }!
        let second = opener.made.first { $0.url == url(9000) }!
        #expect(second.playing)
        #expect(!first.playing && first.stopped, "the stale track is dropped, not played")
        #expect(p.track === second)
        p.close()
        #expect(second.stopped)
    }

    @Test func cueWaitsPausedThenPlaysFromThere() async {
        let opener = Opener()
        let session = FakeSession()
        let p = NotePlayer(makeTrack: opener.make, session: session)
        p.cue(at: 19000, duration: 50000) { ms in (self.url(ms), 0) }
        #expect(p.at == 19000 && !p.playing)
        #expect(session.log.isEmpty && opener.waiting.isEmpty, "nothing opens until 播放")
        p.toggle()
        #expect(p.playing && session.log == ["on"])
        await opener.release(url(19000))
        #expect(p.track === opener.made.first)
        p.close()
    }

    @Test func playbackSessionWhilePlayingButNotDuringARecording() {
        let session = FakeSession()
        var recording = false
        let p = NotePlayer(makeTrack: { _, _, _ in nil }, session: session, isRecording: { recording })
        p.play(from: 0, duration: 1000) { _ in nil }
        p.play(from: 500, duration: 1000) { _ in nil }
        #expect(session.log == ["on"], "activated once")
        p.close()
        #expect(session.log == ["on", "off"])

        recording = true
        p.play(from: 0, duration: 1000) { _ in nil }
        p.close()
        #expect(session.log == ["on", "off"], "a recording's session is left alone")
    }
}
