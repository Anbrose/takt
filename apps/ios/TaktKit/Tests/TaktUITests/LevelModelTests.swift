import Testing
import TaktAPI
@testable import TaktUI

@MainActor
private func osakaModel() async throws -> (LevelModel, InMemoryBackend) {
    let backend = await InMemoryBackend.sample()
    let project = try await backend.projects()[0]
    let root = try await backend.level(project.rootTaskId)
    let m = LevelModel(taskId: root.children[0].id, backend: backend)
    await m.load()
    // Equal row heights keep the drop maths easy to read: centre spacing = 60 + 10.
    for t in m.items { m.rowHeights[t.id] = 60 }
    return (m, backend)
}

@MainActor
private func names(_ m: LevelModel) -> [String] { m.items.map(\.name) }

@MainActor
@Suite struct LevelModelTests {
    @Test func loadsTheLevelInOrder() async throws {
        let (m, _) = try await osakaModel()
        #expect(m.name == "大阪")
        #expect(m.breadcrumb.map(\.name) == ["日本旅行", "大阪"])
        #expect(names(m).first == "大阪城天守阁")
        #expect(!m.isEditing)
    }

    @Test func selectionDecidesScopeNotOrder() async throws {
        let (m, _) = try await osakaModel()
        let before = names(m)
        m.toggle(m.items[3].id)
        m.toggle(m.items[1].id)
        #expect(m.selection.count == 2)
        #expect(names(m) == before)
    }

    @Test func deleteRemovesTheRowAndItsSelection() async throws {
        let (m, backend) = try await osakaModel()
        let usj = m.items[1].id
        m.toggle(usj)
        await m.delete(usj)
        #expect(!names(m).contains("日本环球影城"))
        #expect(m.items.count == 5)
        #expect(m.selection.isEmpty)
        #expect(try await backend.level(m.taskId).children.count == 5)
        // The returned level carries the new version, so saving an order still works.
        m.move(m.items[0].id, by: 1)
        await m.save()
        #expect(m.notice == nil)
    }

    @Test func deleteRollsBackWhenTheServerFails() async throws {
        let (m, backend) = try await osakaModel()
        let before = names(m)
        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        await m.delete(m.items[2].id)
        #expect(names(m) == before)
        #expect(m.notice == "删除失败")
    }

    @Test func deleteIsNotOfferedWhileReordering() async throws {
        let (m, backend) = try await osakaModel()
        m.move(m.items[0].id, by: 1)
        await m.delete(m.items[0].id)
        #expect(m.items.count == 6)
        #expect(await backend.calls.contains { $0.hasPrefix("deleteTask") } == false)
    }

    @Test func dragMakesADraftAndNeighboursMakeRoom() async throws {
        let (m, backend) = try await osakaModel()
        let ids = m.items.map(\.id)
        m.beginDrag(ids[0])
        #expect(m.isEditing)
        m.updateDrag(offset: 150) // passes two centres (70, 140)
        #expect(m.drag?.to == 2)
        #expect(m.shift(for: ids[1]) == -70)
        #expect(m.shift(for: ids[2]) == -70)
        #expect(m.shift(for: ids[3]) == 0)
        #expect(m.liveOrder == [ids[1], ids[2], ids[0], ids[3], ids[4], ids[5]])
        m.endDrag()
        #expect(m.drag == nil)
        #expect(m.items.map(\.id) == [ids[1], ids[2], ids[0], ids[3], ids[4], ids[5]])
        #expect(m.isEditing) // draft still unsaved
        #expect(await backend.calls.contains { $0.hasPrefix("reorder") } == false)
    }

    @Test func cancelRestoresTheSavedOrder() async throws {
        let (m, _) = try await osakaModel()
        let before = names(m)
        m.move(m.items[0].id, by: 1)
        #expect(names(m) != before)
        m.cancel()
        #expect(names(m) == before)
        #expect(!m.isEditing)
    }

    @Test func saveSendsTheWholeOrderOnce() async throws {
        let (m, backend) = try await osakaModel()
        let ids = m.items.map(\.id)
        m.move(ids[5], by: -1)
        m.move(ids[5], by: -1)
        await m.save()
        #expect(!m.isEditing)
        let expected = [ids[0], ids[1], ids[2], ids[5], ids[3], ids[4]]
        #expect(m.items.map(\.id) == expected)
        let reorders = await backend.calls.filter { $0.hasPrefix("reorder") }
        #expect(reorders.count == 1)
        // The server now has the new order too.
        let fresh = try await backend.level(m.taskId)
        #expect(fresh.children.map(\.id) == expected)
    }

    @Test func versionConflictReloadsAndTellsTheUser() async throws {
        let (m, backend) = try await osakaModel()
        m.move(m.items[0].id, by: 1)
        await backend.touch(m.taskId)
        await m.save()
        #expect(m.notice == "已在别处修改")
        #expect(!m.isEditing)
        #expect(names(m).first == "大阪城天守阁")
    }

    @Test func keyboardMoveStopsAtTheEnds() async throws {
        let (m, _) = try await osakaModel()
        let first = m.items[0].id
        m.move(first, by: -1)
        #expect(!m.isEditing)
        let last = m.items[5].id
        m.move(last, by: 1)
        #expect(!m.isEditing)
    }

    @Test func createAppendsAtTheEndOfThisLevel() async throws {
        let (m, backend) = try await osakaModel()
        #expect(await m.create(name: "  ", place: "", prerequisites: []) == false)
        #expect(await m.create(name: "黑门市场", place: "中央区", prerequisites: ["查营业时间", " "]))
        #expect(names(m).last == "黑门市场")
        #expect(m.items.last?.prerequisites.map(\.urgency) == [.before])
        #expect(m.lastAdded == m.items.last?.id)
        // Local version tracks the server's, so a following save is accepted.
        m.move(m.items[6].id, by: -1)
        await m.save()
        #expect(m.notice == nil)
        #expect(try await backend.level(m.taskId).children[5].name == "黑门市场")
    }

    @Test func createWhileEditingKeepsTheDraft() async throws {
        let (m, _) = try await osakaModel()
        m.move(m.items[0].id, by: 1)
        let draft = m.items.map(\.id)
        _ = await m.create(name: "新", place: "", prerequisites: [])
        #expect(m.isEditing)
        #expect(Array(m.items.map(\.id).prefix(6)) == draft)
        #expect(m.items.last?.name == "新")
    }

    @Test func failuresBecomeShortNotices() async throws {
        let (m, backend) = try await osakaModel()
        m.move(m.items[0].id, by: 1)
        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        await m.save()
        #expect(m.notice == "保存失败")
        #expect(m.isEditing) // draft kept so the user can retry
    }
}

@MainActor
@Suite struct PlanModelTests {
    @Test func navigatesAnyDepthAndKeepsSelection() async throws {
        let backend = await InMemoryBackend.sample()
        let project = try await backend.projects()[0]
        let plan = PlanModel(project: project, backend: backend)
        await plan.current.load()
        #expect(plan.isRoot && plan.overline == "Project")
        let osaka = plan.current.items[0]
        plan.current.toggle(plan.current.items[1].id)

        plan.open(osaka.id)
        #expect(plan.direction == .forward && !plan.isRoot)
        await plan.current.load()
        #expect(plan.overline == "日本旅行")
        plan.current.move(plan.current.items[0].id, by: 1)

        plan.back()
        #expect(plan.direction == .back && plan.isRoot)
        #expect(plan.current.selection.count == 1)
        #expect(!plan.model(for: osaka.id).isEditing) // leaving a level drops its unsaved drag
    }

    @Test func appStartsWithTheFirstProjectOrEmpty() async throws {
        let empty = AppModel(backend: InMemoryBackend())
        await empty.start()
        guard case .empty = empty.phase else { Issue.record("expected empty"); return }
        await empty.createProject(name: "周末")
        guard case .ready(let plan) = empty.phase else { Issue.record("expected ready"); return }
        #expect(plan.project.name == "周末")
    }
}
