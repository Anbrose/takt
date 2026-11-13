import MapKit
import SwiftUI
import TaktAPI
import TaktCore

/// 地图 (geographic order): Apple Maps base map, numbered pins, a dotted line through the in-scope
/// located tasks in list order, then status · 重排 · 优化目标 · 出行方式.
struct MapPanel: View {
    /// Tasks in the order being shown (saved, draft, or live drag preview).
    let tasks: [TaskSummary]
    let scope: Set<String>
    let summary: RouteSummary
    let scopeLabel: String
    let loading: Bool
    @Binding var objective: Objective
    @Binding var travel: TravelMode
    let onOptimize: ([String]) -> Void

    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.accessibilityReduceMotion) private var reduce

    private struct Pin: Identifiable {
        let id: String
        let number: Int
        let name: String
        let coordinate: CLLocationCoordinate2D
        let inScope: Bool
    }

    private var pins: [Pin] {
        tasks.enumerated().compactMap { i, t in
            guard let lat = t.lat, let lng = t.lng else { return nil }
            let on = scope.isEmpty || scope.contains(t.id)
            return Pin(id: t.id, number: i + 1, name: t.short,
                       coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), inScope: on)
        }
    }

    private var line: [CLLocationCoordinate2D] {
        let byId = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0.coordinate) })
        return summary.routeIds.compactMap { byId[$0] }
    }

    var body: some View {
        VStack(spacing: 12) {
            map
            statusRow
            // 优化目标 : 出行方式 = 2 : 3 (prototype flex 2 / 3).
            RatioRow(ratios: [2, 3], spacing: 8) {
                SlidingSegments(options: Objective.allCases.map { ($0, $0.label) }, selection: $objective)
                SlidingSegments(options: TravelMode.allCases.map { ($0, $0.label) }, selection: $travel)
            }
        }
    }

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if line.count >= 2 {
                MapPolyline(coordinates: line)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [0.5, 9]))
            }
            ForEach(pins) { pin in
                Annotation(pin.name, coordinate: pin.coordinate, anchor: .center) {
                    PinMark(number: pin.number, on: pin.inScope)
                }
                .annotationTitles(.visible)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .aspectRatio(600 / 440, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line))
        // Re-fit when the set of places changes (level, scope, new task) — not on reorder.
        .onChange(of: Set(pins.map(\.id))) { _, _ in
            Motion.with(Motion.nav, reduce: reduce) { camera = .automatic }
        }
        .accessibilityLabel("地图，\(pins.count) 个地点")
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.statusText).fontWeight(.bold).foregroundStyle(Palette.text)
                Text("\(scopeLabel) · \(summary.totalText)").foregroundStyle(Palette.muted)
                if loading { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 14))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            Spacer(minLength: 0)
            let order = summary.optimizedOrder
            Button {
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
        .frame(minHeight: Metrics.hit)
    }
}

/// Numbered pin (in scope) or a small hollow dot (out of scope).
private struct PinMark: View {
    let number: Int
    let on: Bool

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
        .animation(.easeInOut(duration: 0.22), value: on)
    }
}

/// Segmented control whose highlight slides between options (分段控件的高亮块滑动).
struct SlidingSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var width: CGFloat = 0

    var body: some View {
        let index = options.firstIndex { $0.0 == selection } ?? 0
        let segment = width / CGFloat(max(options.count, 1))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Palette.fill)
                .frame(width: max(segment, 0))
                .offset(x: segment * CGFloat(index))
                .motion(Motion.nav, value: index, reduce: reduce)
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { value, label in
                    Button {
                        selection = value
                    } label: {
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(value == selection ? Palette.onFill : Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(value == selection ? .isSelected : [])
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(4)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line))
    }
}

/// Lays children out side by side with widths in the given ratios (CSS flex-grow).
struct RatioRow: Layout {
    var ratios: [CGFloat]
    var spacing: CGFloat = 8

    private func widths(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        let r = (0..<n).map { $0 < ratios.count ? ratios[$0] : 1 }
        let avail = max(0, total - spacing * CGFloat(n - 1))
        let sum = r.reduce(0, +)
        return r.map { avail * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        let ws = widths(w, subviews.count)
        let h = zip(subviews, ws).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (s, w) in zip(subviews, widths(bounds.width, subviews.count)) {
            s.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
