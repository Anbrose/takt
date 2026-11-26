import AVFoundation
import SwiftUI
import TaktAPI

/// One note (prototype `noteVals`): header (`m:ss · 中` over the title), 文字稿 / 任务链 segmented, the transcript
/// (speaker chip → rename, tap a line to play from it), the chains (long press a header or a step to drag it
/// into a Project; tap the header to rename, the time to hear it), 已导入, the player bar, the dock.
@available(iOS 26, macOS 26, *)
struct NoteDetailScreen: View {
    /// Coordinate space of the drag: the ghost, the drop zones and the finger.
    static let space = "noteDetail"

    @Bindable var detail: NoteDetailModel
    /// The list row it was opened from, shown while the note loads.
    let item: NoteItem?
    /// 自动生成任务 is extracting this note right now.
    let autoExtracting: Bool
    /// Still on the device / being processed (no transcript on the server yet).
    let processing: Bool
    let onBack: () -> Void

    @State private var drag: ImportDrag
    @State private var player = NotePlayer()
    @State private var tab = Tab.text
    /// The rename sheet's subject; kept after closing so the title doesn't change while it slides away.
    @State private var naming = Naming.chain("", "")
    @State private var namingOn = false
    @State private var loaded = false
    @State private var picking: ImportPicker.Item?
    /// Chains came in while this screen was open: they slide in, staggered.
    @State private var entering = false
    @AppStorage("notes.dragTipDone") private var tipDone = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    enum Tab { case text, chains }

    /// Rename sheet: a speaker id or a chain id.
    enum Naming: Equatable {
        case speaker(String, String)
        case chain(String, String)
        var initial: String { switch self { case .speaker(_, let n), .chain(_, let n): n } }
    }

    init(
        detail: NoteDetailModel, dock: ImportDockModel, item: NoteItem?, autoExtracting: Bool, processing: Bool,
        onBack: @escaping () -> Void
    ) {
        self.detail = detail
        self.item = item
        self.autoExtracting = autoExtracting
        self.processing = processing
        self.onBack = onBack
        _drag = State(initialValue: ImportDrag(detail: detail, dock: dock))
    }

    private var note: Note? { detail.note }
    private var chains: [Chain] { note?.extraction.chains ?? [] }
    private var stepsLeft: Int { chains.reduce(0) { $0 + $1.steps.count } }
    /// Loading, or no transcript yet: the transcript pane's spinner.
    private var busy: Bool { !loaded || (note.map { $0.transcript.isEmpty } ?? false) }
    private var autoBusy: Bool { autoExtracting && chains.isEmpty && !busy }
    private var canExtract: Bool {
        guard let n = note else { return false }
        return !detail.isLocalOnly && n.hasTranscript && chains.isEmpty && n.imported.isEmpty && !autoExtracting
    }

    private var title: String {
        if let n = note { return NoteLanguage.title(n.title, createdAt: n.createdAt) }
        return item.map { NoteLanguage.title($0.title, createdAt: $0.createdAt) } ?? ""
    }

    private var meta: String {
        let (ms, locale) = note.map { ($0.durationMs, $0.locale) } ?? item.map { ($0.durationMs, $0.locale) } ?? (0, "")
        return locale.isEmpty ? "" : "\(NoteLanguage.clock(ms)) · \(NoteLanguage.short(locale))"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                segmented
                panes
            }
            .accessibilityHidden(namingOn || picking != nil || drag.ask != nil)

            playerBar
            dockLayer
            ProjectNameSheet(
                isPresented: $namingOn, title: { if case .speaker = naming { "说话人" } else { "任务链" } }(),
                action: "保存", initial: naming.initial, fieldLabel: nil, onSubmit: rename)
            ImportPicker(item: $picking, drag: drag)
            askLayer
        }
        .overlay(alignment: .topLeading) { ghostLayer }
        .overlay(alignment: .top) { DetailToast(detail: detail) }
        .coordinateSpace(.named(Self.space))
        .background(Palette.bg.ignoresSafeArea())
        .task {
            drag.reduce = reduce
            drag.onImported = { tipDone = true }
            if detail.note == nil { await detail.load() }
            loaded = true
        }
        .task(id: note?.imported.map(\.parentTaskId)) { await detail.loadTargets() }
        .task(id: chains.map(\.id)) { openTestPick() }
        .onChange(of: reduce) { _, r in drag.reduce = r }
        // The transcript or the draft arrived on the server meanwhile.
        .onChange(of: processing) { _, now in if !now { Task { await detail.load() } } }
        .onChange(of: autoExtracting) { _, now in
            guard !now else { return }
            entering = true
            Task { await detail.load() }
        }
        .onDisappear { player.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            BackButton(action: onBack).accessibilityIdentifier("note.back")
            VStack(alignment: .leading, spacing: 2) {
                Text(meta)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .contentTransition(.numericText())
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.fade, value: meta)
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
        .frame(minHeight: 76)
    }

    private var segmented: some View {
        GeometryReader { g in
            let w = (g.size.width - 8) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.fill)
                    .frame(width: w)
                    .offset(x: tab == .chains ? w : 0)
                    .animation(reduce ? Motion.fade : Motion.segment, value: tab)
                HStack(spacing: 0) {
                    segment("文字稿", count: nil, .text)
                    segment("任务链", count: stepsLeft, .chains)
                }
            }
            .padding(4)
        }
        .frame(height: 52)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1))
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 10)
    }

    private func segment(_ label: String, count: Int?, _ t: Tab) -> some View {
        let on = tab == t
        return Button { Motion.with(Motion.pane, reduce: reduce) { tab = t } } label: {
            HStack(spacing: 6) {
                Text(label)
                if let count {
                    Text(count > 0 ? "\(count)" : "")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .opacity(count > 0 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.24), value: count)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(on ? Palette.onFill : Palette.text)
            .animation(.easeInOut(duration: 0.26), value: on)
            .frame(maxWidth: .infinity, minHeight: Metrics.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(count.map { $0 > 0 ? "\($0)" : "" } ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(t == .text ? "note.tab.text" : "note.tab.chains")
    }

    // MARK: Panes

    private var panes: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                transcript
                    .frame(width: g.size.width)
                    .allowsHitTesting(tab == .text)
                    .accessibilityHidden(tab != .text)
                chainsPane
                    .frame(width: g.size.width)
                    .allowsHitTesting(tab == .chains)
                    .accessibilityHidden(tab != .chains)
            }
            .offset(x: tab == .chains ? -g.size.width : 0)
        }
        .clipped()
        // The lists scroll on under the home indicator.
        .ignoresSafeArea(edges: .bottom)
    }

    private var speakerIndex: [String: Int] {
        Dictionary((note?.speakers ?? []).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var activeLine: Int? {
        guard let at = player.at, let lines = note?.transcript else { return nil }
        return lines.lastIndex { $0.startMs <= at } ?? 0
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    let lines = note?.transcript ?? []
                    let names = Dictionary((note?.speakers ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                    let many = (note?.speakers.count ?? 0) > 1
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        LineRow(
                            line: l, speaker: l.speaker.map { names[$0] ?? $0 } ?? "",
                            colors: chipColors(l.speaker), showSpeaker: many && l.speaker != nil,
                            active: activeLine == i,
                            onPlay: { play(from: l.startMs) },
                            onRename: {
                                guard let s = l.speaker, !detail.isLocalOnly else { return }
                                naming = .speaker(s, names[s] ?? s)
                                namingOn = true
                            })
                        .id(i)
                    }
                }
                .padding(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 104, trailing: Metrics.gutter))
                .animation(.easeInOut(duration: 0.22), value: activeLine)
            }
            .overlay {
                // Only in the hierarchy while busy: a hidden spinner would still redraw every frame.
                if busy && tab == .text { Spinner(size: 36, radius: 11.5, lineWidth: 3.2).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.26), value: busy)
            .onChange(of: player.jumpSeq) { _, _ in
                guard let i = activeLine else { return }
                Motion.with(Motion.nav, reduce: reduce) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func chipColors(_ speaker: String?) -> (Color, Color) {
        switch (speaker.flatMap { speakerIndex[$0] } ?? 0) % 3 {
        case 1: (Palette.sp2bg, Palette.sp2fg)
        case 2: (Palette.sp3bg, Palette.sp3fg)
        default: (Palette.soft, Palette.accentText)
        }
    }

    private var tipOn: Bool { !chains.isEmpty && !tipDone && !drag.live }

    private var chainsPane: some View {
        ScrollView {
            VStack(spacing: 0) {
                if tipOn {
                    DragTip()
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
                ForEach(Array(chains.enumerated()), id: \.element.id) { i, c in
                    ChainCard(
                        chain: c, drag: drag, entering: entering, delay: Double(i) * 0.06,
                        timeOf: { NoteLanguage.clock($0.quote.startMs) },
                        onRename: {
                            guard !drag.justDragged else { return }
                            naming = .chain(c.id, c.name)
                            namingOn = true
                        },
                        onDelete: {
                            guard !drag.justDragged else { return }
                            Task { await detail.edit(chains.filter { $0.id != c.id }) }
                        },
                        onJump: { s in if !drag.justDragged { jump(to: s.quote.startMs) } },
                        onPick: { s in picking = .init(chain: c.id, step: s?.id, name: s?.name ?? c.name) })
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                ForEach(note?.imported ?? [], id: \.stepId) { im in
                    ImportedRow(name: im.stepName, target: detail.targets[im.parentTaskId])
                        .padding(.bottom, 4)
                        .transition(reduce ? .opacity : .offset(x: 28).combined(with: .opacity))
                }
            }
            .padding(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 104, trailing: Metrics.gutter))
            .animation(reduce ? Motion.fade : Motion.collapse, value: chains)
            .animation(reduce ? Motion.fade : .easeOut(duration: 0.32), value: note?.imported.map(\.stepId))
            .animation(reduce ? Motion.fade : Motion.collapse, value: tipOn)
        }
        .scrollDisabled(drag.live)
        .overlay {
            ZStack {
                if canExtract { extractButton.transition(.opacity) }
                if autoBusy { Spinner(size: 36, radius: 11.5, lineWidth: 3.2).transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.26), value: canExtract)
            .animation(.easeInOut(duration: 0.26), value: autoBusy)
        }
    }

    private var extractButton: some View {
        Button {
            entering = true
            Task { await detail.extract() }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .opacity(detail.extracting ? 0 : 1)
                    if detail.extracting {
                        Spinner(size: 20, radius: 7.5, lineWidth: 2.2, track: Palette.onFill.opacity(0.35), arc: Palette.onFill)
                            .transition(.opacity)
                    }
                }
                .frame(width: 20, height: 20)
                .animation(.easeInOut(duration: 0.2), value: detail.extracting)
                Text("提取")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Palette.onFill)
            .padding(.leading, 20)
            .padding(.trailing, 24)
            .frame(minHeight: 52)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(detail.extracting)
        .accessibilityLabel("提取")
        .accessibilityIdentifier("note.extract")
    }

    // MARK: Player

    private func play(from ms: Int) {
        player.play(from: ms, duration: note?.durationMs ?? 0, detail: detail)
    }

    private func jump(to ms: Int) {
        Motion.with(Motion.pane, reduce: reduce) { tab = .text }
        play(from: ms)
        player.jumpSeq += 1
    }

    @ViewBuilder private var playerBar: some View {
        let on = player.at != nil && !busy && !drag.dockShown
        ZStack(alignment: .bottom) {
            if on {
                PlayerBar(player: player, duration: note?.durationMs ?? 0, detail: detail)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 24)
                    .transition(reduce ? .opacity : .offset(y: 24).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .animation(reduce ? Motion.fade : Motion.langSheet, value: on)
    }

    // MARK: Drag layers

    private var dockLayer: some View {
        ZStack(alignment: .bottom) {
            if drag.dockShown {
                ImportDock(drag: drag)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                    .transition(reduce ? .opacity : .offset(y: 140))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .animation(reduce ? Motion.fade : Motion.dock, value: drag.dockShown)
    }

    private var ghostLayer: some View {
        ZStack(alignment: .topLeading) {
            if let l = drag.lifted, !drag.hidden {
                DragGhost(lifted: l, into: drag.overInto)
                    .offset(x: drag.point.x - 110, y: drag.point.y - 30)
                    .animation(drag.flyingBack && !reduce ? Motion.flyBack : nil, value: drag.point)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var askLayer: some View {
        ZStack {
            if let a = drag.ask {
                NestConfirm(name: a.name, onCancel: drag.dismissAsk, onConfirm: drag.confirm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: drag.ask)
    }

    // MARK: UI tests

    /// `-uitest-pick 名,名…` (demo only): opens `ImportPicker` for these chains / steps, one after another as
    /// the draft changes, as their 「加入到项目」 accessibility action does. XCUITest can't perform custom
    /// accessibility actions, so this is how the VoiceOver path is driven in tests.
    @MainActor private static var testPicks: [String] = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-demo"), let i = args.firstIndex(of: "-uitest-pick"), args.indices.contains(i + 1) else {
            return []
        }
        return args[i + 1].split(separator: ",").map(String.init)
    }()

    private func openTestPick() {
        guard let name = Self.testPicks.first, picking == nil else { return }
        if let c = chains.first(where: { $0.name == name }) {
            Self.testPicks.removeFirst()
            picking = .init(chain: c.id, step: nil, name: c.name)
        } else if let c = chains.first(where: { $0.steps.contains { $0.name == name } }),
                  let s = c.steps.first(where: { $0.name == name }) {
            Self.testPicks.removeFirst()
            picking = .init(chain: c.id, step: s.id, name: s.name)
        }
    }

    // MARK: Rename

    private func rename(_ name: String) async -> Bool {
        switch naming {
        case .speaker(let id, _):
            await detail.renameSpeaker(id, to: name)
        case .chain(let id, _):
            await detail.edit(chains.map { $0.id == id ? Chain(id: $0.id, name: name, steps: $0.steps) : $0 })
        }
        return detail.notice == nil
    }
}

// MARK: - Transcript

/// One transcript line: speaker chip (tap = rename), time, text. Tap plays from here; the playing line is outlined.
@available(iOS 26, macOS 26, *)
private struct LineRow: View {
    let line: TranscriptLine
    let speaker: String
    let colors: (Color, Color)
    let showSpeaker: Bool
    let active: Bool
    let onPlay: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onRename) {
                Text(speaker)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(colors.1)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(minWidth: 32, minHeight: 28)
                    .background(colors.0, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showSpeaker ? 1 : 0.0001)
            .disabled(!showSpeaker)
            .accessibilityHidden(!showSpeaker)
            .accessibilityLabel("说话人：\(speaker)")
            VStack(alignment: .leading, spacing: 2) {
                Text(NoteLanguage.clock(line.startMs))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                Text(line.text)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "播放", onPlay)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(active ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.controlRadius)
                .strokeBorder(active ? Palette.accent : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Chains

/// 「长按拖到项目」 with a bobbing hand, until the first successful drag.
@available(iOS 26, macOS 26, *)
private struct DragTip: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var down = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 14, weight: .semibold))
                .offset(y: down ? 2 : 0)
            Text("长按拖到项目")
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Palette.accentText)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(Palette.soft, in: Capsule())
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { down = true }
        }
    }
}

/// A chain card: the header (name = rename, trash) and its steps (number, name, place, time chip). Long press
/// the header to drag the whole chain, a step to drag that step.
@available(iOS 26, macOS 26, *)
private struct ChainCard: View {
    let chain: Chain
    let drag: ImportDrag
    let entering: Bool
    let delay: Double
    let timeOf: (ChainStep) -> String
    let onRename: () -> Void
    let onDelete: () -> Void
    let onJump: (ChainStep) -> Void
    /// The VoiceOver path: nil step = the whole chain.
    let onPick: (ChainStep?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// nil = was already there; false → true = sliding in.
    @State private var entered: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button(action: onRename) {
                    Text(chain.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: Metrics.hit, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名：\(chain.name)")
                .accessibilityIdentifier("chain.\(chain.name)")
                .accessibilityAction(named: "加入到项目") { onPick(nil) }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: Metrics.hit, height: Metrics.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除：\(chain.name)")
            }
            .padding(.leading, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .liftable(drag, chain: chain, step: nil)

            ForEach(Array(chain.steps.enumerated()), id: \.element.id) { i, s in
                StepRow(number: i + 1, step: s, time: timeOf(s), onJump: { onJump(s) }, onPick: { onPick(s) })
                    .opacity(drag.isDragging(step: s.id) ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.2), value: drag.isDragging(step: s.id))
                    .liftable(drag, chain: chain, step: s)
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1.5))
        .opacity(drag.isDragging(chain: chain.id) ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.24), value: drag.isDragging(chain: chain.id))
        // After an extract the cards slide in from the right, 60 ms apart (prototype `inRA`).
        .opacity(entered == false ? 0 : 1)
        .offset(x: entered == false && !reduce ? 28 : 0)
        .onAppear {
            guard entering, entered == nil else { return }
            entered = false
            withAnimation(.easeOut(duration: 0.32).delay(delay)) { entered = true }
        }
    }
}

@available(iOS 26, macOS 26, *)
private struct StepRow: View {
    let number: Int
    let step: ChainStep
    let time: String
    let onJump: () -> Void
    let onPick: () -> Void

    private var place: String { step.place ?? "" }

    var body: some View {
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(number).").fontWeight(.medium).foregroundStyle(Palette.muted)
                    Text(step.name).foregroundStyle(Palette.text)
                }
                .font(.system(size: 15, weight: .semibold))
                if !place.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 10, weight: .semibold))
                        Text(place).lineLimit(1)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onJump) {
                Text(time)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.soft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8)
                    .frame(minHeight: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.isEmpty ? "\(number). \(step.name)" : "\(number). \(step.name)，\(place)")
        .accessibilityValue(time)
        .accessibilityIdentifier("step.\(step.name)")
        .accessibilityAction(named: "播放：\(time)", onJump)
        .accessibilityAction(named: "加入到项目", onPick)
    }
}

/// ✓ step → where it went.
@available(iOS 26, macOS 26, *)
private struct ImportedRow: View {
    let name: String
    let target: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(target.map { "→ \($0)" } ?? "")
                .fontWeight(.semibold)
                .lineLimit(1)
                .animation(Motion.fade, value: target)
        }
        .font(.system(size: 14))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.hit)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("imported.\(name)")
    }
}

// MARK: - Player

/// Plays the recording from a transcript time. The clock runs on its own so the outlined line follows along
/// across segments (each segment is its own file); the audio, where there is one, plays alongside.
@available(iOS 26, macOS 26, *)
@MainActor
@Observable
final class NotePlayer {
    /// Current position in ms; nil = closed.
    private(set) var at: Int?
    private(set) var playing = false
    /// Bumped when a step's time chip asks the transcript to scroll to the line.
    var jumpSeq = 0
    private var duration = 0
    private var startedAt = Date()
    private var startMs = 0
    private var ticker: Task<Void, Never>?
    private var audio: AVPlayer?
    private var segmentEnd: NSObjectProtocol?
    private weak var detail: NoteDetailModel?

    func play(from ms: Int, duration: Int, detail: NoteDetailModel) {
        self.detail = detail
        self.duration = duration
        startMs = max(0, min(ms, duration))
        startedAt = Date()
        at = startMs
        playing = true
        tick()
        loadAudio(at: startMs)
    }

    func toggle() {
        guard let at, let detail else { return }
        if playing {
            playing = false
            ticker?.cancel()
            audio?.pause()
        } else {
            play(from: at >= duration ? 0 : at, duration: duration, detail: detail)
        }
    }

    func close() {
        ticker?.cancel()
        audio?.pause()
        audio = nil
        playing = false
        at = nil
    }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.playing else { return }
                let now = self.startMs + Int(Date().timeIntervalSince(self.startedAt) * 1000)
                if now >= self.duration {
                    self.at = self.duration
                    self.playing = false
                    self.audio?.pause()
                    return
                }
                self.at = now
            }
        }
    }

    private func loadAudio(at ms: Int) {
        audio?.pause()
        Task { [weak self] in
            guard let self, let detail = self.detail, let (url, offset) = await detail.audioURL(at: ms), self.playing else {
                return
            }
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            await p.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
            guard self.playing else { return }
            self.audio = p
            p.play()
            if let segmentEnd = self.segmentEnd { NotificationCenter.default.removeObserver(segmentEnd) }
            self.segmentEnd = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The next segment carries on from the clock.
                    guard let self, self.playing, let at = self.at, at < self.duration else { return }
                    self.loadAudio(at: at + 50)
                }
            }
        }
    }
}

@available(iOS 26, macOS 26, *)
private struct PlayerBar: View {
    let player: NotePlayer
    let duration: Int
    let detail: NoteDetailModel

    var body: some View {
        let at = player.at ?? 0
        HStack(spacing: 10) {
            Button(action: player.toggle) {
                ZStack {
                    Image(systemName: "pause.fill").opacity(player.playing ? 1 : 0)
                    Image(systemName: "play.fill").opacity(player.playing ? 0 : 1)
                }
                .font(.system(size: 16))
                .foregroundStyle(Palette.onFill)
                .frame(width: Metrics.hit, height: Metrics.hit)
                .background(Palette.fill, in: Circle())
                .animation(.easeInOut(duration: 0.16), value: player.playing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playing ? "暂停" : "播放")
            GeometryReader { g in
                Capsule().fill(Palette.line)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.accent)
                            .frame(width: duration > 0 ? g.size.width * min(1, CGFloat(at) / CGFloat(duration)) : 0)
                            .animation(.linear(duration: 0.25), value: at)
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text("\(NoteLanguage.clock(at)) / \(NoteLanguage.clock(duration))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: at / 1000)
            Button(action: player.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: Metrics.hit, height: Metrics.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 60)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 8)
    }
}

/// Failure toast for the note detail (same look as the notes toast).
@available(iOS 26, macOS 26, *)
private struct DetailToast: View {
    @Bindable var detail: NoteDetailModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Group {
            if let text = detail.notice {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.onFill)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Palette.fill, in: Capsule())
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(Motion.fade) { detail.notice = nil }
                    }
            }
        }
        .padding(.top, 8)
        .animation(reduce ? Motion.fade : Motion.sheet, value: detail.notice)
    }
}
