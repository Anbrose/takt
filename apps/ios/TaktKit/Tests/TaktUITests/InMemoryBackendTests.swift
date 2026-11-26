import Foundation
import Testing
import TaktAPI
@testable import TaktUI

private func status(_ e: Error) -> (Int, String)? {
    if case BackendError.api(let s, let c, _) = e { return (s, c) }
    return nil
}

private func expectError(_ s: Int, _ code: String, _ op: () async throws -> Void) async {
    do {
        try await op()
        Issue.record("expected \(s) \(code)")
    } catch {
        #expect(status(error)?.0 == s && status(error)?.1 == code, "\(error)")
    }
}

/// Project with 大阪 (2 children: a, b) and 东京 (empty).
private func tree() async throws -> (b: InMemoryBackend, root: String, osaka: String, tokyo: String, a: String, c: String) {
    let b = InMemoryBackend()
    let p = try await b.createProject(name: "日本")
    let osaka = await b.add(parent: p.rootTaskId, name: "大阪")
    let tokyo = await b.add(parent: p.rootTaskId, name: "东京")
    let a = await b.add(parent: osaka, name: "大阪城")
    let c = await b.add(parent: osaka, name: "道顿堀")
    return (b, p.rootTaskId, osaka, tokyo, a, c)
}

@Suite struct InMemoryBackendTests {
    @Test func moveIntoAndBack() async throws {
        let t = try await tree()
        let before = try await t.b.level(t.tokyo).version
        let r = try await t.b.moveTask(t.a, to: t.tokyo, before: nil)
        #expect(r.from.task.id == t.osaka && r.from.children.map(\.id) == [t.c])
        #expect(r.to.task.id == t.tokyo && r.to.children.map(\.id) == [t.a])
        #expect(r.to.version > before)
        #expect(r.from.version == (try await t.b.level(t.osaka).version))
        // And back, before the remaining sibling.
        let back = try await t.b.moveTask(t.a, to: t.osaka, before: t.c)
        #expect(back.to.children.map(\.id) == [t.a, t.c])
        #expect(back.from.children.isEmpty)
    }

    @Test func moveWithinSameParentIsOneLevel() async throws {
        let t = try await tree()
        let v = try await t.b.level(t.osaka).version
        let r = try await t.b.moveTask(t.c, to: t.osaka, before: t.a)
        #expect(r.from.children.map(\.id) == [t.c, t.a] && r.to.children.map(\.id) == [t.c, t.a])
        #expect(r.to.version > v)
    }

    @Test func moveIntoDescendantThrows() async throws {
        let t = try await tree()
        await expectError(400, "move_into_self") { _ = try await t.b.moveTask(t.osaka, to: t.a, before: nil) }
        await expectError(400, "move_into_self") { _ = try await t.b.moveTask(t.osaka, to: t.osaka, before: nil) }
    }

    @Test func moveErrors() async throws {
        let t = try await tree()
        await expectError(400, "root_task") { _ = try await t.b.moveTask(t.root, to: t.osaka, before: nil) }
        await expectError(404, "not_found") { _ = try await t.b.moveTask("nope", to: t.osaka, before: nil) }
        await expectError(404, "not_found") { _ = try await t.b.moveTask(t.a, to: "nope", before: nil) }
        await expectError(400, "bad_before") { _ = try await t.b.moveTask(t.a, to: t.tokyo, before: t.c) }
        let other = try await t.b.createProject(name: "别的")
        await expectError(400, "cross_project") { _ = try await t.b.moveTask(t.a, to: other.rootTaskId, before: nil) }
    }

    @Test func importBefore() async throws {
        let b = InMemoryBackend()
        let p = try await b.createProject(name: "京都")
        let x = await b.add(parent: p.rootTaskId, name: "甲")
        let y = await b.add(parent: p.rootTaskId, name: "乙")
        let noteId = "11111111-1111-4111-8111-111111111111"
        _ = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: Date())
        _ = try await b.updateNote(
            noteId, title: nil, durationMs: nil,
            transcript: [TranscriptLine(startMs: 0, endMs: 1000, text: "去伏见稻荷", speaker: "1")], speakers: nil)
        let draft = try await b.extract(note: noteId)
        let chain = draft.extraction.chains[0]
        let pick = ImportPick(chainId: chain.id, stepIds: chain.steps.map(\.id), places: [:])
        let r = try await b.importNote(noteId, parent: p.rootTaskId, picks: [pick], before: y)
        let ids = r.level.children.map(\.id)
        #expect(ids.count == 3 && ids[0] == x && ids[2] == y)
        #expect(r.level.children[1].name == "去伏见稻荷")

        await expectError(400, "bad_before") {
            _ = try await b.importNote(noteId, parent: p.rootTaskId, picks: [], before: "nope")
        }
    }

    @Test func searchGroups() async throws {
        let b = await InMemoryBackend.sample()
        let r = try await b.search("京都")
        #expect(r.projects.isEmpty && r.tasks.isEmpty)
        #expect(r.notes.count == 3)  // title + the 2 matching lines
        #expect(r.notes[0].lineIndex == nil && r.notes[0].title == "京都讨论")
        #expect(r.notes.dropFirst().allSatisfy { $0.lineIndex != nil && $0.startMs != nil })

        let up = try await b.search("teamlab")
        #expect(up.tasks.map(\.name) == ["teamLab Planets"])
        #expect(up.tasks[0].path == ["日本旅行", "东京"])
        #expect(up.tasks[0].parentTaskId.isEmpty == false)

        let proj = try await b.search("日本")
        #expect(proj.projects.map(\.name) == ["日本旅行"])
        #expect(try await b.search("zzzz").tasks.isEmpty)
    }
}
