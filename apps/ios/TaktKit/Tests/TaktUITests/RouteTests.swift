import Foundation
import Testing
import TaktAPI
import TaktCore
@testable import TaktUI

@MainActor
private func osaka() async throws -> (LevelModel, InMemoryBackend) {
    let backend = await InMemoryBackend.sample()
    let root = try await backend.level(try await backend.projects()[0].rootTaskId)
    let m = LevelModel(taskId: root.children[0].id, backend: backend)
    await m.load()
    return (m, backend)
}

@MainActor
@Suite struct RouteSummaryTests {
    @Test func straightLineSummaryMatchesTheSharedRules() async throws {
        let (m, _) = try await osaka()
        let s = RouteSummary.make(tasks: m.items, selected: [], editing: false)
        #expect(s.status == .detour)
        #expect(s.totalText == "36.1 km") // golden: 36.05
        #expect(s.legText[m.items[0].id] == "起点")
        #expect(s.legText[m.items[1].id]?.hasPrefix("+") == true)
        #expect(s.optimizedOrder?.count == 6)
    }

    @Test func dragPreviewAndScope() async throws {
        let (m, _) = try await osaka()
        let editing = RouteSummary.make(tasks: m.items, selected: [], editing: true)
        #expect(editing.status == .preview)
        #expect(editing.optimizedOrder == nil) // 重排 hidden during unsaved drags
        let one = RouteSummary.make(tasks: m.items, selected: [m.items[0].id], editing: false)
        #expect(one.status == .needMore)
        #expect(one.totalText == "—")
        #expect(one.legText[m.items[1].id] == "")
    }

    @Test func unlocatedTasksAreMarked() async throws {
        let (m, _) = try await osaka()
        _ = await m.create(name: "黑门市场", place: "", prerequisites: [])
        let s = RouteSummary.make(tasks: m.items, selected: [], editing: false)
        #expect(s.legText[m.items.last!.id] == "未定位")
        #expect(!s.routeIds.contains(m.items.last!.id))
    }
}

@MainActor
@Suite struct MapsLinkTests {
    @Test func wholeRouteGoesByNameAndAddressInDrivingMode() async throws {
        let (m, _) = try await osaka()
        let url = try #require(MapsLink.route(m.items)).absoluteString
        #expect(url.hasPrefix("https://www.google.com/maps/dir/?api=1&origin="))
        #expect(url.hasSuffix("&travelmode=driving"))
        // 6 stops: origin, destination and 4 waypoints separated by an encoded "|".
        #expect(url.components(separatedBy: "%7C").count == 4)
        let origin = try #require(MapsLink.query(m.items[0]))
        #expect(origin == "中央区 · 大阪城公园 大阪府大阪市中央区大阪城1-1")
        #expect(!url.contains("34.6873")) // no bare coordinates when an address is known
        let decoded = try #require(url.removingPercentEncoding)
        #expect(decoded.contains("origin=中央区 · 大阪城公园 大阪府大阪市中央区大阪城1-1&destination="))
    }

    @Test func unlocatedTasksAreSkippedAndOneStopIsNotARoute() async throws {
        let (m, _) = try await osaka()
        _ = await m.create(name: "随便逛逛", place: "心斋桥", prerequisites: [])
        #expect(MapsLink.query(m.items.last!) == nil)
        #expect(MapsLink.route(m.items)?.absoluteString.contains("%E5%BF%83%E6%96%8B%E6%A1%A5") == false)
        #expect(MapsLink.route([m.items[0]]) == nil)
    }

    @Test func placesWithoutAnAddressFallBackToCoordinates() {
        let t = TaskSummary(id: "x", name: "x", short: "x", place: "某处", address: "", lat: 34.5, lng: 135.25,
                            completed: false, prerequisites: [], childCount: 0)
        #expect(MapsLink.query(t) == "34.5,135.25")
    }

    @Test func pickedPlacesKeepTheirNameAndAddress() async throws {
        let (m, _) = try await osaka()
        let pick = PlaceChoice(name: "黑门市场", address: "日本大阪府大阪市中央区日本橋2丁目4-1", lat: 34.6654, lng: 135.5063)
        #expect(await m.create(name: "吃螃蟹", place: "黑门", location: pick, prerequisites: []))
        let t = m.items.last!
        #expect(t.place == "黑门市场" && t.address == pick.address && t.lat == 34.6654)
        #expect(MapsLink.query(t) == "黑门市场 日本大阪府大阪市中央区日本橋2丁目4-1")
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
