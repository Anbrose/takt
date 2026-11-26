public struct TimedText: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var startMs: Int
    public var endMs: Int
    public init(speaker: String, startMs: Int, endMs: Int) {
        self.speaker = speaker; self.startMs = startMs; self.endMs = endMs
    }
}

public struct AlignedLine: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var speaker: String?
    public init(startMs: Int, endMs: Int, text: String, speaker: String?) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.speaker = speaker
    }
}

public enum SpeakerAlign {
    /// Each token → speaker with the most time overlap; no overlap → nearest turn by midpoint;
    /// no turns at all → speaker nil. Consecutive tokens of one speaker merge into a line,
    /// and a line also breaks when the gap to the next token exceeds `maxGapMs` (default 1500).
    /// Token texts are concatenated as-is: SpeechTranscriber runs carry their own spacing
    /// (none between Chinese characters, a leading space before English words).
    public static func align(_ tokens: [TimedText], _ turns: [SpeakerTurn], maxGapMs: Int = 1500) -> [AlignedLine] {
        var lines: [AlignedLine] = []
        for token in tokens.sorted(by: { $0.startMs < $1.startMs }) {
            let speaker = speaker(for: token, turns)
            if var last = lines.last, last.speaker == speaker, token.startMs - last.endMs <= maxGapMs {
                last.text += token.text
                last.endMs = max(last.endMs, token.endMs)
                lines[lines.count - 1] = last
            } else {
                lines.append(AlignedLine(startMs: token.startMs, endMs: token.endMs, text: token.text, speaker: speaker))
            }
        }
        return lines
    }

    private static func speaker(for token: TimedText, _ turns: [SpeakerTurn]) -> String? {
        // Total overlap per speaker; ties go to the speaker whose turn appears first.
        var overlaps: [(speaker: String, ms: Int)] = []
        for t in turns {
            let ms = min(token.endMs, t.endMs) - max(token.startMs, t.startMs)
            guard ms > 0 else { continue }
            if let i = overlaps.firstIndex(where: { $0.speaker == t.speaker }) {
                overlaps[i].ms += ms
            } else {
                overlaps.append((t.speaker, ms))
            }
        }
        var best: (speaker: String, ms: Int)?
        for o in overlaps where o.ms > (best?.ms ?? 0) { best = o }
        if let best { return best.speaker }

        let mid = (token.startMs + token.endMs) / 2
        var nearest: (speaker: String, dist: Int)?
        for t in turns {
            let d = mid < t.startMs ? t.startMs - mid : (mid > t.endMs ? mid - t.endMs : 0)
            if d < (nearest?.dist ?? Int.max) { nearest = (t.speaker, d) }
        }
        return nearest?.speaker
    }
}
