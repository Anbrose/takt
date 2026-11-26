import Foundation
import Observation
import TaktAPI

/// 「加入到项目」 dock under a dragged chain or step: the Project list, and one opened Project's first level.
@MainActor
@Observable
public final class ImportDockModel {
    private let backend: any TaktBackend

    public private(set) var projects: [Project] = []
    /// First-level task count per Project id (`N 项` on its row); missing until loaded, or when that load failed.
    public private(set) var counts: [String: Int] = [:]
    /// The Project hovered open and its first level (children in their saved order). nil = the Project list.
    public private(set) var opened: (project: Project, level: Level)?
    /// Short, user-facing message for the last failure. Cleared on the next action.
    public var notice: String?

    public init(backend: any TaktBackend) {
        self.backend = backend
    }

    public func load() async {
        notice = nil
        do {
            projects = try await backend.projects()
        } catch {
            notice = "加载失败"
            return
        }
        let backend = backend
        counts = await withTaskGroup(of: (String, Int)?.self) { group in
            for p in projects {
                group.addTask { (try? await backend.level(p.rootTaskId)).map { (p.id, $0.children.count) } }
            }
            var counts: [String: Int] = [:]
            for await case let (id, n)? in group { counts[id] = n }
            return counts
        }
    }

    /// Opens a Project's first level. An unknown id or a failed load leaves the dock as it was.
    public func open(_ projectId: String) async {
        guard let p = projects.first(where: { $0.id == projectId }) else { return }
        notice = nil
        do {
            let level = try await backend.level(p.rootTaskId)
            opened = (p, level)
        } catch {
            notice = "加载失败"
        }
    }

    /// The back area: returns to the Project list.
    public func back() { opened = nil }
}
