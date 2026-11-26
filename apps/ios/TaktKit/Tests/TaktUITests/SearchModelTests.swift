import Foundation
import Testing
import TaktAPI
@testable import TaktUI

/// Stands in for the 250 ms wait: sleepers stay parked until the test opens the gate.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [Duration] = []

    func sleep(_ d: Duration) async {
        asked.append(d)
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private func sampleWithNote() async throws -> InMemoryBackend {
    let b = await InMemoryBackend.sample()
    let id = UUID().uuidString
    _ = try await b.createNote(id: id, title: "大阪笔记", locale: "zh-CN", createdAt: Date())
    _ = try await b.updateNote(
        id, title: nil, durationMs: nil,
        transcript: [TranscriptLine(startMs: 0, endMs: 1000, text: "你好", speaker: "1"),
                     TranscriptLine(startMs: 75_000, endMs: 80_000, text: "明天去大阪城", speaker: "1")],
        speakers: [Speaker(id: "1", name: "1")])
    return b
}

@MainActor
@Suite struct SearchModelTests {
    @Test func searchDebouncesAndGroups() async throws {
        let backend = try await sampleWithNote()
        let gate = Gate()
        let m = SearchModel(backend: backend, sleep: { await gate.sleep($0) })
        m.query = "大"
        m.query = "大阪"
        for _ in 0..<5 { await Task.yield() }
        #expect(await backend.calls.contains { $0.hasPrefix("search") } == false)
        await gate.release()
        await m.searchTask?.value
        #expect(await backend.calls.filter { $0.hasPrefix("search") } == ["search 大阪"])
        #expect(await gate.asked.allSatisfy { $0 == .milliseconds(250) })
        // 日本旅行 doesn't contain 大阪: no Project group.
        #expect(m.groups.map(\.title) == ["任务", "笔记"])
        let tasks = try #require(m.groups.first)
        #expect(tasks.hits.map(\.text) == ["大阪", "大阪城天守阁"])
        let osaka = try #require(tasks.hits.first { $0.text == "大阪" })
        #expect(osaka.sub == "日本旅行")
        let castle = try #require(tasks.hits.first { $0.text == "大阪城天守阁" })
        #expect(castle.sub == "日本旅行 › 大阪")
        guard case .task(_, _, let parent) = castle.target else { Issue.record("not a task"); return }
        #expect(parent == osaka.id)
        let notes = m.groups[1].hits
        #expect(notes.map(\.text) == ["大阪笔记", "明天去大阪城"])
        #expect(notes.map(\.sub) == ["", "大阪笔记 · 1:15"])
        guard case .note(_, let line, let ms) = notes[1].target else { Issue.record("not a note"); return }
        #expect(line == 1 && ms == 75_000)

        // Projects come first when they match.
        m.query = "旅行"
        await m.searchTask?.value
        #expect(m.groups.map(\.title) == ["Project"])
        #expect(m.groups[0].hits.map(\.text) == ["日本旅行"])

        // Blank clears without a call.
        m.query = "  "
        await m.searchTask?.value
        #expect(m.groups.isEmpty)
        #expect(await backend.calls.filter { $0.hasPrefix("search") }.count == 2)
    }

    @Test func answeredOnlyOnceTheResultsAreForTheQuery() async throws {
        let backend = await InMemoryBackend.sample()
        let gate = Gate()
        let m = SearchModel(backend: backend, sleep: { await gate.sleep($0) })
        #expect(!m.answered)
        m.query = "火星"
        #expect(!m.answered, "still waiting: no 无结果 yet")
        await gate.release()
        await m.searchTask?.value
        #expect(m.answered && m.groups.isEmpty)
        m.query = "火星人"
        #expect(!m.answered)
        await m.searchTask?.value
        #expect(m.answered)
        m.query = ""
        #expect(!m.answered)
    }

    @Test func searchHighlightSplit() {
        let s = SearchModel.split("Visit teamLab Planets", on: "TEAMLAB")
        #expect(s.pre == "Visit " && s.hit == "teamLab" && s.post == " Planets")
        let first = SearchModel.split("大阪 大阪城", on: "大阪")
        #expect(first.pre == "" && first.hit == "大阪" && first.post == " 大阪城")
        let none = SearchModel.split("东京", on: "大阪")
        #expect(none.pre == "东京" && none.hit == "" && none.post == "")
        #expect(SearchModel.clock(75_000) == "1:15")
        #expect(SearchModel.clock(3_725_000) == "1:02:05")
    }
}
