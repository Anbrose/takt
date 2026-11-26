import Foundation
import SwiftUI
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
    private let pause: @MainActor (Duration) async -> Void

    /// A search hit's row stays outlined this long (prototype 1600 ms).
    public static let hitFlashTime: Duration = .milliseconds(1600)

    public init(
        project: Project, backend: any TaktBackend,
        pause: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.project = project
        self.backend = backend
        self.pause = pause
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
        let m = LevelModel(taskId: taskId, backend: backend, pause: pause)
        // A move changes two levels; the other one may be cached here (the parent after 移到上一级, the row
        // a task was put into).
        // A level's own 「N 项」 sits on the level above it.
        m.onMoved = { [weak self] from, to in
            guard let self else { return }
            self.models[to.task.id]?.show(to)
            for l in [from, to] {
                if let up = l.breadcrumb.dropLast().last { self.models[up.id]?.setChildCount(l.task.id, l.children.count) }
            }
        }
        models[taskId] = m
        return m
    }

    /// Opens `taskId`'s level straight away (from 查找), with `flash` outlined. Back then walks up through
    /// every level above it, which are known once the level has loaded.
    /// The level shows at once (loading); the returned task finishes once it has loaded and the row is flashed.
    @discardableResult
    public func reveal(level taskId: String, flash: String?) -> Task<Void, Never> {
        direction = .forward
        path = taskId == project.rootTaskId ? [taskId] : [project.rootTaskId, taskId]
        let m = model(for: taskId)
        return Task { [weak self] in
            if m.level == nil { await m.load() }
            guard let self, self.path.last == taskId else { return }
            let ids = m.breadcrumb.map(\.id)
            if ids.first == self.project.rootTaskId, ids.last == taskId { self.path = ids }
            if let flash { m.flash(flash, for: Self.hitFlashTime) }
        }
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

/// Project 列表 and the project that is open on top of it.
/// Mutations take the animation to run them in, so the list never changes in a single frame.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case loading
        case failed(String)
        case ready
    }

    public private(set) var phase: Phase = .loading
    /// Newest first (the server's order).
    public private(set) var projects: [Project] = []
    /// The project being planned, pushed over the list; nil = the list is showing.
    public private(set) var open: PlanModel?
    /// Short failure message for the list's toast.
    public var notice: String?
    private let backend: any TaktBackend

    public init(backend: any TaktBackend) {
        self.backend = backend
    }

    public func start(animation: Animation? = nil) async {
        if case .ready = phase {} else { phase = .loading }
        do {
            let list = try await backend.projects()
            withAnimation(animation) {
                projects = list
                phase = .ready
            }
        } catch {
            log.error("start failed: \(String(describing: error), privacy: .public)")
            withAnimation(animation) { phase = .failed("连不上服务器") }
        }
    }

    public func openProject(_ project: Project, animation: Animation? = nil) {
        withAnimation(animation) { open = PlanModel(project: project, backend: backend) }
    }

    /// A plan for a project on the list, opened from 查找 (pushed over the search, not over the list).
    public func plan(for projectId: String) -> PlanModel? {
        projects.first { $0.id == projectId }.map { PlanModel(project: $0, backend: backend) }
    }

    public func closeProject(animation: Animation? = nil) {
        open?.current.cancel()
        withAnimation(animation) { open = nil }
    }

    /// Creates at the top of the list. Returns the project, or nil (with a notice) on failure.
    @discardableResult
    public func createProject(name: String, animation: Animation? = nil) async -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let p = try await backend.createProject(name: name)
            withAnimation(animation) { projects.insert(p, at: 0) }
            return p
        } catch {
            log.error("create project failed: \(String(describing: error), privacy: .public)")
            withAnimation(animation) { notice = "新建失败" }
            return nil
        }
    }

    /// Optimistic: the name changes at once and rolls back if the server refuses.
    @discardableResult
    public func renameProject(_ id: String, to name: String, animation: Animation? = nil) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return false }
        let before = projects[i]
        guard before.name != name else { return true }
        withAnimation(animation) { projects[i].name = name }
        do {
            let saved = try await backend.renameProject(id, name: name)
            if let j = projects.firstIndex(where: { $0.id == id }) { projects[j] = saved }
            return true
        } catch {
            log.error("rename project failed: \(String(describing: error), privacy: .public)")
            withAnimation(animation) {
                if let j = projects.firstIndex(where: { $0.id == id }) { projects[j] = before }
                notice = "重命名失败"
            }
            return false
        }
    }

    /// Optimistic: the card collapses at once and comes back if the server refuses.
    public func deleteProject(_ id: String, animation: Animation? = nil) async {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects[i]
        withAnimation(animation) { _ = projects.remove(at: i) }
        do {
            try await backend.deleteProject(id)
        } catch {
            log.error("delete project failed: \(String(describing: error), privacy: .public)")
            withAnimation(animation) {
                projects.insert(removed, at: min(i, projects.count))
                notice = "删除失败"
            }
        }
    }
}
