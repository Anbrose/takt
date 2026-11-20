import Foundation
import Testing
@testable import TaktCore

private struct RouteCases: Decodable {
    struct P: Decodable { let id: String; let lat: Double; let lng: Double }
    struct C: Decodable { let name: String; let points: [P]; let totalKm: Double; let bestOrder: [String]; let bestKm: Double }
    let route: [C]
    static let shared: RouteCases = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../packages/fixtures/data/cases.json").standardized
        return try! JSONDecoder().decode(RouteCases.self, from: Data(contentsOf: url))
    }()
}

private func km(_ a: GeoPoint, _ b: GeoPoint, _: String, _: String) -> Double { Geo.haversineKm(a, b) }

@Test func bestOrderMatchesPrototype() {
    for c in RouteCases.shared.route {
        let pts = c.points.map { GeoPoint(lat: $0.lat, lng: $0.lng) }
        let order = Route.shortestPathOrder(pts.count) { Geo.haversineKm(pts[$0], pts[$1]) }
        #expect(order.map { c.points[$0].id } == c.bestOrder, "\(c.name)")
        #expect(abs(Route.pathCost(order) { Geo.haversineKm(pts[$0], pts[$1]) } - c.bestKm) < 1e-9)
    }
}

/// Same Osaka cases as packages/core/test/rules.test.ts.
private let osaka: [RouteStop] = [
    ("castle", 34.6873, 135.5262), ("usj", 34.6654, 135.4323), ("dotonbori", 34.6687, 135.5013),
    ("kaiyukan", 34.6545, 135.4290), ("umeda", 34.7053, 135.4903), ("tsutenkaku", 34.6525, 135.5063),
].map { RouteStop(id: $0.0, point: GeoPoint(lat: $0.1, lng: $0.2)) }

@Test func planWholeLevel() {
    let r = Route.plan(stops: osaka, selected: [], cost: km)
    #expect(r.status == .detour)
    #expect(r.optimizedOrder == ["castle", "umeda", "dotonbori", "tsutenkaku", "usj", "kaiyukan"])
    #expect(r.legs["castle"] == .start)
}

@Test func planScopeKeepsOtherSlots() {
    let r = Route.plan(stops: osaka, selected: ["tsutenkaku", "usj", "castle", "kaiyukan"], cost: km)
    #expect(r.scopeIds == ["castle", "usj", "kaiyukan", "tsutenkaku"])
    #expect(r.legs["dotonbori"] == .outOfScope)
    #expect(r.optimizedOrder == ["castle", "tsutenkaku", "dotonbori", "usj", "umeda", "kaiyukan"])
}

@Test func planUnlocatedStaysInPlace() {
    var stops = osaka
    stops.insert(RouteStop(id: "new", point: nil), at: 2)
    let r = Route.plan(stops: stops, selected: [], cost: km)
    #expect(r.legs["new"] == .unlocated)
    #expect(r.optimizedOrder?[2] == "new")
}

@Test func planNeedsTwoAndTwoIsNeverADetour() {
    #expect(Route.plan(stops: osaka, selected: ["castle"], cost: km).status == .needMore)
    let two = Route.plan(stops: osaka, selected: ["castle", "usj"], cost: km)
    #expect(two.status == .optimal && two.optimizedOrder == nil)
}

@Test func heuristicAboveExactLimitIsValid() {
    var s: UInt64 = 7
    func r() -> Double { s = s &* 6364136223846793005 &+ 1; return Double(s >> 33) / Double(1 << 31) * 100 }
    let pts = (0..<25).map { _ in (r(), r()) }
    let c: (Int, Int) -> Double = { hypot(pts[$0].0 - pts[$1].0, pts[$0].1 - pts[$1].1) }
    let o = Route.shortestPathOrder(25, cost: c)
    #expect(o.first == 0 && Set(o).count == 25)
    #expect(Route.pathCost(o, cost: c) < Route.pathCost(Array(0..<25), cost: c))
}
