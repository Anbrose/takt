import MapKit
import SwiftUI
import TaktAPI
import TaktCore

/// 地图 (geographic order): Apple Maps base map, numbered pins and one straight dashed leg per pair
/// of consecutive in-scope stops — a sketch of the order, not the real way there (that is Google
/// Maps' job, one tap away). Arrows and a dark → light ramp show direction and sequence; tapping a
/// pin highlights only its incoming and outgoing legs. Below: the total distance and 重排.
struct MapPanel: View {
    /// Tasks in the order being shown (saved, draft, or live drag preview).
    let tasks: [TaskSummary]
    let scope: Set<String>
    let summary: RouteSummary
    let onOptimize: ([String]) -> Void

    @State private var camera: MapCameraPosition = .automatic
    /// Pin whose legs are highlighted; nil = the whole route.
    @State private var focus: String?
    @Environment(\.accessibilityReduceMotion) private var reduce

    private struct Pin: Identifiable {
        let id: String
        let number: Int
        let name: String
        let coordinate: CLLocationCoordinate2D
        let inScope: Bool
    }

    private struct Leg: Identifiable {
        let id: String
        let index: Int
        let from: Pin
        let to: Pin
    }

    private var pins: [Pin] {
        tasks.enumerated().compactMap { i, t in
            guard let lat = t.lat, let lng = t.lng else { return nil }
            let on = scope.isEmpty || scope.contains(t.id)
            return Pin(id: t.id, number: i + 1, name: t.short,
                       coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), inScope: on)
        }
    }

    /// In-scope located stops in route order.
    private var stops: [Pin] {
        let byId = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
        return summary.routeIds.compactMap { byId[$0] }
    }

    private var legs: [Leg] {
        let s = stops
        return zip(s, s.dropFirst()).enumerated().map { i, pair in
            Leg(id: "\(pair.0.id)>\(pair.1.id)", index: i, from: pair.0, to: pair.1)
        }
    }

    /// The focused pin, if it is still one of the stops.
    private var focused: String? {
        guard let focus, stops.contains(where: { $0.id == focus }) else { return nil }
        return focus
    }

    private func isHot(_ leg: Leg) -> Bool {
        guard let f = focused else { return false }
        return leg.from.id == f || leg.to.id == f
    }

    /// Pins next to the focused one (and itself); everything else fades while focused.
    private func isNear(_ pin: Pin) -> Bool {
        guard let f = focused else { return true }
        let ids = stops.map(\.id)
        guard let a = ids.firstIndex(of: f), let b = ids.firstIndex(of: pin.id) else { return false }
        return abs(a - b) <= 1
    }

    var body: some View {
        VStack(spacing: 12) {
            map
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(summary.totalText)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                optimizeButton
            }
            .frame(minHeight: Metrics.hit)
            googleMapsButton
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(legs) { leg in
                let hot = isHot(leg)
                MapPolyline(coordinates: [leg.from.coordinate, leg.to.coordinate])
                    .stroke(
                        legColor(leg),
                        style: StrokeStyle(lineWidth: hot ? 5 : 3, lineCap: .round, dash: hot ? [] : [7, 7])
                    )
            }
            ForEach(legs) { leg in
                let (at, angle) = arrow(leg)
                Annotation("", coordinate: at, anchor: .center) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: isHot(leg) ? 15 : 12, weight: .heavy))
                        .foregroundStyle(legColor(leg))
                        .rotationEffect(.radians(angle))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .annotationTitles(.hidden)
            }
            ForEach(pins) { pin in
                let near = isNear(pin)
                Annotation(pin.name, coordinate: pin.coordinate, anchor: .center) {
                    PinMark(number: pin.number, on: pin.inScope, focused: focused == pin.id)
                        .opacity(near ? 1 : 0.35)
                        .onTapGesture { tap(pin) }
                        .accessibilityAddTraits(pin.inScope ? .isButton : [])
                        .accessibilityLabel(pin.inScope ? "\(pin.number) \(pin.name)" : pin.name)
                }
                .annotationTitles(pin.inScope && near ? .visible : .hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .aspectRatio(600 / 440, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line))
        // Tapping the map itself brings the whole route back.
        .onTapGesture { if focus != nil { Motion.with(Motion.fade, reduce: reduce) { focus = nil } } }
        // Re-fit when the set of places changes (level, scope, new task) — not on reorder.
        .onChange(of: Set(pins.map(\.id))) { _, _ in
            focus = nil
            Motion.with(Motion.nav, reduce: reduce) { camera = .automatic }
        }
        .accessibilityLabel("地图，\(pins.count) 个地点")
    }

    private func tap(_ pin: Pin) {
        guard pin.inScope else { return }
        Motion.with(Motion.fade, reduce: reduce) { focus = focus == pin.id ? nil : pin.id }
    }

    /// Accent, getting lighter along the route; while a pin is focused, only its legs keep colour.
    private func legColor(_ leg: Leg) -> Color {
        if focused != nil { return isHot(leg) ? Palette.accent : Palette.muted.opacity(0.3) }
        let n = legs.count
        let ramp = n > 1 ? 1 - 0.55 * Double(leg.index) / Double(n - 1) : 1
        return Palette.accent.opacity(ramp)
    }

    /// Where the arrow sits (a bit past the middle) and which way it points on screen.
    private func arrow(_ leg: Leg) -> (CLLocationCoordinate2D, Double) {
        let a = MKMapPoint(leg.from.coordinate), b = MKMapPoint(leg.to.coordinate)
        let at = MKMapPoint(x: a.x + (b.x - a.x) * 0.55, y: a.y + (b.y - a.y) * 0.55)
        // Map points grow east (x) and south (y), like screen coordinates (the map never rotates).
        return (at.coordinate, atan2(b.y - a.y, b.x - a.x))
    }

    // MARK: Controls

    private var optimizeButton: some View {
        let order = summary.optimizedOrder
        return Button {
            if let order { onOptimize(order) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 14, weight: .bold))
                Text("重排").font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Palette.onFill)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.hit)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(order == nil ? 0 : 1)
        .disabled(order == nil)
        .accessibilityHidden(order == nil)
    }

    /// The whole in-scope route in Google Maps (driving: transit can't take waypoints).
    @ViewBuilder private var googleMapsButton: some View {
        let inScope = tasks.filter { scope.isEmpty || scope.contains($0.id) }
        let url = MapsLink.route(inScope)
        Link(destination: url ?? URL(string: "https://www.google.com/maps")!) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 15, weight: .semibold))
                Text("Google 地图").font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(Palette.accentText)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line))
        }
        .disabled(url == nil)
        .opacity(url == nil ? 0.5 : 1)
    }
}

/// Numbered pin (in scope) or a small hollow dot (out of scope); a soft ring while focused.
private struct PinMark: View {
    let number: Int
    let on: Bool
    var focused = false

    var body: some View {
        ZStack {
            Circle().fill(on ? Palette.fill : Palette.surface)
            Circle().strokeBorder(on ? Palette.surface : Palette.muted, lineWidth: 2)
            if on {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.onFill)
            }
        }
        .frame(width: on ? 28 : 12, height: on ? 28 : 12)
        .padding(focused ? 4 : 0)
        .background(Circle().fill(Palette.accent.opacity(focused ? 0.35 : 0)))
        .frame(minWidth: on ? Metrics.hit : 12, minHeight: on ? Metrics.hit : 12)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.22), value: on)
        .animation(.easeInOut(duration: 0.22), value: focused)
    }
}
