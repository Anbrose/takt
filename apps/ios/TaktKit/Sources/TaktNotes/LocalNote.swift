import Foundation
import TaktCore

/// One recorded audio segment of a note (`{index}.m4a` next to `note.json`).
public struct LocalSegment: Codable, Equatable, Sendable {
    public var index: Int
    public var durationMs: Int
    public var file: String
    public var transcribed: Bool
    public var uploaded: Bool
    public init(index: Int, durationMs: Int, file: String, transcribed: Bool = false, uploaded: Bool = false) {
        self.index = index; self.durationMs = durationMs; self.file = file
        self.transcribed = transcribed; self.uploaded = uploaded
    }
}

/// What the server already has of this note.
public struct SyncState: Codable, Equatable, Sendable {
    public var created: Bool
    /// The transcript (lines, possibly without speakers) is on the server.
    public var transcriptSent: Bool
    /// The server's transcript already carries speakers; it is sent again once diarization succeeds.
    public var diarizedSent: Bool
    public init(created: Bool = false, transcriptSent: Bool = false, diarizedSent: Bool = false) {
        self.created = created; self.transcriptSent = transcriptSent; self.diarizedSent = diarizedSent
    }

    private enum CodingKeys: String, CodingKey { case created, transcriptSent, diarizedSent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = try c.decode(Bool.self, forKey: .created)
        transcriptSent = try c.decode(Bool.self, forKey: .transcriptSent)
        diarizedSent = try c.decodeIfPresent(Bool.self, forKey: .diarizedSent) ?? false
    }
}

/// A note as stored on the device; the source of truth until the server confirms each part.
public struct LocalNote: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var locale: String
    public var createdAt: Date
    public var segments: [LocalSegment]
    /// Whole-recording timeline, appended per segment in segment order.
    public var tokens: [TimedText]
    /// Set once all segments are transcribed after recording stopped; speaker nil until diarization succeeds.
    public var lines: [AlignedLine]?
    /// True once diarization succeeded and `lines` carry speakers; until then every process() retries it.
    public var diarized: Bool
    /// True until stop() finished writing the last segment.
    public var recording: Bool
    public var synced: SyncState

    public init(
        id: UUID = UUID(), title: String = "", locale: String, createdAt: Date = Date(),
        segments: [LocalSegment] = [], tokens: [TimedText] = [], lines: [AlignedLine]? = nil,
        diarized: Bool = false, recording: Bool = true, synced: SyncState = SyncState()
    ) {
        self.id = id; self.title = title; self.locale = locale; self.createdAt = createdAt
        self.segments = segments; self.tokens = tokens; self.lines = lines; self.diarized = diarized
        self.recording = recording; self.synced = synced
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, locale, createdAt, segments, tokens, lines, diarized, recording, synced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        locale = try c.decode(String.self, forKey: .locale)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        segments = try c.decode([LocalSegment].self, forKey: .segments)
        tokens = try c.decode([TimedText].self, forKey: .tokens)
        lines = try c.decodeIfPresent([AlignedLine].self, forKey: .lines)
        // Missing in notes saved before this field existed: diarization is retried.
        diarized = try c.decodeIfPresent(Bool.self, forKey: .diarized) ?? false
        recording = try c.decode(Bool.self, forKey: .recording)
        synced = try c.decode(SyncState.self, forKey: .synced)
    }

    public var durationMs: Int { segments.reduce(0) { $0 + $1.durationMs } }
}
