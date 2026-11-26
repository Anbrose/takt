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
    /// Row the dragged task would go into if released now (its middle band); highlighted.
    public private(set) var nestTarget: String?
    /// The view sets this while the drag is over the 「移到「上一级」」 zone; the rows then neither reorder nor nest.
    public var upZoneHot = false {
        didSet { if upZoneHot { nestTarget = nil } }
    }
    /// Released onto a row: waits for 「放入「X」？」.
    public private(set) var pendingNest: (id: String, into: String)?
    /// The move started by releasing in the up zone (test seam).
    public private(set) var moving: Task<Void, Never>?

    public init(taskId: String, backend: any TaktBackend, level: Level? = nil) {
        self.taskId = taskId
        self.backend = backend
        self.level = level
    }

    // MARK: Derived

    public var name: String { level?.task.name ?? "" }
    public var breadcrumb: [Crumb] { level?.breadcrumb ?? [] }
    /// The level containing this one (「上一级」). The breadcrumb ends with this level itself; nil on the first level.
    public var parentCrumb: Crumb? { breadcrumb.dropLast().last }
    public var isEditing: Bool { drag != nil || draft != nil }

    /// Tasks in the order currently shown (draft if any, else saved).
    public var items: [TaskSummary] {
        guard let children = level?.children else { return [] }
        guard let draft else { return children }
        let byId = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        return draft.compactMap { byId[$0] }
    }

    public var scopeAll: Bool { selection.isEmpty }

    /// Ids in the order they'd have if the current drag were released now.
    public var liveOrder: [String] {
        guard let drag else { return items.map(\.id) }
        return liveOrder(of: drag)
    }

    private func liveOrder(of drag: Drag) -> [String] {
        Order.move(items.map(\.id), from: drag.from, to: drag.to)
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

    public func isSelected(_ id: String) -> Bool { selection.contains(id) }

    // MARK: 拖动排序

    public func beginDrag(_ id: String) {
        guard drag == nil, let i = items.firstIndex(where: { $0.id == id }) else { return }
        notice = nil
        drag = Drag(id: id, from: i, to: i, offset: 0)
    }

    public func updateDrag(offset: Double) {
        guard var d = drag else { return }
        d.offset = offset
        if upZoneHot {
            nestTarget = nil
        } else {
            let heights = items.map { rowHeights[$0.id] ?? 0 }
            switch Order.dropTarget(heights: heights, gap: Self.rowGap, from: d.from, offset: offset) {
            case .reorder(let to):
                d.to = to
                nestTarget = nil
            case .into(let i):
                nestTarget = items[i].id
            }
        }
        drag = d
    }

    /// Releases the drag. Over a row's middle → asks before nesting; over the up zone → moves up a level at once;
    /// otherwise the new order becomes the draft (not saved yet).
    public func endDrag() {
        guard let d = drag else { return }
        let into = nestTarget
        drag = nil
        nestTarget = nil
        if upZoneHot {
            upZoneHot = false
            moving = Task { await promote(d.id) }
        } else if let into {
            pendingNest = (d.id, into)
        } else {
            draft = liveOrder(of: d)
        }
    }

    /// 放入: the task becomes the last child of the row it was dropped on. Saved at once.
    public func confirmNest() async {
        guard let p = pendingNest else { return }
        pendingNest = nil
        await move(p.id, to: p.into, before: nil)
    }

    public func cancelNest() { pendingNest = nil }

    /// Moves a child of this level up into the containing level, right after this level's own task.
    public func promote(_ id: String) async {
        guard let up = parentCrumb else { return }
        notice = nil
        do {
            let siblings = try await backend.level(up.id).children.map(\.id)
            let next = siblings.firstIndex(of: taskId).map { $0 + 1 }.flatMap { siblings.indices.contains($0) ? siblings[$0] : nil }
            await move(id, to: up.id, before: next)
        } catch {
            notice = "移动失败"
        }
    }

    /// Moves are saved right away; an unsaved order of this level keeps everything but the moved task.
    private func move(_ id: String, to parent: String, before: String?) async {
        notice = nil
        status = .saving
        defer { status = .idle }
        do {
            let r = try await backend.moveTask(id, to: parent, before: before)
            draft?.removeAll { $0 == id }
            selection.remove(id)
            level = r.from
            pruneSelection()
        } catch let e as BackendError where e.code == "not_found" || e.isVersionConflict {
            notice = "已在别处修改"
            await load()
        } catch {
            notice = "移动失败"
        }
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

    /// 重排: adopt the shortest-route order and save it right away (as in the prototype — no
    /// 取消 / 保存 step). Optimistic: the list reorders at once and rolls back if saving fails.
    public func applyOrder(_ ids: [String]) async {
        guard drag == nil, draft == nil, var current = level,
              ids.count == current.children.count, Set(ids) == Set(current.children.map(\.id))
        else { return }
        let before = current
        let byId = Dictionary(uniqueKeysWithValues: current.children.map { ($0.id, $0) })
        current.children = ids.compactMap { byId[$0] }
        level = current
        status = .saving
        defer { status = .idle }
        do {
            level = try await backend.reorder(taskId, ids: ids, version: before.version)
        } catch let e as BackendError where e.isVersionConflict || e.code == "not_a_permutation" {
            notice = "已在别处修改"
            await load()
        } catch {
            level = before
            notice = "保存失败"
        }
    }

    // MARK: 左滑删除

    /// Deletes a task (and everything under it). Optimistic: the row goes at once and comes back
    /// if the server refuses. Not offered while an order is being edited.
    public func delete(_ id: String) async {
        guard !isEditing, let before = level, before.children.contains(where: { $0.id == id }) else { return }
        var after = before
        after.children.removeAll { $0.id == id }
        level = after
        selection.remove(id)
        do {
            level = try await backend.deleteTask(id)
            pruneSelection()
        } catch let e as BackendError where e.code == "not_found" {
            await load() // already gone elsewhere
        } catch {
            level = before
            notice = "删除失败"
        }
    }

    // MARK: 新建

    /// Appends a task to this level. Prerequisites default to 行前订.
    /// `location` comes from the place search; typed-in text without a pick stays 未定位.
    @discardableResult
    public func create(
        name: String, place: String, location: PlaceChoice? = nil, prerequisites: [String]
    ) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let place = (location?.name ?? place).trimmingCharacters(in: .whitespacesAndNewlines)
        let pres = prerequisites
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { NewPrerequisite(action: $0, urgency: .before) }
        let address = location?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = CreateTaskBody(
            name: name,
            place: place.isEmpty ? nil : place,
            address: address.isEmpty ? nil : address,
            lat: location?.lat,
            lng: location?.lng,
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
