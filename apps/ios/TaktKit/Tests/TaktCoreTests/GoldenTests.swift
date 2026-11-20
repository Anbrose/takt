import Foundation
import Testing
@testable import TaktCore

/// Shared golden cases (computed from the design prototype), same file the TS tests use.
private struct Cases: Decodable {
    struct P: Decodable { let id: String; let lat: Double; let lng: Double }
    struct GeoCase: Decodable { let a: P; let b: P; let km: Double }
    struct FormatCase: Decodable { let km: Double; let text: String }
    struct RouteCase: Decodable { let name: String; let points: [P]; let totalKm: Double }
    let geo: [GeoCase]
    let format: [FormatCase]
    let route: [RouteCase]

    static let shared: Cases = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../../packages/fixtures/data/cases.json")
            .standardized
        return try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }()
}

private func pt(_ p: Cases.P) -> GeoPoint { GeoPoint(lat: p.lat, lng: p.lng) }

@Test func haversineMatchesPrototype() {
    #expect(!Cases.shared.geo.isEmpty)
    for c in Cases.shared.geo {
        #expect(abs(Geo.haversineKm(pt(c.a), pt(c.b)) - c.km) < 1e-9, "\(c.a.id)→\(c.b.id)")
    }
}

@Test func routeKmMatchesPrototype() {
    for c in Cases.shared.route {
        #expect(abs(Geo.routeKm(c.points.map(pt)) - c.totalKm) < 1e-9, "\(c.name)")
    }
}

@Test func formatMatchesTypeScript() {
    for c in Cases.shared.format {
        #expect(Geo.formatKm(c.km) == c.text, "\(c.km)")
    }
    // Extra exact-tie cases where printf (ties-to-even) and JS (ties-up) would differ.
    #expect(Geo.formatKm(0.25) == "0.3")
    #expect(Geo.formatKm(1.25) == "1.3")
    #expect(Geo.formatKm(2.75) == "2.8")
    #expect(Geo.formatKm(100.5) == "101")
}

@Test func orderHelpers() {
    #expect(Order.move(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
    #expect(Order.move(["a", "b", "c", "d"], from: 3, to: 1) == ["a", "d", "b", "c"])
    #expect(Order.railAbbr("teamLab") == "team")
    #expect(Order.railAbbr("梅田空中庭园") == "梅田")
    #expect(Order.railAbbr("") == "")
}

@Test func dropIndexCrossesNeighbourCentres() {
    let hs = [100.0, 60, 100, 60]
    #expect(Order.dropIndex(heights: hs, gap: 10, from: 0, offset: 0) == 0)
    // Row 0 centre at 50; row 1 centre at 140. Needs > 90 to pass.
    #expect(Order.dropIndex(heights: hs, gap: 10, from: 0, offset: 89) == 0)
    #expect(Order.dropIndex(heights: hs, gap: 10, from: 0, offset: 91) == 1)
    #expect(Order.dropIndex(heights: hs, gap: 10, from: 0, offset: 1000) == 3)
    #expect(Order.dropIndex(heights: hs, gap: 10, from: 3, offset: -1000) == 0)
}
