import SwiftUI
import TaktAPI
#if canImport(UIKit)
import UIKit
#endif

/// Drag-to-project state on the note detail (prototype `noteVals` › 拖动状态): a chain or step lifted by a
/// long press, the 「加入到项目」 dock under it, what the finger is over, the 「放入「X」？」 question and the
/// 「✓ 名」 after an import. Points are in `NoteDetailScreen.space`.
@available(iOS 26, macOS 26, *)
@MainActor
@Observable
final class ImportDrag {
    /// A drop area of the dock, registered with its frame.
    enum Zone: Hashable { case dock, back, project(String), task(String), end }
    /// Where on a task row: top 28% = before, bottom 28% = after, the middle = into.
    enum Band: Equatable { case before, after, into }
    /// What the finger is over.
    enum Over: Equatable { case dock, back, project(String), task(String, Band), end }

    struct Lifted: Equatable {
        let chain: String
        /// nil = the whole chain.
        let step: String?
        let label: String
        let count: Int
        /// Where it was picked up; a cancelled drag flies back here.
        let origin: CGPoint
    }

    struct Ask: Equatable {
        let lifted: Lifted
        let task: String
        let name: String
    }

    let detail: NoteDetailModel
    let dock: ImportDockModel
    var reduce = false
    /// After the first successful import (hides the 「长按拖到项目」 tip for good).
    var onImported: () -> Void = {}

    private(set) var lifted: Lifted?
    /// The finger (ghost centre).
    private(set) var point: CGPoint = .zero
    /// Released: the ghost is gone (importing, or waiting for 「放入」).
    private(set) var hidden = false
    private(set) var flyingBack = false
    private(set) var over: Over?
    private(set) var dockOpen = false
    private(set) var committing = false
    /// 「✓ 名」 for about a second after an import.
    private(set) var done: String?
    private(set) var ask: Ask?
    /// Bumped on every dock level change; the dock's content slides in from the right (open) or left (back).
    private(set) var seq = 0
    private(set) var fromLeading = false

    /// Drop zones on screen, each with the token of the view that registered it.
    var frames: [Zone: (token: UUID, rect: CGRect)] = [:]
    private var dwell: Task<Void, Never>?
    private var endedAt = Date.distantPast

    init(detail: NoteDetailModel, dock: ImportDockModel) {
        self.detail = detail
        self.dock = dock
    }

    /// Following the finger (lifted and not yet released).
    var live: Bool { lifted != nil && !hidden }
    var dockShown: Bool { live || committing || done != nil }
    /// A drag just ended: the row's buttons share its touches, so the release isn't a tap (prototype: 450 ms).
    var justDragged: Bool { Date().timeIntervalSince(endedAt) < 0.45 }
    var overInto: Bool { if case .task(_, .into) = over { true } else { false } }

    func isDragging(chain: String) -> Bool { live && lifted?.chain == chain && lifted?.step == nil }
    func isDragging(step: String) -> Bool { live && lifted?.step == step }

    // MARK: Gesture

    func lift(chain: Chain, step: ChainStep?, at p: CGPoint) {
        guard lifted == nil, ask == nil, !committing else { return }
        Task { await dock.load() }
        dock.back()
        frames = frames.filter { $0.key == .dock }
        point = p
        over = nil
        dockOpen = false
        done = nil
        seq = 0
        animate(Motion.fade) {
            lifted = Lifted(
                chain: chain.id, step: step?.id, label: step?.name ?? chain.name, count: step == nil ? chain.steps.count : 1,
                origin: p)
        }
    }

    func move(to p: CGPoint) {
        guard live else { return }
        point = p
        let next = hit(p)
        if next != nil && !dockOpen { animate(Motion.dock) { dockOpen = true } }
        guard next != over else { return }
        animate(.easeInOut(duration: 0.18)) { over = next }
        dwell?.cancel()
        switch next {
        case .project(let id):
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(520))
                guard let self, !Task.isCancelled, self.over == .project(id) else { return }
                await self.dock.open(id)
                guard self.dock.opened?.project.id == id else { return }
                self.fromLeading = false
                self.animate(Motion.dockLevel) { self.over = nil; self.seq += 1 }
            }
        case .back:
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard let self, !Task.isCancelled, self.over == .back else { return }
                self.fromLeading = true
                self.animate(Motion.dockLevel) { self.dock.back(); self.over = nil; self.seq += 1 }
            }
        default:
            break
        }
    }

    /// The finger lifted (`released`) or the system took the touch away.
    func end(released: Bool) {
        dwell?.cancel()
        guard let l = lifted, live else { return }
        endedAt = Date()
        guard released else { return cancel(l) }
        let level = dock.opened?.level
        switch over {
        case .project(let id):
            guard let p = dock.projects.first(where: { $0.id == id }) else { return cancel(l) }
            commit(l, .end(parent: p.rootTaskId))
        case .end:
            guard let level else { return cancel(l) }
            commit(l, .end(parent: level.task.id))
        case .task(let id, .before):
            guard let level else { return cancel(l) }
            commit(l, .before(parent: level.task.id, task: id))
        case .task(let id, .after):
            guard let level, let i = level.children.firstIndex(where: { $0.id == id }) else { return cancel(l) }
            let next = level.children.indices.contains(i + 1) ? level.children[i + 1].id : nil
            commit(l, next.map { .before(parent: level.task.id, task: $0) } ?? .end(parent: level.task.id))
        case .task(let id, .into):
            guard let task = level?.children.first(where: { $0.id == id }) else { return cancel(l) }
            animate(Motion.fade) {
                hidden = true
                over = nil
                dockOpen = false
                ask = Ask(lifted: l, task: id, name: task.name)
            }
        case .dock, .back, nil:
            cancel(l)
        }
    }

    // MARK: Picker (VoiceOver) path

    /// 「放这里」 / a task in `ImportPicker`: the same destinations as a drop, without a ghost.
    func pick(chain: String, step: String?, to destination: DropDestination, intoName: String?) {
        guard lifted == nil, !committing else { return }
        let l = Lifted(chain: chain, step: step, label: "", count: 0, origin: .zero)
        lifted = l
        hidden = true
        if case .into(let task) = destination, let intoName {
            animate(Motion.fade) { ask = Ask(lifted: l, task: task, name: intoName) }
        } else {
            commit(l, destination)
        }
    }

    // MARK: 放入「X」？

    func confirm() {
        guard let a = ask else { return }
        animate(Motion.fade) { ask = nil }
        commit(a.lifted, .into(task: a.task))
    }

    func dismissAsk() {
        animate(Motion.fade) {
            ask = nil
            lifted = nil
            hidden = false
        }
        dock.back()
    }

    // MARK: Private

    private func commit(_ l: Lifted, _ destination: DropDestination) {
        animate(Motion.dock) {
            hidden = true
            over = nil
            dockOpen = false
            committing = true
        }
        Task {
            let name = await detail.importDragged(chain: l.chain, step: l.step, to: destination)
            animate(Motion.fade) {
                committing = false
                done = name
            }
            if name != nil {
                onImported()
                try? await Task.sleep(for: .milliseconds(1200))
            }
            animate(Motion.dock) {
                done = nil
                lifted = nil
                hidden = false
            }
            dock.back()
        }
    }

    /// Released anywhere else: the ghost flies back to where it was picked up, then goes.
    private func cancel(_ l: Lifted) {
        animate(Motion.flyBack) {
            flyingBack = true
            point = l.origin
            over = nil
            dockOpen = false
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            animate(Motion.fade) {
                lifted = nil
                flyingBack = false
            }
            dock.back()
        }
    }

    /// Rows before the dock itself; a task row is split into before / into / after bands.
    private func hit(_ p: CGPoint) -> Over? {
        var found: Over?
        for (zone, (_, r)) in frames where zone != .dock && r.contains(p) {
            switch zone {
            case .back: found = .back
            case .project(let id): found = .project(id)
            case .end: found = .end
            case .task(let id):
                let rel = (p.y - r.minY) / max(r.height, 1)
                found = .task(id, rel < 0.28 ? .before : rel > 0.72 ? .after : .into)
            case .dock: break
            }
        }
        if found == nil, frames[.dock]?.rect.contains(p) == true { found = .dock }
        return found
    }

    private func animate(_ a: Animation, _ body: () -> Void) {
        Motion.with(reduce ? Motion.fade : a, reduce: false, body)
    }
}

// MARK: - Views

@available(iOS 26, macOS 26, *)
extension View {
    /// Registers this view's frame as a drop zone while it is on screen.
    func dropZone(_ zone: ImportDrag.Zone, in drag: ImportDrag) -> some View {
        modifier(DropZone(zone: zone, drag: drag))
    }
}

/// A view going away (an old dock level sliding out) may share its zone with the one replacing it: it only
/// removes the frame it registered itself.
@available(iOS 26, macOS 26, *)
private struct DropZone: ViewModifier {
    let zone: ImportDrag.Zone
    let drag: ImportDrag
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NoteDetailScreen.space)) } action: {
                drag.frames[zone] = (token, $0)
            }
            .onDisappear { if drag.frames[zone]?.token == token { drag.frames[zone] = nil } }
    }
}

/// 「加入到项目」 at the bottom: a 72 pt dashed peek while dragging, a 440 pt panel once the finger is in it
/// (Project rows with a dwell bar; an opened Project's tasks with before / after lines and the into highlight;
/// the dashed end zone), and 「✓ 名」 after an import.
@available(iOS 26, macOS 26, *)
struct ImportDock: View {
    @Bindable var drag: ImportDrag
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var dock: ImportDockModel { drag.dock }
    private var accent: Bool { drag.dockOpen || drag.over == .dock || drag.done != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            if drag.dockOpen {
                panel
                    .transition(.opacity.animation(.easeInOut(duration: 0.22).delay(reduce ? 0 : 0.08)))
            }
            peek
        }
        .frame(maxWidth: .infinity)
        .frame(height: drag.dockOpen ? 440 : 72)
        .background(drag.done != nil ? Palette.soft : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(accent ? Palette.accent : Palette.line, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 14, y: -6)
        .dropZone(.dock, in: drag)
        .animation(reduce ? nil : Motion.dock, value: drag.dockOpen)
        .animation(.easeInOut(duration: 0.2), value: accent)
        .animation(.easeInOut(duration: 0.24), value: drag.done)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dock")
    }

    /// Bottom 68 pt: 「加入到项目」, a spinner while importing, or 「✓ 名」.
    private var peek: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 17, weight: .semibold))
                Text("加入到项目")
            }
            .opacity(!drag.dockOpen && !drag.committing && drag.done == nil ? 1 : 0)
            .accessibilityHidden(true)
            if drag.committing { Spinner().transition(.opacity) }
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                Text(drag.done ?? "")
            }
            .opacity(drag.done != nil ? 1 : 0)
            .accessibilityHidden(true)
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(Palette.accentText)
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .allowsHitTesting(false)
        // 「✓ 名」 after an import is the value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加入到项目")
        .accessibilityValue(drag.done ?? "")
        .accessibilityIdentifier("dock.peek")
        .animation(.easeInOut(duration: 0.2), value: drag.committing)
    }

    private var panel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                backZone
                Text(dock.opened?.project.name ?? "加入到项目")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(drag.seq)
                    .transition(slide)
            }
            .frame(minHeight: 44)
            ZStack(alignment: .top) {
                rows
                    .id(drag.seq)
                    .transition(slide)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var slide: AnyTransition {
        if reduce || drag.seq == 0 { return .identity }
        return .asymmetric(insertion: .offset(x: drag.fromLeading ? -28 : 28).combined(with: .opacity), removal: .identity)
    }

    @ViewBuilder private var backZone: some View {
        let on = dock.opened != nil
        Image(systemName: "chevron.left")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Palette.text)
            .frame(width: on ? 40 : 0, height: 40)
            .background(drag.over == .back ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
            .clipped()
            .opacity(on ? 1 : 0)
            .modifier(OptionalZone(zone: on ? .back : nil, drag: drag))
            .animation(.easeInOut(duration: 0.26), value: on)
            .animation(.easeInOut(duration: 0.2), value: drag.over == .back)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var rows: some View {
        VStack(spacing: 8) {
            if let opened = dock.opened {
                ForEach(opened.level.children, id: \.id) { t in
                    TaskDropRow(task: t, drag: drag)
                }
                EndZone(drag: drag)
            } else {
                ForEach(dock.projects, id: \.id) { p in
                    ProjectDropRow(project: p, count: dock.counts[p.id], drag: drag)
                }
            }
        }
    }
}

@available(iOS 26, macOS 26, *)
private struct OptionalZone: ViewModifier {
    let zone: ImportDrag.Zone?
    let drag: ImportDrag

    func body(content: Content) -> some View {
        if let zone { content.dropZone(zone, in: drag) } else { content }
    }
}

/// A Project in the dock: hovering fills the bar along its bottom for 520 ms, then the Project opens.
@available(iOS 26, macOS 26, *)
private struct ProjectDropRow: View {
    let project: Project
    let count: Int?
    let drag: ImportDrag

    private var on: Bool { drag.over == .project(project.id) }

    var body: some View {
        HStack(spacing: 8) {
            Text(project.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count, count > 0 {
                Text("\(count) 项").font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.muted)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(on ? Palette.soft : Palette.bg)
        .overlay(alignment: .bottomLeading) {
            GeometryReader { g in
                Palette.accent
                    .frame(width: on ? g.size.width : 0, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    // Fills over the dwell; snaps back at once.
                    .animation(on ? .linear(duration: 0.52) : nil, value: on)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(on ? Palette.accent : Palette.line, lineWidth: 1.5))
        .animation(.easeInOut(duration: 0.18), value: on)
        .dropZone(.project(project.id), in: drag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.name)
        .accessibilityIdentifier("dock.project.\(project.name)")
    }
}

/// A task of the opened level: insertion line above / below, or the into highlight with ＋.
@available(iOS 26, macOS 26, *)
private struct TaskDropRow: View {
    let task: TaskSummary
    let drag: ImportDrag

    private var band: ImportDrag.Band? {
        if case .task(let id, let b) = drag.over, id == task.id { return b }
        return nil
    }

    var body: some View {
        let into = band == .into
        HStack(spacing: 8) {
            Text(task.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if task.childCount > 0 {
                Text("\(task.childCount) 项").font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.accentText)
                .opacity(into ? 1 : 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(into ? Palette.soft : Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(into ? Palette.accent : Palette.line, lineWidth: 1.5))
        .overlay(alignment: .top) { line(band == .before).offset(y: -6) }
        .overlay(alignment: .bottom) { line(band == .after).offset(y: 6) }
        .animation(.easeInOut(duration: 0.14), value: band)
        .dropZone(.task(task.id), in: drag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.name)
        .accessibilityIdentifier("dock.task.\(task.name)")
    }

    private func line(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Palette.accent)
            .frame(height: 3)
            .padding(.horizontal, 8)
            .opacity(on ? 1 : 0)
    }
}

/// Dashed ＋ under the opened level's tasks: the end of that level.
@available(iOS 26, macOS 26, *)
private struct EndZone: View {
    let drag: ImportDrag

    var body: some View {
        let on = drag.over == .end
        Image(systemName: "plus")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(on ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(on ? Palette.accent : Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .animation(.easeInOut(duration: 0.18), value: on)
            .dropZone(.end, in: drag)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("末尾")
            .accessibilityIdentifier("dock.end")
    }
}

/// The card under the finger: name and step count; 1.03 while dragging, 0.88 over an into target.
@available(iOS 26, macOS 26, *)
struct DragGhost: View {
    let lifted: ImportDrag.Lifted
    let into: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(lifted.label)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lifted.count > 1 {
                Text("\(lifted.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.onFill)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Palette.fill, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 220)
        .frame(minHeight: 56)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.accent, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.26), radius: 17, y: 14)
        .scaleEffect(into ? 0.88 : 1.03)
        .animation(.easeInOut(duration: 0.2), value: into)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 「放入「X」？」 — 取消 / 放入 (drag import and nesting in the plan).
struct NestConfirm: View {
    let name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("放入「\(name)」？")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    WideButton(title: "取消", kind: .secondary, action: onCancel)
                    WideButton(title: "放入", kind: .primary, action: onConfirm)
                        .accessibilityIdentifier("confirm.nest")
                }
            }
            .padding(EdgeInsets(top: 22, leading: 16, bottom: 16, trailing: 16))
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 16)
            .scaleEffect(shown || reduce ? 1 : 0.96)
            .padding(.horizontal, 40)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { withAnimation(Motion.toggle) { shown = true } }
    }
}

// MARK: - Long press

#if canImport(UIKit)
/// Long press (420 ms, 8 pt tolerance) that keeps reporting the finger until it lifts. UIKit, because a
/// SwiftUI long press → drag sequence knows nothing of the finger until it moves (the ghost must appear
/// under it at 420 ms) and a scroll view doesn't share touches with a simultaneous SwiftUI drag.
@available(iOS 26, *)
struct LiftPress: UIGestureRecognizerRepresentable {
    let onLift: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: (_ released: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.42
        g.allowableMovement = 8
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    /// Shares touches with the buttons inside the row, but not with the scroll view: once lifted, the list
    /// stays put.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let p = context.converter.location(in: .named(NoteDetailScreen.space))
        switch g.state {
        case .began: onLift(p)
        case .changed: onMove(p)
        case .ended: onEnd(true)
        case .cancelled, .failed: onEnd(false)
        default: break
        }
    }
}
#endif

@available(iOS 26, macOS 26, *)
extension View {
    /// Long press lifts `chain` (or one `step` of it) into the drag.
    func liftable(_ drag: ImportDrag, chain: Chain, step: ChainStep?) -> some View {
        #if canImport(UIKit)
        gesture(LiftPress(
            onLift: { drag.lift(chain: chain, step: step, at: $0) },
            onMove: { drag.move(to: $0) },
            onEnd: { drag.end(released: $0) }))
        #else
        self
        #endif
    }
}
