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

private let noteJSON = #"{"id":"5f1c7a0e-4e0b-4a3a-9d7e-0c6f2f8f1a11","title":"2026-11-24 09:00","locale":"zh-CN","durationMs":50340,"createdAt":"2026-11-24T09:00:00.000Z","hasTranscript":true,"chainCount":1,"importedCount":1,"transcript":[{"startMs":0,"endMs":5800,"text":"下周去京都","speaker":"1"},{"startMs":6000,"endMs":11800,"text":"好","speaker":null}],"speakers":[{"id":"1","name":"我"}],"segments":[{"index":0,"durationMs":50340,"uploaded":true}],"extraction":{"version":2,"chains":[{"id":"0b6c1f0e-1111-4222-8333-444455556666","name":"京都","steps":[{"id":"0b6c1f0e-1111-4222-8333-777788889999","name":"订酒店","place":null,"quote":{"startMs":6000,"endMs":11800}}]}]},"imported":[{"stepId":"0b6c1f0e-1111-4222-8333-aaaabbbbcccc","chainName":"京都","stepName":"买车票","taskId":"0b6c1f0e-1111-4222-8333-ddddeeeeffff","parentTaskId":"0b6c1f0e-1111-4222-8333-000011112222","importedAt":"2026-11-24T10:15:30.123Z"}]}"#

@Test func decodesANote() async throws {
    let n = try await backend(noteJSON).note("5f1c7a0e-4e0b-4a3a-9d7e-0c6f2f8f1a11")
    #expect(n.durationMs == 50340)
    #expect(n.transcript.map(\.speaker) == ["1", nil])
    #expect(n.extraction.version == 2)
    #expect(n.extraction.chains[0].steps[0].place == nil)
    #expect(n.imported[0].stepId == "0b6c1f0e-1111-4222-8333-aaaabbbbcccc")
}

@Test func decodesAnImportResult() async throws {
    let level = #"{"projectId":"p","task":{"id":"t","name":"京都"},"breadcrumb":[{"id":"t","name":"京都"}],"version":4,"children":[]}"#
    let b = backend(#"{"level":\#(level),"note":\#(noteJSON)}"#)
    let r = try await b.importNote("n", parent: "t", picks: [ImportPick(chainId: "c", stepIds: ["s"], places: [:])])
    #expect(r.level.version == 4)
    #expect(r.note.importedCount == 1)
}

@Test func decodesAudioUrls() async throws {
    let b = backend(#"{"segments":[{"index":0,"durationMs":1000,"url":"https://storage.example/a.m4a","expiresAt":"2026-11-24T10:00:00.000Z"}]}"#)
    let urls = try await b.noteAudio("n")
    #expect(urls.segments.first?.url == "https://storage.example/a.m4a")
}

@Test func mapsExtractLimitToItsCode() async throws {
    let b = backend(#"{"error":"extract_limit","message":"Extraction limit for this note reached"}"#, status: .tooManyRequests)
    await #expect(throws: BackendError.api(status: 429, code: "extract_limit", message: "Extraction limit for this note reached")) {
        _ = try await b.extract(note: "n")
    }
}

@Test func importPickWrapsPlacesAsADictionary() throws {
    let place = PickedPlace(place: "伏见稻荷大社", address: "京都", lat: 34.97, lng: 135.77)
    let pick = ImportPick(chainId: "c", stepIds: ["s"], places: ["s": place])
    #expect(pick.placesByStep["s"] == place)
    let json = String(decoding: try JSONEncoder().encode(pick), as: UTF8.self)
    #expect(json.contains(#""places":{"s":{"#))
    #expect(ImportPick(chainId: "c", stepIds: ["s"], places: [:]).places == nil)
}
