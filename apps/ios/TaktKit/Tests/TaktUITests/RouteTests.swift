import Foundation
import Testing
import TaktAPI
import TaktCore
@testable import TaktUI

/// Counts requests; fails for pairs listed in `failing`; returns 2× straight-line metres as "real".
private actor FakeRoutes: RouteProvider {
    var calls = 0
    var failing: Set<String> = []
    func fail(_ a: GeoPoint) { failing.insert("\(a.lat)") }
    func cost(from: GeoPoint, to: GeoPoint, mode: TravelMode) async throws -> LegCost {
        calls += 1
        if failing.contains("\(from.lat)") || failing.contains("\(to.lat)") { throw URLError(.cannotFindHost) }
        let s = LegCost.straightLine(from, to, mode: mode)
        return LegCost(meters: s.meters * 2, seconds: s.seconds * 2, estimated: false)
    }
}

@MainActor
private func waitIdle(_ m: RouteMatrix) async {
    for _ in 0..<200 where m.pending > 0 { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor
private func osaka() async throws -> (LevelModel, InMemoryBackend) {
    let backend = await InMemoryBackend.sample()
    let root = try await backend.level(try await backend.projects()[0].rootTaskId)
    let m = LevelModel(taskId: root.children[0].id, backend: backend)
    await m.load()
    return (m, backend)
}

@MainActor
@Suite struct RouteMatrixTests {
    let a = GeoPoint(lat: 34.6873, lng: 135.5262)
    let b = GeoPoint(lat: 34.6654, lng: 135.4323)
    let c = GeoPoint(lat: 34.6687, lng: 135.5013)

    @Test func estimatesUntilRealCostsArriveThenCachesSymmetrically() async {
        let fake = FakeRoutes()
        let m = RouteMatrix(provider: fake, cacheURL: nil)
        #expect(m.cost(a, b, mode: .walk).estimated)
        m.prefetch([a, b, c], mode: .walk)
        await waitIdle(m)
        #expect(await fake.calls == 3) // 3 unordered pairs, not 6
        let ab = m.cost(a, b, mode: .walk)
        #expect(!ab.estimated)
        #expect(m.cost(b, a, mode: .walk) == ab)
        m.prefetch([a, b, c], mode: .walk)
        await waitIdle(m)
        #expect(await fake.calls == 3) // cached
        m.prefetch([a, b], mode: .drive)
        await waitIdle(m)
        #expect(await fake.calls == 4) // per travel mode
    }

    @Test func unavailableRoutesFallBackToEstimates() async {
        let fake = FakeRoutes()
        await fake.fail(c)
        let m = RouteMatrix(provider: fake, cacheURL: nil)
        m.prefetch([a, c], mode: .transit)
        await waitIdle(m)
        #expect(m.cost(a, c, mode: .transit).estimated)
    }

    @Test func largeLevelsOnlyFetchConsecutiveLegs() async {
        let fake = FakeRoutes()
        let m = RouteMatrix(provider: fake, cacheURL: nil)
        let pts = (0..<12).map { GeoPoint(lat: 35 + Double($0) / 100, lng: 139) }
        m.prefetch(pts, mode: .walk)
        await waitIdle(m)
        #expect(await fake.calls == 11)
    }

    @Test func diskCacheKeepsOnlyRealRoutes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID()).json")
        let fake = FakeRoutes()
        await fake.fail(c)
        let m = RouteMatrix(provider: fake, cacheURL: url)
        m.prefetch([a, b, c], mode: .walk)
        await waitIdle(m)
        try? await Task.sleep(for: .milliseconds(20))
        let reopened = RouteMatrix(provider: FakeRoutes(), cacheURL: url)
        #expect(!reopened.cost(a, b, mode: .walk).estimated)
        #expect(reopened.cost(a, c, mode: .walk).estimated)
    }
}

@MainActor
@Suite struct RouteSummaryTests {
    @Test func straightLineSummaryMatchesTheSharedRules() async throws {
        let (m, _) = try await osaka()
        let matrix = RouteMatrix(provider: StraightLineProvider(), cacheURL: nil)
        let s = RouteSummary.make(tasks: m.items, selected: [], editing: false, objective: .distance,
                                  mode: .walk, matrix: matrix)
        #expect(s.status == .detour)
        #expect(s.statusText == "多绕 18.0 km") // golden: 36.05 − 18.06
        #expect(s.totalText == "约 36.1 km")
        #expect(s.legText[m.items[0].id] == "起点")
        #expect(s.optimizedOrder?.count == 6)
        #expect(s.estimated)
    }

    @Test func dragPreviewAndScope() async throws {
        let (m, _) = try await osaka()
        let matrix = RouteMatrix(provider: StraightLineProvider(), cacheURL: nil)
        let editing = RouteSummary.make(tasks: m.items, selected: [], editing: true, objective: .distance,
                                        mode: .walk, matrix: matrix)
        #expect(editing.statusText == "预览中")
        #expect(editing.optimizedOrder == nil) // 重排 hidden during unsaved drags
        let one = RouteSummary.make(tasks: m.items, selected: [m.items[0].id], editing: false,
                                    objective: .distance, mode: .walk, matrix: matrix)
        #expect(one.statusText == "至少 2 项")
        #expect(one.legText[m.items[1].id] == "")
    }

    @Test func timeObjectiveFormatsMinutes() {
        #expect(RouteSummary.format(59, .time) == "1 分钟")
        #expect(RouteSummary.format(18 * 60, .time) == "18 分钟")
        #expect(RouteSummary.format(3600, .time) == "1 小时")
        #expect(RouteSummary.format(3900, .time) == "1 小时 5 分")
        #expect(RouteSummary.format(2450, .distance) == "2.5 km")
    }

    @Test func unlocatedTasksAreMarked() async throws {
        let (m, _) = try await osaka()
        _ = await m.create(name: "黑门市场", place: "", prerequisites: [])
        let matrix = RouteMatrix(provider: StraightLineProvider(), cacheURL: nil)
        let s = RouteSummary.make(tasks: m.items, selected: [], editing: false, objective: .time,
                                  mode: .transit, matrix: matrix)
        #expect(s.legText[m.items.last!.id] == "未定位")
        #expect(!s.routeIds.contains(m.items.last!.id))
    }
}

@MainActor
@Suite struct OptimizeTests {
    @Test func applyOrderSavesImmediatelyWithoutADraft() async throws {
        let (m, backend) = try await osaka()
        let ids = m.items.map(\.id)
        let order = [ids[0], ids[4], ids[2], ids[5], ids[1], ids[3]]
        await m.applyOrder(order)
        #expect(m.items.map(\.id) == order)
        #expect(!m.isEditing)
        #expect(try await backend.level(m.taskId).children.map(\.id) == order)
    }

    @Test func applyOrderRollsBackOnFailure() async throws {
        let (m, backend) = try await osaka()
        let ids = m.items.map(\.id)
        await backend.failNextCall(with: BackendError.unexpected(status: 500))
        await m.applyOrder(ids.reversed())
        #expect(m.items.map(\.id) == ids)
        #expect(m.notice == "保存失败")
    }

    @Test func applyOrderIgnoresForeignIds() async throws {
        let (m, backend) = try await osaka()
        await m.applyOrder(["nope"])
        #expect(await backend.calls.contains { $0.hasPrefix("reorder") } == false)
    }
}
