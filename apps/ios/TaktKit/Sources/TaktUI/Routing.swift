import Foundation
import MapKit
import Observation
import os
import TaktCore

private let log = Logger(subsystem: "dev.takt.app", category: "routing")

/// 出行方式 (步行 | 公交 | 自驾).
public enum TravelMode: String, CaseIterable, Codable, Sendable {
    case walk, transit, drive

    public var label: String {
        switch self {
        case .walk: "步行"
        case .transit: "公交"
        case .drive: "自驾"
        }
    }

    /// Average speed used when a real route isn't available (km/h).
    var fallbackSpeed: Double {
        switch self {
        case .walk: 4.5
        case .transit: 30
        case .drive: 40
        }
    }
}

/// 优化目标 (距离 | 耗时).
public enum Objective: String, CaseIterable, Codable, Sendable {
    case distance, time

    public var label: String { self == .distance ? "距离" : "耗时" }
}

/// Real travel cost between two points.
public struct LegCost: Codable, Equatable, Sendable {
    public var meters: Double
    public var seconds: Double
    /// True when this is a straight-line estimate (no route found, or no routing in use).
    public var estimated: Bool

    public init(meters: Double, seconds: Double, estimated: Bool) {
        self.meters = meters
        self.seconds = seconds
        self.estimated = estimated
    }

    public static func straightLine(_ a: GeoPoint, _ b: GeoPoint, mode: TravelMode) -> LegCost {
        let km = Geo.haversineKm(a, b)
        return LegCost(meters: km * 1000, seconds: km / mode.fallbackSpeed * 3600, estimated: true)
    }

    public func value(_ objective: Objective) -> Double { objective == .distance ? meters : seconds }
}

public protocol RouteProvider: Sendable {
    func cost(from: GeoPoint, to: GeoPoint, mode: TravelMode) async throws -> LegCost
}

/// Offline / deterministic provider (demo mode, tests): straight line at an average speed.
public struct StraightLineProvider: RouteProvider {
    public init() {}
    public func cost(from: GeoPoint, to: GeoPoint, mode: TravelMode) async throws -> LegCost {
        .straightLine(from, to, mode: mode)
    }
}

/// Apple Maps ETA (MKDirections.calculateETA): real road / walking / transit time and distance.
public struct MapKitRouteProvider: RouteProvider {
    public init() {}

    public func cost(from: GeoPoint, to: GeoPoint, mode: TravelMode) async throws -> LegCost {
        let request = MKDirections.Request()
        request.source = Self.item(from)
        request.destination = Self.item(to)
        request.transportType = switch mode {
        case .walk: .walking
        case .transit: .transit
        case .drive: .automobile
        }
        var delay: Duration = .seconds(2)
        for attempt in 0..<4 {
            do {
                let eta = try await MKDirections(request: request).calculateETA()
                return LegCost(meters: eta.distance, seconds: eta.expectedTravelTime, estimated: false)
            } catch let e as MKError where e.code == .loadingThrottled && attempt < 3 {
                // MapKit allows ~50 requests a minute per app; back off and retry.
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
        throw MKError(.loadingThrottled)
    }

    private static func item(_ p: GeoPoint) -> MKMapItem {
        let coord = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
        if #available(iOS 26, macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: p.lat, longitude: p.lng), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coord))
    }
}

/// Pairwise travel costs for the current level, fetched in the background and cached on disk.
/// Costs are treated as symmetric (A→B ≈ B→A) to halve the number of MapKit requests.
/// Until a pair arrives, `cost` returns a straight-line estimate, so the UI always has numbers.
@MainActor
@Observable
public final class RouteMatrix {
    struct Key: Hashable, Codable {
        var mode: TravelMode
        var a: String
        var b: String

        init(_ p: GeoPoint, _ q: GeoPoint, _ mode: TravelMode) {
            let x = Self.tag(p), y = Self.tag(q)
            self.mode = mode
            (a, b) = x < y ? (x, y) : (y, x)
        }

        private static func tag(_ p: GeoPoint) -> String { String(format: "%.5f,%.5f", p.lat, p.lng) }
    }

    private let provider: any RouteProvider
    private let cacheURL: URL?
    private var costs: [Key: LegCost] = [:]
    private var queued: [(Key, GeoPoint, GeoPoint)] = []
    private var inFlight: Set<Key> = []
    private var worker: Task<Void, Never>?
    /// Pairs still being fetched (for a small loading hint).
    public private(set) var pending = 0

    /// Full matrices are only requested up to this many points (n·(n−1)/2 requests); above it
    /// only consecutive legs are fetched and 重排 relies on estimates for the rest.
    public static let fullMatrixLimit = 10

    public init(provider: any RouteProvider, cacheURL: URL? = RouteMatrix.defaultCacheURL) {
        self.provider = provider
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([Key: LegCost].self, from: data) {
            costs = saved
        }
    }

    public nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("route-costs.json")
    }

    /// Known cost, or a straight-line estimate while the real one is unknown.
    public func cost(_ p: GeoPoint, _ q: GeoPoint, mode: TravelMode) -> LegCost {
        costs[Key(p, q, mode)] ?? .straightLine(p, q, mode: mode)
    }

    /// Requests what the level needs: every pair (for 重排) when small enough, else consecutive legs.
    public func prefetch(_ points: [GeoPoint], mode: TravelMode) {
        var pairs: [(GeoPoint, GeoPoint)] = []
        if points.count <= Self.fullMatrixLimit {
            for i in points.indices { for j in points.indices where j > i { pairs.append((points[i], points[j])) } }
        } else {
            pairs = Array(zip(points, points.dropFirst()))
        }
        for (p, q) in pairs {
            let key = Key(p, q, mode)
            if costs[key] != nil || inFlight.contains(key) || p == q { continue }
            inFlight.insert(key)
            queued.append((key, p, q))
        }
        pending = inFlight.count
        if worker == nil, !queued.isEmpty { worker = Task { await drain() } }
    }

    private func drain() async {
        while !queued.isEmpty {
            let (key, p, q) = queued.removeFirst()
            let result: LegCost
            do {
                result = try await provider.cost(from: p, to: q, mode: key.mode)
            } catch {
                // No route (e.g. 大阪→北海道 by transit) — keep an estimate so the plan still works.
                log.info("route unavailable \(key.a, privacy: .public)→\(key.b, privacy: .public): \(String(describing: error), privacy: .public)")
                result = .straightLine(p, q, mode: key.mode)
            }
            costs[key] = result
            inFlight.remove(key)
            pending = inFlight.count
        }
        worker = nil
        save()
    }

    private func save() {
        // Only real routes are persisted; estimates (no route / errors) are retried next launch.
        guard let cacheURL, let data = try? JSONEncoder().encode(costs.filter { !$0.value.estimated }) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
