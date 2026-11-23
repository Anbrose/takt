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
    public var transcriptSent: Bool
    public init(created: Bool = false, transcriptSent: Bool = false) {
        self.created = created; self.transcriptSent = transcriptSent
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
    /// Set after diarization + alignment (speaker nil when diarization failed).
    public var lines: [AlignedLine]?
    /// True until stop() finished writing the last segment.
    public var recording: Bool
    public var synced: SyncState

    public init(
        id: UUID = UUID(), title: String = "", locale: String, createdAt: Date = Date(),
        segments: [LocalSegment] = [], tokens: [TimedText] = [], lines: [AlignedLine]? = nil,
        recording: Bool = true, synced: SyncState = SyncState()
    ) {
        self.id = id; self.title = title; self.locale = locale; self.createdAt = createdAt
        self.segments = segments; self.tokens = tokens; self.lines = lines
        self.recording = recording; self.synced = synced
    }

    public var durationMs: Int { segments.reduce(0) { $0 + $1.durationMs } }
}
