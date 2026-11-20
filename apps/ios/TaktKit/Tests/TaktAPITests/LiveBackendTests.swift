import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import TaktAPI

/// Feeds LiveBackend canned responses shaped exactly like the Node server's output.
private struct StubTransport: ClientTransport {
    let status: HTTPResponse.Status
    let json: String

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
        -> (HTTPResponse, HTTPBody?)
    {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        return (HTTPResponse(status: status, headerFields: fields), HTTPBody(json))
    }
}

private func backend(_ json: String, status: HTTPResponse.Status = .ok) -> LiveBackend {
    LiveBackend(baseURL: URL(string: "http://test")!, transport: StubTransport(status: status, json: json))
}

@Test func decodesServerTimestampsWithMilliseconds() async throws {
    let b = backend(#"{"projects":[{"id":"ecf50ca9-d99c-41a0-9582-aea2b8a8a276","name":"日本旅行","rootTaskId":"9b35bfdc-9632-4e98-ae66-f259dcb6b4d7","createdAt":"2026-11-13T13:01:24.800Z"}]}"#)
    let projects = try await b.projects()
    #expect(projects.first?.name == "日本旅行")
}

@Test func decodesNullCoordinatesAsNil() async throws {
    let b = backend(#"{"projectId":"p","task":{"id":"t","name":"大阪"},"breadcrumb":[{"id":"t","name":"大阪"}],"version":3,"children":[{"id":"c","name":"新","short":"新","place":"","address":"","lat":null,"lng":null,"completed":false,"prerequisites":[],"childCount":0}]}"#)
    let level = try await b.level("t")
    #expect(level.children.first?.lat == nil)
    #expect(level.version == 3)
}

@Test func mapsApiErrorsToBackendError() async throws {
    let b = backend(#"{"error":"version_conflict","message":"This level changed since it was loaded"}"#, status: .conflict)
    await #expect(throws: BackendError.api(status: 409, code: "version_conflict", message: "This level changed since it was loaded")) {
        _ = try await b.reorder("t", ids: [], version: 0)
    }
}
