import Foundation
import Observation
import TaktAPI
import TaktNotes

/// One opened note: transcript, speakers, extracted draft, import and audio lookup.
@MainActor
@Observable
public final class NoteDetailModel {
    public let id: UUID
    private let backend: any TaktBackend
    private let store: NoteStore
    private let onChange: () -> Void
    private var audio: AudioUrls?

    public private(set) var note: Note?
    /// Short, user-facing message for the last failure. Cleared on the next action.
    public var notice: String?
    public private(set) var extracting = false
    /// The server doesn't have this note yet (recorded offline): shown from the device, read-only.
    public private(set) var isLocalOnly = false

    public init(id: UUID, backend: any TaktBackend, store: NoteStore, onChange: @escaping () -> Void = {}) {
        self.id = id; self.backend = backend; self.store = store; self.onChange = onChange
    }

    public func load() async {
        do {
            note = try await backend.note(id.uuidString)
            isLocalOnly = false
        } catch {
            if let local = await store.note(id) {
                note = Self.note(from: local)
                isLocalOnly = true
            } else {
                notice = "加载失败"
            }
        }
    }

    /// What the device knows of a note, shaped like the server's. No draft, nothing imported.
    private static func note(from l: LocalNote) -> Note {
        let transcript = (l.lines ?? []).map {
            TranscriptLine(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: $0.speaker)
        }
        var ids: [String] = []
        for case let s? in transcript.map(\.speaker) where !ids.contains(s) { ids.append(s) }
        return Note(
            id: l.id.uuidString, title: l.title, locale: l.locale, durationMs: l.durationMs, createdAt: l.createdAt,
            hasTranscript: !transcript.isEmpty, chainCount: 0, importedCount: 0, transcript: transcript,
            speakers: ids.map { Speaker(id: $0, name: $0) },
            segments: l.segments.map { NoteSegment(index: $0.index, durationMs: $0.durationMs, uploaded: $0.uploaded) },
            extraction: .init(version: 0, chains: []), imported: [])
    }

    /// Renames one speaker; the others keep their names.
    public func renameSpeaker(_ speaker: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note, !isLocalOnly, !name.isEmpty, note.speakers.contains(where: { $0.id == speaker }) else { return }
        notice = nil
        let speakers = note.speakers.map { $0.id == speaker ? Speaker(id: $0.id, name: name) : $0 }
        do {
            self.note = try await backend.updateNote(id.uuidString, title: nil, durationMs: nil, transcript: nil, speakers: speakers)
        } catch {
            notice = "保存失败"
        }
    }

    /// Asks the server to extract chains from the transcript.
    public func extract() async {
        guard !extracting, !isLocalOnly else { return }
        notice = nil
        extracting = true
        defer { extracting = false }
        do {
            note = try await backend.extract(note: id.uuidString)
            onChange()
        } catch let e as BackendError {
            switch e {
            case .api(429, _, _): notice = "已达上限"
            case .api(400, _, _): break // empty transcript: nothing to extract
            default: notice = "提取失败"
            }
        } catch {
            notice = "提取失败"
        }
    }

    /// Saves the edited draft. If it changed elsewhere meanwhile, the draft is reloaded instead.
    public func edit(_ chains: [Chain]) async {
        guard let note, !isLocalOnly else { return }
        notice = nil
        do {
            self.note = try await backend.updateExtraction(note: id.uuidString, version: note.extraction.version, chains: chains)
            onChange()
        } catch let e as BackendError where e.isVersionConflict {
            notice = "已在别处修改"
            await load()
        } catch {
            notice = "保存失败"
        }
    }

    /// Writes the picked steps into `parent`. On a stale draft (409) or a missing target (404) nothing was
    /// written; the note is reloaded.
    public func importPicks(_ picks: [ImportPick], into parent: String) async -> Bool {
        guard !isLocalOnly else { return false }
        notice = nil
        do {
            note = try await backend.importNote(id.uuidString, parent: parent, picks: picks).note
            onChange()
            return true
        } catch let e as BackendError {
            if case .api(409, _, _) = e {
                notice = "已在别处修改"
                await load()
            } else if case .api(404, _, _) = e {
                notice = "导入失败"
                await load()
            } else {
                notice = "导入失败"
            }
            return false
        } catch {
            notice = "导入失败"
            return false
        }
    }

    /// Where to play the recording at `ms`: the segment holding it and the offset inside that segment.
    /// Segments still on the device are played from there, without the server; the server's signed URLs
    /// are used only when the needed local file is gone.
    public func audioURL(at ms: Int) async -> (URL, TimeInterval)? {
        if let local = await store.note(id),
           let (index, offset) = Self.locate(ms, in: local.segments.map { ($0.index, $0.durationMs) }) {
            let file = await store.segmentURL(id, index)
            if FileManager.default.fileExists(atPath: file.path) { return (file, offset) }
        }
        guard let urls = await currentAudio(),
              let (index, offset) = Self.locate(ms, in: urls.segments.map { ($0.index, $0.durationMs) }),
              let hit = urls.segments.first(where: { $0.index == index }) else { return nil }
        let file = await store.segmentURL(id, index)
        if FileManager.default.fileExists(atPath: file.path) { return (file, offset) }
        return URL(string: hit.url).map { ($0, offset) }
    }

    /// The segment containing `ms` (the last one when past the end) and the offset in seconds inside it.
    private static func locate(_ ms: Int, in segments: [(index: Int, durationMs: Int)]) -> (Int, TimeInterval)? {
        let sorted = segments.sorted { $0.index < $1.index }
        guard var hit = sorted.first else { return nil }
        var start = 0
        for s in sorted {
            hit = s
            if ms < start + s.durationMs { break }
            start += s.durationMs
        }
        return (hit.index, TimeInterval(min(max(ms - start, 0), hit.durationMs)) / 1000)
    }

    /// Signed URLs are reused until the first one expires.
    private func currentAudio() async -> AudioUrls? {
        if let audio, audio.segments.allSatisfy({ $0.expiresAt > Date().addingTimeInterval(60) }) { return audio }
        audio = try? await backend.noteAudio(id.uuidString)
        return audio
    }
}
