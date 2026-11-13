import Foundation

/// Mirrors packages/core/src/route.ts, generalised over the cost (metres or seconds from MapKit,
/// or straight-line km as a fallback). Verified against the prototype's golden cases.
public enum Route {
    /// Up to this many points the shortest path is solved exactly (Held–Karp); beyond, a heuristic.
    public static let exactLimit = 12

    /// Shortest open path over nodes 0..<n starting at node 0 (the fixed 起点). `cost` may be asymmetric.
    public static func shortestPathOrder(_ n: Int, cost: (Int, Int) -> Double) -> [Int] {
        if n <= 2 { return Array(0..<n) }
        return n <= exactLimit ? heldKarp(n, cost) : nearestNeighbourTwoOpt(n, cost)
    }

    public static func pathCost(_ order: [Int], cost: (Int, Int) -> Double) -> Double {
        zip(order, order.dropFirst()).reduce(0) { $0 + cost($1.0, $1.1) }
    }

    private static func heldKarp(_ n: Int, _ cost: (Int, Int) -> Double) -> [Int] {
        let full = 1 << n
        var dp = [Double](repeating: .infinity, count: full * n)
        var parent = [Int8](repeating: -1, count: full * n)
        dp[1 * n + 0] = 0
        var mask = 1
        while mask < full {
            for j in 0..<n {
                let cur = dp[mask * n + j]
                if cur == .infinity { continue }
                for k in 1..<n where mask & (1 << k) == 0 {
                    let nm = mask | (1 << k)
                    let v = cur + cost(j, k)
                    if v < dp[nm * n + k] {
                        dp[nm * n + k] = v
                        parent[nm * n + k] = Int8(j)
                    }
                }
            }
            mask += 2
        }
        let last = full - 1
        var end = 1
        for j in 2..<n where dp[last * n + j] < dp[last * n + end] { end = j }
        var order: [Int] = []
        var m = last
        var j = end
        while j != -1 {
            order.append(j)
            let p = Int(parent[m * n + j])
            m &= ~(1 << j)
            j = p
        }
        return order.reversed()
    }

    private static func nearestNeighbourTwoOpt(_ n: Int, _ cost: (Int, Int) -> Double) -> [Int] {
        var order = [0]
        var left = Set(1..<n)
        while !left.isEmpty {
            let from = order.last!
            let next = left.min { cost(from, $0) < cost(from, $1) }!
            order.append(next)
            left.remove(next)
        }
        var best = pathCost(order, cost: cost)
        var improved = true
        while improved {
            improved = false
            for i in 1..<(n - 1) {
                for k in (i + 1)..<n {
                    var cand = order
                    cand[i...k].reverse()
                    let c = pathCost(cand, cost: cost)
                    if c < best - 1e-9 {
                        order = cand
                        best = c
                        improved = true
                    }
                }
            }
        }
        return order
    }

    /// Reorders a subset in place: the subset's slots keep their positions and are refilled with
    /// `subsetOrder`; everything else stays put (重排 only moves scoped, located tasks).
    public static func fillSlots(_ full: [String], _ subsetOrder: [String]) -> [String] {
        let inSubset = Set(subsetOrder)
        var next = full
        var j = 0
        for i in next.indices where inSubset.contains(next[i]) {
            next[i] = subsetOrder[j]
            j += 1
        }
        precondition(j == subsetOrder.count, "fillSlots: subset contains ids not in full list")
        return next
    }

    /// Below this, the current order counts as optimal (prototype: 0.05 km).
    public static let detourThresholdKm = 0.05
}

/// One stop on a level, in list order.
public struct RouteStop: Hashable, Sendable {
    public var id: String
    public var point: GeoPoint?
    public init(id: String, point: GeoPoint?) {
        self.id = id
        self.point = point
    }
}

public struct LevelRoute: Equatable, Sendable {
    public enum Leg: Equatable, Sendable {
        case start
        case leg(Double)
        case unlocated
        case outOfScope
    }

    public enum Status: Equatable, Sendable { case needMore, optimal, detour }

    /// In-scope ids, list order. An empty selection means the whole level.
    public var scopeIds: [String]
    /// One entry per stop (list order): cost from the previous located, in-scope stop.
    public var legs: [String: Leg]
    /// nil while fewer than two in-scope stops have coordinates.
    public var total: Double?
    public var best: Double?
    public var extra: Double
    public var status: Status
    /// Full order after 重排 (first located stop stays); nil unless detour.
    public var optimizedOrder: [String]?
}

extension Route {
    /// Route summary for one level (勾选只决定范围，不决定顺序). `cost(a, b)` is in any unit;
    /// `threshold` is the "多绕" cut-off in that unit.
    public static func plan(
        stops: [RouteStop], selected: Set<String>, threshold: Double = detourThresholdKm,
        cost: (GeoPoint, GeoPoint, _ fromId: String, _ toId: String) -> Double
    ) -> LevelRoute {
        let scoped = selected.isEmpty ? stops : stops.filter { selected.contains($0.id) }
        let inScope = Set(scoped.map(\.id))
        let geo = scoped.filter { $0.point != nil }

        var legs: [String: LevelRoute.Leg] = [:]
        var prev: RouteStop?
        for s in stops {
            if !inScope.contains(s.id) { legs[s.id] = .outOfScope }
            else if let p = s.point {
                legs[s.id] = prev.map { .leg(cost($0.point!, p, $0.id, s.id)) } ?? .start
                prev = s
            } else { legs[s.id] = .unlocated }
        }

        let scopeIds = scoped.map(\.id)
        guard geo.count >= 2 else {
            return LevelRoute(scopeIds: scopeIds, legs: legs, total: nil, best: nil, extra: 0,
                              status: .needMore, optimizedOrder: nil)
        }
        let c: (Int, Int) -> Double = { cost(geo[$0].point!, geo[$1].point!, geo[$0].id, geo[$1].id) }
        let total = pathCost(Array(geo.indices), cost: c)
        let bestIdx = shortestPathOrder(geo.count, cost: c)
        let best = pathCost(bestIdx, cost: c)
        let extra = max(0, total - best)
        let detour = geo.count >= 3 && extra > threshold
        return LevelRoute(
            scopeIds: scopeIds, legs: legs, total: total, best: best, extra: extra,
            status: detour ? .detour : .optimal,
            optimizedOrder: detour ? fillSlots(stops.map(\.id), bestIdx.map { geo[$0].id }) : nil
        )
    }
}
