import Foundation

/// Mirrors packages/core/src/geo.ts. Verified against packages/fixtures/data/cases.json.
public struct GeoPoint: Hashable, Sendable {
    public var lat: Double
    public var lng: Double
    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }
}

public enum Geo {
    static let earthRadiusKm = 6371.0

    /// Great-circle (straight-line) distance; used for the drag-time 预览 before the server answers.
    public static func haversineKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.lat - a.lat) * rad
        let dLng = (b.lng - a.lng) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLng / 2) * sin(dLng / 2)
        return earthRadiusKm * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// Length of the path through `points` in order.
    public static func routeKm(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + haversineKm($1.0, $1.1) }
    }

    /// "约 18.1 km" / "约 483 km": under 100 one decimal, otherwise integer; a value that rounds to
    /// 100.0 shows as "100". Rounding matches JS toFixed / Math.round (exact binary value, ties up).
    public static func formatKm(_ km: Double) -> String {
        if km < 100 {
            let s = oneDecimal(km)
            if s != "100.0" { return s }
        }
        return String(Int(km.rounded(.toNearestOrAwayFromZero)))
    }

    private static func oneDecimal(_ x: Double) -> String {
        // printf rounds exact ties to even; JS rounds them up. In binary, x * 10 can only be an exact
        // tie (n + 0.5) when x is a multiple of 0.25, so handle that case explicitly.
        let t = x * 10
        if (x * 4).rounded() == x * 4, t - t.rounded(.down) == 0.5 {
            return String(format: "%.1f", (t.rounded(.down) + 1) / 10)
        }
        return String(format: "%.1f", x)
    }
}
