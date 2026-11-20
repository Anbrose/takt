import Foundation
import Observation
import os
import TaktAPI

private let log = Logger(subsystem: "dev.takt.app", category: "app")

/// Navigation through the task tree (任意一级都是同一套界面) for one project.
@MainActor
@Observable
public final class PlanModel {
    public enum Direction: Sendable { case forward, back }

    public let project: Project
    private let backend: any TaktBackend
    /// Level models by task id, kept so selection survives going back and forth.
    private var models: [String: LevelModel] = [:]

    /// Task ids from the project root to the current level.
    public private(set) var path: [String]
    public private(set) var direction: Direction = .forward

    /// 地图 on/off — shared by all levels, closes when moving between levels.
    public var mapOn = false

    public init(project: Project, backend: any TaktBackend) {
        self.project = project
        self.backend = backend
        self.path = [project.rootTaskId]
    }

    public var current: LevelModel { model(for: path.last ?? project.rootTaskId) }
    public var isRoot: Bool { path.count <= 1 }
    /// Small line above the title: "Project" at the root, otherwise the parent's name.
    public var overline: String {
        isRoot ? "Project" : current.breadcrumb.dropLast().last?.name ?? project.name
    }

    public func model(for taskId: String) -> LevelModel {
        if let m = models[taskId] { return m }
        let m = LevelModel(taskId: taskId, backend: backend)
        models[taskId] = m
        return m
    }

    /// Enter a child task's level ("N 项 ›"). Unsaved drags on the level being left are dropped.
    public func open(_ taskId: String) {
        current.cancel()
        mapOn = false
        direction = .forward
        path.append(taskId)
    }

    public func back() {
        guard !isRoot else { return }
        current.cancel()
        mapOn = false
        direction = .back
        path.removeLast()
    }
}

/// Loads the first project (no Project list page yet — see HANDOFF 原型的限制 5).
@MainActor
@Observable
public final class AppModel {
    public enum Phase {
        case loading
        case empty
        case failed(String)
        case ready(PlanModel)
    }

    public private(set) var phase: Phase = .loading
    private let backend: any TaktBackend

    public init(backend: any TaktBackend) {
        self.backend = backend
    }

    public func start() async {
        phase = .loading
        do {
            if let first = try await backend.projects().first {
                phase = .ready(PlanModel(project: first, backend: backend))
            } else {
                phase = .empty
            }
        } catch {
            log.error("start failed: \(String(describing: error), privacy: .public)")
            phase = .failed("连不上服务器")
        }
    }

    public func createProject(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let p = try await backend.createProject(name: name)
            phase = .ready(PlanModel(project: p, backend: backend))
        } catch {
            phase = .failed("新建失败")
        }
    }
}
