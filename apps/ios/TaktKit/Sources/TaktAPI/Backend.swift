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
    func level(_ taskId: String) async throws -> Level
    func createTask(in parentId: String, _ body: CreateTaskBody) async throws -> TaskSummary
    func reorder(_ parentId: String, ids: [String], version: Int) async throws -> Level
    func setPrerequisite(_ id: String, done: Bool) async throws -> Prerequisite
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

    private func err(_ status: Int, _ e: Components.Schemas.ApiError) -> BackendError {
        .api(status: status, code: e.error, message: e.message)
    }
}
