import Testing
import TaktAPI
@testable import TaktUI

@MainActor
@Suite struct ImportDockModelTests {
    @Test func dockOpensProjectLevel() async throws {
        let backend = await InMemoryBackend.sample()
        let other = try await backend.createProject(name: "搬家")
        let m = ImportDockModel(backend: backend)
        await m.load()
        #expect(m.projects.map(\.name) == ["搬家", "日本旅行"])
        let trip = m.projects[1]
        // Children come in their saved order.
        let root = try await backend.level(trip.rootTaskId)
        let ids = root.children.map(\.id)
        _ = try await backend.reorder(trip.rootTaskId, ids: [ids[2], ids[0], ids[1]], version: root.version)

        await m.open(trip.id)
        #expect(m.opened?.project.id == trip.id)
        #expect(m.opened?.level.task.id == trip.rootTaskId)
        #expect(m.opened?.level.children.map(\.name) == ["北海道", "大阪", "东京"])
        m.back()
        #expect(m.opened == nil)

        await m.open(other.id)
        #expect(m.opened?.level.children.isEmpty == true)
        await m.open("missing")
        #expect(m.opened?.project.id == other.id) // unknown id: stays where it was
    }
}
