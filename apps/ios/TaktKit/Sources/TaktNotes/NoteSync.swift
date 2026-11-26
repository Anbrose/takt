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
            // Everything already arrived but GCS hasn't finalized: ask again instead of sending an empty range.
            if offset < data.count {
                do {
                    if try await put(data, from: offset, to: sessionURL) { return }
                    lastError = UploadFailed(status: 308)
                } catch let e as UploadFailed where (400..<500).contains(e.status) && e.status != 408 && e.status != 429 {
                    throw e  // expired or rejected session: retrying won't help
                } catch {
                    lastError = error
                }
            }
            switch try? await status(size: data.count, of: sessionURL) {
            case .done?: return
            case .resume(let from)?: offset = min(from, data.count)
            case .failed(let s)?:
                if (400..<500).contains(s) && s != 408 && s != 429 { throw UploadFailed(status: s) }
                lastError = UploadFailed(status: s)
            case nil: break
            }
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

/// Pushes local notes to the server: note → transcript → segment audio. Safe to re-run. Without the note nothing
/// else is tried; after that the transcript and each segment go independently, so a segment that keeps failing
/// holds back neither the transcript (and extraction) nor the segments after it.
public actor NoteSync {
    private let store: NoteStore
    private let backend: any TaktBackend
    private let uploader: SegmentUploading
    /// Notes being synced, and whether another call asked for a rerun meanwhile.
    private var running: [UUID: Bool] = [:]

    public init(store: NoteStore, backend: any TaktBackend, uploader: SegmentUploading) {
        self.store = store; self.backend = backend; self.uploader = uploader
    }

    public func syncAll() async {
        for n in await store.all() { await sync(n.id) }
    }

    public func sync(_ id: UUID) async {
        if running[id] != nil {
            running[id] = true // the pass in flight may have read the note before this change
            return
        }
        repeat {
            running[id] = false
            do { try await run(id) } catch {}
        } while running[id] == true
        running[id] = nil
    }

    private func run(_ id: UUID) async throws {
        guard var note = await store.note(id) else { return }
        let key = id.uuidString

        if !note.synced.created {
            _ = try await backend.createNote(
                id: key, title: note.title.isEmpty ? nil : note.title, locale: note.locale, createdAt: note.createdAt)
            note = try await store.update(id) { $0.synced.created = true } ?? note
        }

        var failure: Error?
        do { try await sendTranscript(id, key) } catch { failure = error }

        var serverMs: Int?
        for seg in note.segments {
            do {
                if let ms = try await upload(id, key, seg) { serverMs = ms }
            } catch {
                failure = failure ?? error  // this segment waits for the next pass; the rest go on
            }
        }

        // The server totals the uploaded segments; while one is missing that is short of the recording.
        if let serverMs, let latest = await store.note(id), latest.synced.transcriptSent, serverMs != latest.durationMs {
            do {
                _ = try await backend.updateNote(key, title: nil, durationMs: latest.durationMs, transcript: nil, speakers: nil)
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Sends the lines once they exist, and again once they carry speakers.
    private func sendTranscript(_ id: UUID, _ key: String) async throws {
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

    /// Uploads one segment unless the server has it, then frees its local audio once the note is diarized.
    /// Returns the server's note duration when this call completed the upload.
    private func upload(_ id: UUID, _ key: String, _ seg: LocalSegment) async throws -> Int? {
        var uploaded = seg.uploaded
        var serverMs: Int?
        if !uploaded {
            let file = await store.segmentURL(id, seg.index)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let ticket = try await backend.uploadTicket(note: key, segment: seg.index)
            guard let url = URL(string: ticket.uploadUrl) else { throw URLError(.badURL) }
            try await uploader.upload(file, to: url)
            serverMs = try await backend.completeSegment(note: key, segment: seg.index, durationMs: seg.durationMs).durationMs
            try await store.update(id) { n in
                if let i = n.segments.firstIndex(where: { $0.index == seg.index }) { n.segments[i].uploaded = true }
            }
            uploaded = true
        }
        // Diarization reads the local audio, so it stays until the note is diarized.
        if uploaded, let current = await store.note(id), current.diarized {
            try await store.deleteAudio(id, seg.index)
        }
        return serverMs
    }
}
