import Foundation
import TaktAPI
import TaktCore

/// What the map panel and the compressed rows show for one level, given the current (possibly
/// dragged) order and the 勾选 scope. Distances are straight-line: the real route (and the means
/// of transport) is left to Google Maps, so the app doesn't pick a 出行方式 any more.
public struct RouteSummary: Equatable {
    public enum Status: Equatable { case needMore, optimal, detour, preview }

    public var status: Status
    /// "36.1 km" / "—" (fewer than two located, in-scope tasks).
    public var totalText: String
    /// Per task id: "起点", "+2.4 km", "未定位", or "" when out of scope.
    public var legText: [String: String]
    /// Located, in-scope ids in route order (for the map line).
    public var routeIds: [String]
    /// Full order after 重排; nil unless there is a detour (and never while dragging).
    public var optimizedOrder: [String]?

    public static func make(tasks: [TaskSummary], selected: Set<String>, editing: Bool) -> RouteSummary {
        let stops = tasks.map { t in
            RouteStop(id: t.id, point: t.lat.flatMap { lat in t.lng.map { GeoPoint(lat: lat, lng: $0) } })
        }
        let plan = Route.plan(stops: stops, selected: selected) { a, b, _, _ in Geo.haversineKm(a, b) }

        var legText: [String: String] = [:]
        for (id, leg) in plan.legs {
            legText[id] = switch leg {
            case .start: "起点"
            case .leg(let km): "+" + Geo.formatKm(km) + " km"
            case .unlocated: "未定位"
            case .outOfScope: ""
            }
        }
        let status: Status = if editing { .preview } else {
            switch plan.status {
            case .needMore: .needMore
            case .optimal: .optimal
            case .detour: .detour
            }
        }
        let located = Set(stops.filter { $0.point != nil }.map(\.id))
        return RouteSummary(
            status: status,
            totalText: plan.total.map { Geo.formatKm($0) + " km" } ?? "—",
            legText: legText,
            routeIds: plan.scopeIds.filter(located.contains),
            optimizedOrder: editing ? nil : plan.optimizedOrder
        )
    }
}
