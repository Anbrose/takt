import Foundation
import Observation
import TaktAPI
import TaktCore

/// State of one level of the plan: its tasks, the 勾选 scope, and the unsaved drag order.
@MainActor
@Observable
public final class LevelModel {
    public static let rowGap: Double = 10

    public struct Drag: Equatable, Sendable {
        public var id: String
        public var from: Int
        public var to: Int
        public var offset: Double
    }

    public enum Status: Equatable { case idle, loading, saving }

    public let taskId: String
    private let backend: any TaktBackend

    public private(set) var level: Level?
    public private(set) var status: Status = .idle
    /// Short, user-facing message for the last failure ("保存失败", …). Cleared on the next action.
    public var notice: String?

    /// 勾选: only decides scope, never order. Kept in memory per level.
    public private(set) var selection: Set<String> = []
    /// Unsaved order (保存前不落库). nil when the list shows the saved order.
    public private(set) var draft: [String]?
    public private(set) var drag: Drag?
    /// Measured row heights, used to decide where a dragged row lands.
    public var rowHeights: [String: Double] = [:]
    /// Id of the task just created, for its entry animation.
    public private(set) var lastAdded: String?

    public init(taskId: String, backend: any TaktBackend, level: Level? = nil) {
        self.taskId = taskId
        self.backend = backend
        self.level = level
    }

    // MARK: Derived

    public var name: String { level?.task.name ?? "" }
    public var breadcrumb: [Crumb] { level?.breadcrumb ?? [] }
    public var isEditing: Bool { drag != nil || draft != nil }

    /// Tasks in the order currently shown (draft if any, else saved).
    public var items: [TaskSummary] {
        guard let children = level?.children else { return [] }
        guard let draft else { return children }
        let byId = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        return draft.compactMap { byId[$0] }
    }

    public var scopeAll: Bool { selection.isEmpty }
    public var allLabel: String { scopeAll ? "全选" : "清空" }
    public var scopeLabel: String { scopeAll ? "\(items.count) 项" : "已选 \(selection.count) 项" }

    /// Ids in the order they'd have if the current drag were released now.
    public var liveOrder: [String] {
        let ids = items.map(\.id)
        guard let drag else { return ids }
        return Order.move(ids, from: drag.from, to: drag.to)
    }

    /// Vertical shift for a row while another row is being dragged (others 让位).
    public func shift(for id: String) -> Double {
        guard let drag, id != drag.id, let i = items.firstIndex(where: { $0.id == id }) else { return 0 }
        let amount = (rowHeights[drag.id] ?? 0) + Self.rowGap
        if i > drag.from && i <= drag.to { return -amount }
        if i < drag.from && i >= drag.to { return amount }
        return 0
    }

    // MARK: Loading

    public func load() async {
        status = .loading
        defer { status = .idle }
        do {
            level = try await backend.level(taskId)
            pruneSelection()
        } catch {
            notice = "加载失败"
        }
    }

    // MARK: 勾选

    public func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func toggleAll() {
        selection = scopeAll ? Set(items.map(\.id)) : []
    }

    public func isSelected(_ id: String) -> Bool { selection.contains(id) }

    // MARK: 拖动排序

    public func beginDrag(_ id: String) {
        guard drag == nil, let i = items.firstIndex(where: { $0.id == id }) else { return }
        notice = nil
        drag = Drag(id: id, from: i, to: i, offset: 0)
    }

    public func updateDrag(offset: Double) {
        guard var d = drag else { return }
        let heights = items.map { rowHeights[$0.id] ?? 0 }
        d.offset = offset
        d.to = Order.dropIndex(heights: heights, gap: Self.rowGap, from: d.from, offset: offset)
        drag = d
    }

    /// Releases the drag: the new order becomes the draft (not saved yet).
    public func endDrag() {
        guard drag != nil else { return }
        draft = liveOrder
        drag = nil
    }

    /// Keyboard / VoiceOver: move one row up (-1) or down (+1).
    public func move(_ id: String, by delta: Int) {
        let ids = items.map(\.id)
        guard drag == nil, let i = ids.firstIndex(of: id) else { return }
        let j = i + delta
        guard ids.indices.contains(j) else { return }
        draft = Order.move(ids, from: i, to: j)
    }

    /// 取消: drop the draft; rows slide back to the saved order.
    public func cancel() {
        drag = nil
        draft = nil
    }

    /// 保存: one call with the whole order. On a version conflict the level is reloaded.
    public func save() async {
        guard let draft, let level else { return }
        status = .saving
        defer { status = .idle }
        do {
            self.level = try await backend.reorder(taskId, ids: draft, version: level.version)
            self.draft = nil
        } catch let e as BackendError where e.isVersionConflict || e.code == "not_a_permutation" {
            self.draft = nil
            notice = "已在别处修改"
            await load()
        } catch {
            notice = "保存失败"
        }
    }

    // MARK: 新建

    /// Appends a task to this level. Prerequisites default to 行前订.
    @discardableResult
    public func create(name: String, place: String, prerequisites: [String]) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        let pres = prerequisites
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { NewPrerequisite(action: $0, urgency: .before) }
        let body = CreateTaskBody(
            name: name,
            place: place.isEmpty ? nil : place,
            prerequisites: pres.isEmpty ? nil : pres
        )
        do {
            let task = try await backend.createTask(in: taskId, body)
            guard var level else { return true }
            level.children.append(task)
            level.version += 1
            self.level = level
            if draft != nil { draft?.append(task.id) }
            lastAdded = task.id
            return true
        } catch {
            notice = "新建失败"
            return false
        }
    }

    private func pruneSelection() {
        let ids = Set(level?.children.map(\.id) ?? [])
        selection.formIntersection(ids)
        if let d = draft, Set(d) != ids { draft = nil }
    }
}
