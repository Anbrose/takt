import Foundation
import TaktAPI
import TaktCore

/// What the map panel and the compressed rows show for one level, given the current (possibly
/// dragged) order, the 勾选 scope, the 优化目标 and the 出行方式.
public struct RouteSummary: Equatable {
    public enum Status: Equatable { case needMore, optimal, detour, preview }

    public var status: Status
    /// "多绕 3.2 km" / "多 12 分钟" / "不绕路" / "预览中" / "至少 2 项"
    public var statusText: String
    /// "约 18 km" / "约 1 小时 5 分" / "—"
    public var totalText: String
    /// Per task id: "起点", "+2.4 km", "+18 分钟", "未定位", or "" when out of scope.
    public var legText: [String: String]
    /// Located, in-scope ids in route order (for the map line).
    public var routeIds: [String]
    /// Full order after 重排; nil unless there is a detour.
    public var optimizedOrder: [String]?
    /// Some numbers are straight-line estimates (route not fetched yet / unavailable).
    public var estimated: Bool

    /// 多绕 cut-offs: 50 m (prototype 0.05 km) or one minute.
    static func threshold(_ o: Objective) -> Double { o == .distance ? 50 : 60 }

    @MainActor
    public static func make(
        tasks: [TaskSummary], selected: Set<String>, editing: Bool,
        objective: Objective, mode: TravelMode, matrix: RouteMatrix
    ) -> RouteSummary {
        let stops = tasks.map { t in
            RouteStop(id: t.id, point: t.lat.flatMap { lat in t.lng.map { GeoPoint(lat: lat, lng: $0) } })
        }
        var estimated = false
        let plan = Route.plan(stops: stops, selected: selected, threshold: threshold(objective)) { a, b, _, _ in
            let c = matrix.cost(a, b, mode: mode)
            if c.estimated { estimated = true }
            return c.value(objective)
        }

        var legText: [String: String] = [:]
        for (id, leg) in plan.legs {
            legText[id] = switch leg {
            case .start: "起点"
            case .leg(let v): "+" + format(v, objective)
            case .unlocated: "未定位"
            case .outOfScope: ""
            }
        }
        let status: Status
        if editing { status = .preview } else {
            switch plan.status {
            case .needMore: status = .needMore
            case .optimal: status = .optimal
            case .detour: status = .detour
            }
        }
        let statusText = switch status {
        case .preview: "预览中"
        case .needMore: "至少 2 项"
        case .optimal: "不绕路"
        case .detour: objective == .distance ? "多绕 " + format(plan.extra, .distance) : "多 " + format(plan.extra, .time)
        }
        return RouteSummary(
            status: status,
            statusText: statusText,
            totalText: plan.total.map { "约 " + format($0, objective) } ?? "—",
            legText: legText,
            routeIds: plan.scopeIds.filter { id in stops.first { $0.id == id }?.point != nil },
            optimizedOrder: editing ? nil : plan.optimizedOrder,
            estimated: estimated
        )
    }

    /// Metres → "2.4 km" (shared km rule) ; seconds → "18 分钟" / "1 小时 5 分".
    public static func format(_ value: Double, _ objective: Objective) -> String {
        switch objective {
        case .distance:
            return Geo.formatKm(value / 1000) + " km"
        case .time:
            let minutes = max(1, Int((value / 60).rounded()))
            if minutes < 60 { return "\(minutes) 分钟" }
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
        }
    }
}
