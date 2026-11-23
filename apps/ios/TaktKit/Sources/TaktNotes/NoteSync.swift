import Foundation
import TaktAPI
import TaktCore

/// Sends one audio file to a resumable GCS session URL.
public protocol SegmentUploading: Sendable {
    func upload(_ file: URL, to sessionURL: URL) async throws
}

/// What to do after a failed PUT, from the answer to the `Content-Range: bytes */<size>` status query.
public enum UploadResume: Equatable, Sendable {
    case done
    /// Send the file again starting at this byte.
    case resume(from: Int)
    case failed(status: Int)

    /// 200/201: stored. 308: incomplete, `Range: bytes=0-N` says N+1 bytes arrived (no header: none).
    public static func decide(status: Int, range: String?) -> UploadResume {
        switch status {
        case 200, 201: return .done
        case 308:
            guard let range, let last = range.split(separator: "-").last, let n = Int(last) else { return .resume(from: 0) }
            return .resume(from: n + 1)
        default: return .failed(status: status)
        }
    }
}

public struct UploadFailed: Error, Equatable, Sendable { public var status: Int }

/// PUT to the resumable session URL; on failure asks GCS how much it has and sends the rest.
public struct GCSUploader: SegmentUploading {
    private let session: URLSession
    private let attempts: Int
    public init(session: URLSession = .shared, attempts: Int = 3) {
        self.session = session; self.attempts = attempts
    }

    public func upload(_ file: URL, to sessionURL: URL) async throws {
        let data = try Data(contentsOf: file)
        var offset = 0
        var lastError: Error = UploadFailed(status: 0)
        for _ in 0..<attempts {
            do {
                if try await put(data, from: offset, to: sessionURL) { return }
                lastError = UploadFailed(status: 308)
            } catch {
                lastError = error
            }
            do {
                switch try await status(size: data.count, of: sessionURL) {
                case .done: return
                case .resume(let from): offset = min(from, data.count)
                case .failed(let s): throw UploadFailed(status: s)
                }
            } catch { lastError = error }
        }
        throw lastError
    }

    /// True when GCS stored the whole object.
    private func put(_ data: Data, from offset: Int, to url: URL) async throws -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        if offset > 0 {
            req.setValue("bytes \(offset)-\(data.count - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
        }
        let (_, resp) = try await session.upload(for: req, from: data.subdata(in: offset..<data.count))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 || code == 201 { return true }
        if code == 308 { return false }
        throw UploadFailed(status: code)
    }

    private func status(size: Int, of url: URL) async throws -> UploadResume {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        let (_, resp) = try await session.upload(for: req, from: Data())
        let http = resp as? HTTPURLResponse
        return .decide(status: http?.statusCode ?? 0, range: http?.value(forHTTPHeaderField: "Range"))
    }
}

/// Pushes local notes to the server: note → segment audio → transcript. Safe to re-run; stops at the first failure.
public actor NoteSync {
    private let store: NoteStore
    private let backend: any TaktBackend
    private let uploader: SegmentUploading
    private var running: Set<UUID> = []

    public init(store: NoteStore, backend: any TaktBackend, uploader: SegmentUploading) {
        self.store = store; self.backend = backend; self.uploader = uploader
    }

    public func syncAll() async {
        for n in await store.all() { await sync(n.id) }
    }

    public func sync(_ id: UUID) async {
        guard running.insert(id).inserted else { return }
        defer { running.remove(id) }
        do { try await run(id) } catch {}
    }

    private func run(_ id: UUID) async throws {
        guard var note = await store.note(id) else { return }
        let key = id.uuidString

        if !note.synced.created {
            _ = try await backend.createNote(
                id: key, title: note.title.isEmpty ? nil : note.title, locale: note.locale, createdAt: note.createdAt)
            note = try await store.update(id) { $0.synced.created = true } ?? note
        }

        for seg in note.segments {
            var uploaded = seg.uploaded
            if !uploaded {
                let file = await store.segmentURL(id, seg.index)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let ticket = try await backend.uploadTicket(note: key, segment: seg.index)
                guard let url = URL(string: ticket.uploadUrl) else { throw URLError(.badURL) }
                try await uploader.upload(file, to: url)
                _ = try await backend.completeSegment(note: key, segment: seg.index, durationMs: seg.durationMs)
                try await store.update(id) { n in
                    if let i = n.segments.firstIndex(where: { $0.index == seg.index }) { n.segments[i].uploaded = true }
                }
                uploaded = true
            }
            // Diarization reads the local audio, so it stays until the note is diarized.
            if uploaded, let current = await store.note(id), current.diarized {
                try await store.deleteAudio(id, seg.index)
            }
        }

        guard let latest = await store.note(id), let lines = latest.lines else { return }
        let needsSend = !latest.synced.transcriptSent || (latest.diarized && !latest.synced.diarizedSent)
        guard needsSend else { return }
        var ids: [String] = []
        for case let s? in lines.map(\.speaker) where !ids.contains(s) { ids.append(s) }
        _ = try await backend.updateNote(
            key, title: nil, durationMs: latest.durationMs,
            transcript: lines.map { TranscriptLine(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: $0.speaker) },
            speakers: ids.map { Speaker(id: $0, name: $0) })
        let wasDiarized = latest.diarized
        try await store.update(id) { n in
            n.synced.transcriptSent = true
            if wasDiarized { n.synced.diarizedSent = true }
        }
    }
}
