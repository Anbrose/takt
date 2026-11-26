import Foundation
import Observation
import TaktAPI

/// One result row: the matched text split around the first match (for the highlight), a second line, and where
/// tapping it goes.
public struct SearchHit: Equatable, Identifiable, Sendable {
    public enum Target: Equatable, Sendable {
        case project(id: String)
        /// Opens `parentTaskId`'s level with the row flashed.
        case task(id: String, projectId: String, parentTaskId: String)
        /// `lineIndex` nil = the title matched.
        case note(id: String, lineIndex: Int?, startMs: Int?)
    }

    public var id: String
    public var text: String
    public var pre: String
    public var hit: String
    public var post: String
    /// Task: 「Project › 父任务」; transcript line: 「标题 · m:ss」; otherwise empty.
    public var sub: String
    public var target: Target
}

public struct SearchGroup: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case projects, tasks, notes }
    public var kind: Kind
    public var hits: [SearchHit]
    public var id: Kind { kind }
    public var title: String {
        switch kind {
        case .projects: "Project"
        case .tasks: "任务"
        case .notes: "笔记"
        }
    }
}

/// 查找: Project, task and note hits for what is typed, fetched 250 ms after typing stops.
@MainActor
@Observable
public final class SearchModel {
    public static let debounce: Duration = .milliseconds(250)

    private let backend: any TaktBackend
    private let sleep: @Sendable (Duration) async -> Void

    /// Blank clears the results without a call; each change cancels the search still waiting or running.
    public var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    public private(set) var groups: [SearchGroup] = []
    /// Short, user-facing message for the last failure. Cleared on the next search.
    public var notice: String?
    /// The pending or running search (test seam).
    private(set) var searchTask: Task<Void, Never>?

    /// `sleep` waits out the debounce; tests pass a clock they control.
    public init(
        backend: any TaktBackend,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.backend = backend
        self.sleep = sleep
    }

    private func schedule() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchTask = nil
            groups = []
            notice = nil
            return
        }
        let backend = backend, sleep = sleep
        searchTask = Task { [weak self] in
            await sleep(Self.debounce)
            guard !Task.isCancelled else { return }
            let result: Result<SearchResult, Error>
            do { result = .success(try await backend.search(q)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let r):
                notice = nil
                groups = Self.groups(r, q)
            case .failure:
                notice = "查找失败"
            }
        }
    }

    static func groups(_ r: SearchResult, _ q: String) -> [SearchGroup] {
        func hit(_ id: String, _ text: String, _ sub: String, _ target: SearchHit.Target) -> SearchHit {
            let s = split(text, on: q)
            return SearchHit(id: id, text: text, pre: s.pre, hit: s.hit, post: s.post, sub: sub, target: target)
        }
        let all: [SearchGroup] = [
            SearchGroup(kind: .projects, hits: r.projects.map { hit($0.id, $0.name, "", .project(id: $0.id)) }),
            SearchGroup(kind: .tasks, hits: r.tasks.map {
                hit($0.id, $0.name, $0.path.joined(separator: " › "),
                    .task(id: $0.id, projectId: $0.projectId, parentTaskId: $0.parentTaskId))
            }),
            SearchGroup(kind: .notes, hits: r.notes.map { n in
                let sub = n.startMs.map { "\(n.title) · \(clock($0))" } ?? ""
                return hit("\(n.noteId)#\(n.lineIndex.map(String.init) ?? "title")", n.text, sub,
                           .note(id: n.noteId, lineIndex: n.lineIndex, startMs: n.startMs))
            }),
        ]
        return all.filter { !$0.hits.isEmpty }
    }

    /// Splits `text` around the first case-insensitive match of `q`; no match → all in `pre`.
    public static func split(_ text: String, on q: String) -> (pre: String, hit: String, post: String) {
        guard !q.isEmpty, let r = text.range(of: q, options: [.caseInsensitive]) else { return (text, "", "") }
        return (String(text[..<r.lowerBound]), String(text[r]), String(text[r.upperBound...]))
    }

    /// `m:ss`, or `h:mm:ss` from an hour on.
    public static func clock(_ ms: Int) -> String {
        let t = max(ms, 0) / 1000
        let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
