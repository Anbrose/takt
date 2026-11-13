import SwiftUI
import TaktAPI
import TaktCore

/// 规划模式 for any level: header, toolbar, task list, drag-to-reorder with 取消 / 保存, 新建.
public struct PlanScreen: View {
    @Bindable var plan: PlanModel
    @Binding var theme: ThemeChoice
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.colorScheme) private var scheme
    @State private var adding = false

    public init(plan: PlanModel, theme: Binding<ThemeChoice>) {
        self.plan = plan
        self._theme = theme
    }

    private var level: LevelModel { plan.current }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                LevelList(model: level, plan: plan, adding: $adding, onOpen: open)
                    .id(level.taskId)
                    .transition(navTransition)
            }
            .clipped()
        }
        .background(Palette.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { SaveBar(model: level) }
        .overlay { NewTaskSheet(model: level, isPresented: $adding) }
        .overlay(alignment: .top) { NoticeToast(model: level) }
        .task(id: level.taskId) { if level.level == nil { await level.load() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: plan.isRoot ? 0 : Metrics.hit, alignment: .leading)
            .opacity(plan.isRoot ? 0 : 1)
            .clipped()
            .disabled(plan.isRoot)
            .accessibilityLabel("返回")
            .padding(.leading, -8)

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.overline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Text(level.name.isEmpty ? plan.project.name : level.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }
            .id(level.taskId)
            .transition(navTransition)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)

            Button {
                theme = (scheme == .dark) ? .light : .dark
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.text)
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scheme == .dark ? "切换到浅色" : "切换到深色")
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
    }

    /// 进入子任务 / 返回: content slides in from the right / left and fades (prototype inR / inL).
    private var navTransition: AnyTransition {
        if reduce { return .identity }
        let dx: CGFloat = plan.direction == .forward ? 28 : -28
        return .asymmetric(insertion: .offset(x: dx).combined(with: .opacity), removal: .opacity)
    }

    private func open(_ id: String) {
        Motion.with(Motion.nav, reduce: reduce) { plan.open(id) }
    }

    private func back() {
        Motion.with(Motion.nav, reduce: reduce) { plan.back() }
    }
}

public enum ThemeChoice: String, Sendable {
    case system, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - List

struct LevelList: View {
    @Bindable var model: LevelModel
    @Bindable var plan: PlanModel
    @Binding var adding: Bool
    let onOpen: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(RouteMatrix.self) private var matrix

    /// Tasks in the order a release would give (live drag preview → 预览中 numbers).
    private var previewTasks: [TaskSummary] {
        let byId = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        return model.liveOrder.compactMap { byId[$0] }
    }

    private var summary: RouteSummary {
        RouteSummary.make(
            tasks: previewTasks, selected: model.selection, editing: model.isEditing,
            objective: plan.objective, mode: plan.travel, matrix: matrix
        )
    }

    /// In-scope located points; what the route matrix needs for this level.
    private var routePoints: [GeoPoint] {
        model.items.compactMap { t in
            guard model.scopeAll || model.isSelected(t.id), let lat = t.lat, let lng = t.lng else { return nil }
            return GeoPoint(lat: lat, lng: lng)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                        .id("top")
                    if plan.mapOn {
                        MapPanel(
                            tasks: previewTasks, scope: model.selection, summary: summary,
                            scopeLabel: model.scopeLabel, loading: matrix.pending > 0,
                            objective: $plan.objective, travel: $plan.travel,
                            onOptimize: { order in Task { await model.applyOrder(order) } }
                        )
                        .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: -12)))
                    }
                    HStack(alignment: .top, spacing: 0) {
                        OrderRail(model: model)
                        rows
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 4)
                .padding(.bottom, model.isEditing ? 96 : 16)
            }
            .scrollDisabled(model.drag != nil)
            .task(id: plan.mapOn ? "\(routePoints)|\(plan.travel)" : "off") {
                if plan.mapOn { matrix.prefetch(routePoints, mode: plan.travel) }
            }
            .onChange(of: plan.mapOn) { _, on in
                if on { Motion.with(Motion.settle, reduce: reduce) { proxy.scrollTo("top", anchor: .top) } }
            }
            .sensoryFeedback(.selection, trigger: model.drag?.to)
            .onChange(of: model.lastAdded) { _, id in
                guard let id else { return }
                Motion.with(Motion.settle, reduce: reduce) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .overlay {
                if model.level == nil, model.status == .loading { ProgressView() }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ToolButton(icon: "point.topleft.down.to.point.bottomright.curvepath", title: "地图", pressed: plan.mapOn) {
                Motion.with(Motion.settle, reduce: reduce) { plan.mapOn.toggle() }
            }
            .accessibilityAddTraits(plan.mapOn ? .isSelected : [])
            ToolButton(icon: "plus", title: "新建") {
                Motion.with(Motion.sheet, reduce: reduce) { adding = true }
            }
            Spacer(minLength: 0)
            Text(model.scopeLabel)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .contentTransition(.numericText())
            Button {
                Motion.with(Motion.fade, reduce: reduce) { model.toggleAll() }
            } label: {
                Text(model.allLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
                    .frame(minWidth: Metrics.hit, minHeight: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.items.isEmpty)
        }
    }

    private var rows: some View {
        let legs = plan.mapOn ? summary.legText : [:]
        return VStack(spacing: LevelModel.rowGap) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, task in
                let dragged = model.drag?.id == task.id
                TaskRow(
                    task: task,
                    number: index + 1,
                    selected: model.isSelected(task.id),
                    dragging: dragged,
                    compact: plan.mapOn,
                    leg: legs[task.id] ?? "",
                    onToggle: { Motion.with(Motion.fade, reduce: reduce) { model.toggle(task.id) } },
                    onOpen: { onOpen(task.id) },
                    onDragChanged: { dy in
                        if model.drag == nil { Motion.with(Motion.sheet, reduce: reduce) { model.beginDrag(task.id) } }
                        model.updateDrag(offset: dy)
                    },
                    onDragEnded: { Motion.with(Motion.settle, reduce: reduce) { model.endDrag() } },
                    onMove: { delta in Motion.with(Motion.settle, reduce: reduce) { model.move(task.id, by: delta) } }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.rowHeights[task.id] = $0 }
                .offset(y: dragged ? model.drag?.offset ?? 0 : model.shift(for: task.id))
                // The dragged card follows the finger exactly; the others glide out of the way.
                .animation(dragged || reduce ? nil : Motion.makeRoom, value: model.drag?.to)
                .zIndex(dragged ? 2 : 0)
                .transition(reduce ? .identity : .asymmetric(
                    insertion: .offset(x: 28).combined(with: .opacity), removal: .opacity))
                .id(task.id)
            }
        }
        .frame(maxWidth: .infinity)
        // Order changes not driven by a gesture (重排, 保存 result, reload) slide rows into place.
        .motion(Motion.settle, value: model.items.map(\.id), reduce: reduce)
    }
}

/// While dragging, a narrow column on the left shows the whole level's live order
/// ("序号 + 两字缩写"), with the dragged task highlighted.
struct OrderRail: View {
    let model: LevelModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let on = model.drag != nil
        let live = model.liveOrder
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, t in
                let pos = live.firstIndex(of: t.id) ?? i
                let held = model.drag?.id == t.id
                HStack(spacing: 5) {
                    Text("\(pos + 1)")
                        .foregroundStyle(Palette.muted)
                        .fontWeight(.medium)
                        .frame(width: 14, alignment: .trailing)
                    Text(Order.railAbbr(t.short))
                        .foregroundStyle(held ? Palette.accentText : Palette.text)
                        .fontWeight(held ? .bold : .medium)
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(height: 26)
                .offset(y: CGFloat(pos - i) * 26)
                .motion(Motion.makeRoom, value: pos, reduce: reduce)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 52, alignment: .leading)
        .frame(width: on ? 52 : 0, alignment: .leading)
        .padding(.trailing, on ? 8 : 0)
        .opacity(on ? 1 : 0)
        .clipped()
        .motion(Motion.settle, value: on, reduce: reduce)
        .accessibilityHidden(true)
    }
}

// MARK: - Bottom bar

/// 取消 / 保存: slides up from the bottom while a drag or an unsaved order exists.
struct SaveBar: View {
    let model: LevelModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let shown = model.isEditing
        ZStack {
            if shown {
                bar.transition(reduce ? .opacity : .move(edge: .bottom))
            }
        }
        .motion(Motion.sheet, value: shown, reduce: reduce)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            WideButton(title: "取消", kind: .secondary) {
                Motion.with(Motion.settle, reduce: reduce) { model.cancel() }
            }
            WideButton(title: "保存", kind: .primary, busy: model.status == .saving) {
                Task {
                    await model.save()
                }
            }
            .disabled(model.draft == nil || model.status == .saving)
        }
        .padding(EdgeInsets(top: 10, leading: Metrics.gutter, bottom: 10, trailing: Metrics.gutter))
        .background {
            Palette.surface
                .overlay(alignment: .top) { Palette.line.frame(height: 1) }
                .shadow(color: .black.opacity(0.12), radius: 12, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Notice

struct NoticeToast: View {
    @Bindable var model: LevelModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Group {
            if let text = model.notice {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.onFill)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Palette.fill, in: Capsule())
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        Motion.with(Motion.fade, reduce: reduce) { model.notice = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.top, 8)
        .motion(Motion.sheet, value: model.notice, reduce: reduce)
    }
}
