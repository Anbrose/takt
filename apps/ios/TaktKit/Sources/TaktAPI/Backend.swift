import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

// Generated types (from packages/contract) under friendlier names.
public typealias Project = Components.Schemas.Project
public typealias Level = Components.Schemas.Level
public typealias TaskSummary = Components.Schemas.TaskSummary
public typealias Prerequisite = Components.Schemas.Prerequisite
public typealias Urgency = Components.Schemas.Urgency
public typealias Crumb = Components.Schemas.Crumb
public typealias CreateTaskBody = Components.Schemas.CreateTask
public typealias NewPrerequisite = Components.Schemas.NewPrerequisite

public typealias SearchResult = Components.Schemas.SearchResult

public typealias NoteSummary = Components.Schemas.NoteSummary
public typealias Note = Components.Schemas.Note
public typealias TranscriptLine = Components.Schemas.TranscriptLine
public typealias Speaker = Components.Schemas.Speaker
public typealias Chain = Components.Schemas.Chain
public typealias ChainStep = Components.Schemas.ChainStep
public typealias Quote = Components.Schemas.Quote
public typealias ImportedStep = Components.Schemas.ImportedStep
public typealias NoteSegment = Components.Schemas.NoteSegment
public typealias ImportPick = Components.Schemas.ImportPick
public typealias PickedPlace = Components.Schemas.PickedPlace
public typealias UploadTicket = Components.Schemas.UploadTicket
public typealias AudioUrls = Components.Schemas.AudioUrls
public typealias AudioSegmentURL = Components.Schemas.AudioUrls.SegmentsPayloadPayload

extension ImportPick {
    /// `places` is keyed by step id. The generator wraps that map in `PlacesPayload`; callers pass a plain dictionary.
    public init(chainId: String, stepIds: [String], places: [String: PickedPlace]) {
        self.init(
            chainId: chainId, stepIds: stepIds,
            places: places.isEmpty ? nil : PlacesPayload(additionalProperties: places)
        )
    }

    /// The picked places keyed by step id (empty when none).
    public var placesByStep: [String: PickedPlace] { places?.additionalProperties ?? [:] }
}

public enum BackendError: Error, Equatable, Sendable {
    /// The server answered with an ApiError (`code` is e.g. "version_conflict", "validation").
    case api(status: Int, code: String, message: String)
    /// A status the contract doesn't document.
    case unexpected(status: Int)

    public var code: String? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }

    public var isVersionConflict: Bool {
        if case .api(409, "version_conflict", _) = self { return true }
        return false
    }
}

/// What the UI needs from the server. `LiveBackend` talks HTTP; tests use a fake.
public protocol TaktBackend: Sendable {
    func projects() async throws -> [Project]
    func createProject(name: String) async throws -> Project
    func renameProject(_ id: String, name: String) async throws -> Project
    /// Deletes the project and its whole task tree.
    func deleteProject(_ id: String) async throws
    func level(_ taskId: String) async throws -> Level
    func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary
    func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level
    /// 左滑删除: removes the task and everything under it; returns the parent level.
    func deleteTask(_ id: String) async throws -> Level
    func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite
    /// Moves a task under `parent`, before sibling `before` (else last). `from` and `to` are the same level
    /// when the parent is unchanged. Errors: 404 not_found; 400 root_task, move_into_self, cross_project, bad_before.
    func moveTask(_ id: String, to parent: String, before: String?) async throws -> (from: Level, to: Level)
    /// Case-insensitive substring search over projects, tasks and notes.
    func search(_ q: String) async throws -> SearchResult

    // Notes (录音笔记). Errors carry codes such as empty_transcript, extract_limit, budget_exceeded,
    // llm_failed, stale_draft, version_conflict.
    /// Newest first.
    func notes() async throws -> [NoteSummary]
    /// Idempotent on `id`: a retried create returns the same note.
    func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note
    func note(_ id: String) async throws -> Note
    func updateNote(
        _ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?
    ) async throws -> Note
    func deleteNote(_ id: String) async throws
    func uploadTicket(note: String, segment: Int) async throws -> UploadTicket
    func completeSegment(note: String, segment: Int, durationMs: Int) async throws -> Note
    func noteAudio(_ id: String) async throws -> AudioUrls
    /// AI draft from the transcript. Returns the stored draft when the transcript is unchanged.
    func extract(note: String) async throws -> Note
    /// Replaces the draft; `version` is the one the edit was based on.
    func updateExtraction(note: String, version: Int, chains: [Chain]) async throws -> Note
    /// Writes the picked steps into the level `parent` (before its child `before`, else at the end);
    /// returns that level and the updated note.
    func importNote(_ id: String, parent: String, picks: [ImportPick], before: String?) async throws -> (level: Level, note: Note)
}

extension TaktBackend {
    public func importNote(_ id: String, parent: String, picks: [ImportPick]) async throws -> (level: Level, note: Note) {
        try await importNote(id, parent: parent, picks: picks, before: nil)
    }
}

public struct LiveBackend: TaktBackend {
    let client: Client

    public init(baseURL: URL, transport: any ClientTransport = URLSessionTransport()) {
        // The server sends `2026-11-13T13:01:24.800Z` (JS toISOString): fractional seconds required.
        client = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: transport
        )
    }

    public func projects() async throws -> [Project] {
        switch try await client.listProjects() {
        case .ok(let r): return try r.body.json.projects
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func createProject(name: String) async throws -> Project {
        switch try await client.createProject(body: .json(.init(name: name))) {
        case .created(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func renameProject(_ id: String, name: String) async throws -> Project {
        switch try await client.updateProject(path: .init(projectId: id), body: .json(.init(name: name))) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func deleteProject(_ id: String) async throws {
        switch try await client.deleteProject(path: .init(projectId: id)) {
        case .ok: return
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func level(_ taskId: String) async throws -> Level {
        switch try await client.getLevel(path: .init(taskId: taskId)) {
        case .ok(let r): return try r.body.json
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary {
        switch try await client.createTask(path: .init(taskId: parentId), body: .json(body)) {
        case .created(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level {
        switch try await client.reorderLevel(
            path: .init(taskId: parentId), body: .json(.init(ids: ids, version: version))
        ) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func deleteTask(_ id: String) async throws -> Level {
        switch try await client.deleteTask(path: .init(taskId: id)) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite {
        switch try await client.updatePrerequisite(
            path: .init(prerequisiteId: id), body: .json(.init(done: done))
        ) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func moveTask(_ id: String, to parent: String, before: String?) async throws -> (from: Level, to: Level) {
        switch try await client.moveTask(
            path: .init(taskId: id), body: .json(.init(parentTaskId: parent, beforeTaskId: before))
        ) {
        case .ok(let r):
            let result = try r.body.json
            return (result.from, result.to)
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func search(_ q: String) async throws -> SearchResult {
        switch try await client.search(query: .init(q: q)) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    // MARK: Notes

    public func notes() async throws -> [NoteSummary] {
        switch try await client.listNotes() {
        case .ok(let r): return try r.body.json.notes
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note {
        switch try await client.createNote(
            body: .json(.init(id: id, title: title, locale: locale, createdAt: createdAt))
        ) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func note(_ id: String) async throws -> Note {
        switch try await client.getNote(path: .init(noteId: id)) {
        case .ok(let r): return try r.body.json
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func updateNote(
        _ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?
    ) async throws -> Note {
        let body = Components.Schemas.UpdateNote(
            title: title, durationMs: durationMs, transcript: transcript, speakers: speakers)
        switch try await client.updateNote(path: .init(noteId: id), body: .json(body)) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func deleteNote(_ id: String) async throws {
        switch try await client.deleteNote(path: .init(noteId: id)) {
        case .ok: return
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func uploadTicket(note: String, segment: Int) async throws -> UploadTicket {
        switch try await client.uploadSegment(path: .init(noteId: note, index: segment)) {
        case .ok(let r): return try r.body.json
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func completeSegment(note: String, segment: Int, durationMs: Int) async throws -> Note {
        switch try await client.completeSegment(
            path: .init(noteId: note, index: segment), body: .json(.init(durationMs: durationMs))
        ) {
        case .ok(let r): return try r.body.json
        case .notFound(let r): throw err(404, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func noteAudio(_ id: String) async throws -> AudioUrls {
        switch try await client.noteAudio(path: .init(noteId: id)) {
        case .ok(let r): return try r.body.json
        case .notFound(let r): throw err(404, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func extract(note: String) async throws -> Note {
        switch try await client.extractNote(path: .init(noteId: note)) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .tooManyRequests(let r): throw err(429, try r.body.json)
        case .badGateway(let r): throw err(502, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func updateExtraction(note: String, version: Int, chains: [Chain]) async throws -> Note {
        switch try await client.updateExtraction(
            path: .init(noteId: note), body: .json(.init(version: version, chains: chains))
        ) {
        case .ok(let r): return try r.body.json
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    public func importNote(
        _ id: String, parent: String, picks: [ImportPick], before: String?
    ) async throws -> (level: Level, note: Note) {
        switch try await client.importNote(
            path: .init(noteId: id), body: .json(.init(parentTaskId: parent, beforeTaskId: before, picks: picks))
        ) {
        case .ok(let r):
            let result = try r.body.json
            return (result.level, result.note)
        case .badRequest(let r): throw err(400, try r.body.json)
        case .notFound(let r): throw err(404, try r.body.json)
        case .conflict(let r): throw err(409, try r.body.json)
        case .undocumented(let s, _): throw BackendError.unexpected(status: s)
        }
    }

    private func err(_ status: Int, _ e: Components.Schemas.ApiError) -> BackendError {
        .api(status: status, code: e.error, message: e.message)
    }
}
