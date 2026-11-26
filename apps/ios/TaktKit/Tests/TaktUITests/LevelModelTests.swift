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
        m.updateDrag(offset: 160) // centre 190: past 72% of rows 1 and 2, short of row 3's middle band
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

    @Test func dragIntoAsksThenMoves() async throws {
        let (m, backend) = try await osakaModel()
        let ids = m.items.map(\.id)
        m.beginDrag(ids[0])
        m.updateDrag(offset: 70) // centre 100: middle band of row 1
        #expect(m.nestTarget == ids[1])
        #expect(m.drag?.to == 0)
        #expect(m.shift(for: ids[1]) == 0)
        m.endDrag()
        #expect(m.drag == nil && m.nestTarget == nil)
        #expect(m.pendingNest?.id == ids[0] && m.pendingNest?.into == ids[1])
        #expect(m.items.map(\.id) == ids) // nothing moved yet
        #expect(await backend.calls.contains { $0.hasPrefix("moveTask") } == false)

        await m.confirmNest()
        #expect(m.pendingNest == nil)
        #expect(m.items.map(\.id) == Array(ids.dropFirst()))
        #expect(m.items.first?.childCount == 1)
        #expect(!m.isEditing)
        #expect(try await backend.level(ids[1]).children.map(\.id) == [ids[0]])
        // Back to reorder: leaving the middle band clears the highlight.
        m.beginDrag(m.items[0].id)
        m.updateDrag(offset: 70)
        #expect(m.nestTarget == m.items[1].id)
        m.updateDrag(offset: 0)
        #expect(m.nestTarget == nil)
    }

    @Test func cancelNestKeepsTree() async throws {
        let (m, backend) = try await osakaModel()
        let ids = m.items.map(\.id)
        m.beginDrag(ids[2])
        m.updateDrag(offset: -70) // centre into row 1's middle band
        #expect(m.nestTarget == ids[1])
        m.endDrag()
        m.cancelNest()
        #expect(m.pendingNest == nil)
        #expect(m.items.map(\.id) == ids)
        #expect(!m.isEditing)
        #expect(try await backend.level(m.taskId).children.map(\.id) == ids)
        #expect(await backend.calls.contains { $0.hasPrefix("moveTask") } == false)
    }

    @Test func promotePlacesAfterParent() async throws {
        let (m, backend) = try await osakaModel()
        let project = try await backend.projects()[0]
        #expect(m.parentCrumb?.id == project.rootTaskId)
        let ids = m.items.map(\.id)
        // Dragged into the 「移到「日本旅行」」 zone: no confirm, lands right after 大阪.
        m.beginDrag(ids[3])
        m.upZoneHot = true
        m.updateDrag(offset: 70)
        #expect(m.nestTarget == nil && m.drag?.to == 3)
        m.endDrag()
        await m.moving?.value
        #expect(m.pendingNest == nil)
        #expect(m.items.map(\.id) == ids.filter { $0 != ids[3] })
        let root = try await backend.level(project.rootTaskId)
        #expect(root.children.map(\.name) == ["大阪", "海游馆", "东京", "北海道"])

        // From the last child of the root, it goes to the end. On the first level there is no parent.
        let hokkaido = LevelModel(taskId: root.children[3].id, backend: backend)
        await hokkaido.load()
        await hokkaido.promote(hokkaido.items[0].id)
        let after = try await backend.level(project.rootTaskId)
        #expect(after.children.map(\.name) == ["大阪", "海游馆", "东京", "北海道", "大通公园"])
        let first = LevelModel(taskId: project.rootTaskId, backend: backend)
        await first.load()
        #expect(first.parentCrumb == nil)
    }

    @Test func moveDropsIdFromDraft() async throws {
        let (m, backend) = try await osakaModel()
        let ids = m.items.map(\.id)
        m.move(ids[5], by: -1) // draft: 0 1 2 3 5 4
        m.beginDrag(ids[0])
        m.updateDrag(offset: 70)
        m.endDrag()
        await m.confirmNest()
        #expect(m.isEditing) // the rest of the draft is kept
        #expect(m.items.map(\.id) == [ids[1], ids[2], ids[3], ids[5], ids[4]])
        await m.save()
        #expect(m.notice == nil)
        #expect(try await backend.level(m.taskId).children.map(\.id) == [ids[1], ids[2], ids[3], ids[5], ids[4]])
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

    @Test func projectListCreateRenameDeleteAndOpen() async throws {
        let backend = InMemoryBackend()
        let app = AppModel(backend: backend)
        await app.start()
        #expect(app.phase == .ready && app.projects.isEmpty && app.open == nil)

        let a = try #require(await app.createProject(name: "  日本旅行 "))
        let b = try #require(await app.createProject(name: "搬家"))
        #expect(app.projects.map(\.name) == ["搬家", "日本旅行"]) // newest first
        #expect(await app.createProject(name: "  ") == nil)

        #expect(await app.renameProject(a.id, to: "关西之旅"))
        #expect(app.projects.map(\.name) == ["搬家", "关西之旅"])
        #expect(try await backend.level(a.rootTaskId).task.name == "关西之旅")

        app.openProject(app.projects[1])
        #expect(app.open?.project.name == "关西之旅" && app.open?.isRoot == true)
        app.closeProject()
        #expect(app.open == nil)

        await app.deleteProject(b.id)
        #expect(app.projects.map(\.id) == [a.id])
        #expect(try await backend.projects().map(\.id) == [a.id])
    }

    @Test func projectChangesRollBackWhenTheServerRefuses() async throws {
        let backend = InMemoryBackend()
        let app = AppModel(backend: backend)
        await app.start()
        let p = try #require(await app.createProject(name: "日本旅行"))

        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        #expect(await app.renameProject(p.id, to: "x") == false)
        #expect(app.projects[0].name == "日本旅行" && app.notice == "重命名失败")

        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        await app.deleteProject(p.id)
        #expect(app.projects.map(\.id) == [p.id] && app.notice == "删除失败")
    }

    @Test func startFailureShowsRetryState() async {
        let backend = InMemoryBackend()
        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        let app = AppModel(backend: backend)
        await app.start()
        #expect(app.phase == .failed("连不上服务器"))
        await app.start()
        #expect(app.phase == .ready)
    }
}
