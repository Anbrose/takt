import SwiftUI
import TaktAPI

/// Project 列表: name-only cards, newest first. Tap opens, long-press → 重命名 / 删除. The ＋ button opens
/// the menu: 查找 / 笔记 / 录音 / 新建 Project (笔记 and 录音 only where notes are available).
/// Every change animates (design/guidelines.md 动效): cards open / collapse in place, the empty
/// state cross-fades, menu items spring out one after another.
struct ProjectListScreen: View {
    @Bindable var app: AppModel
    @Binding var theme: ThemeChoice
    var onSearch: () -> Void = {}
    /// nil hides 笔记 / 录音 (before iOS 26).
    var onNotes: (() -> Void)?
    var onRecord: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduce

    private enum Sheet: Equatable {
        case new
        case rename(Project)
    }

    @State private var sheet: Sheet?
    /// The last sheet shown, so its labels stay put while it slides away.
    @State private var shown: Sheet = .new
    @State private var deleting: Project?
    @State private var dialOpen = false

    private var listAnimation: Animation { reduce ? Motion.fade : Motion.collapse }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                list
                emptyState
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .overlay { scrim }
        .overlay(alignment: .bottomTrailing) { dial }
        .overlay(alignment: .top) { AppToast(app: app) }
        .overlay { nameSheet }
        .alert(
            deleting.map { "删除「\($0.name)」？" } ?? "",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            presenting: deleting
        ) { p in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await app.deleteProject(p.id, animation: listAnimation) }
            }
        }
        .animation(reduce ? Motion.fade : Motion.sheet, value: app.projects.isEmpty)
    }

    // MARK: 悬浮按钮 menu

    private enum DialItem: Int, CaseIterable {
        case search, notes, record, new

        var title: String {
            switch self {
            case .search: "查找"
            case .notes: "笔记"
            case .record: "录音"
            case .new: "新建 Project"
            }
        }

        var icon: String {
            switch self {
            case .search: "magnifyingglass"
            case .notes: "doc.text"
            case .record: "mic"
            case .new: "folder.badge.plus"
            }
        }

        var id: String {
            switch self {
            case .search: "menu.search"
            case .notes: "menu.notes"
            case .record: "menu.record"
            case .new: "menu.new"
            }
        }
    }

    private var dialItems: [DialItem] {
        DialItem.allCases.filter { item in
            switch item {
            case .notes: onNotes != nil
            case .record: onRecord != nil
            default: true
            }
        }
    }

    private var scrim: some View {
        ZStack {
            if dialOpen {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { setDial(false) }
                    .accessibilityHidden(true)
                    .transition(.opacity.animation(.easeInOut(duration: 0.26)))
            }
        }
    }

    private var dial: some View {
        let items = dialItems
        return VStack(alignment: .trailing, spacing: 14) {
            VStack(alignment: .trailing, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element) { i, item in
                    if dialOpen {
                        dialButton(item)
                            // k counts from the bottom: the item next to ＋ comes out first.
                            .transition(dialTransition(k: items.count - 1 - i))
                    }
                }
            }
            .padding(.trailing, 2)

            Button { setDial(!dialOpen) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.onFill)
                    .rotationEffect(.degrees(dialOpen ? 45 : 0))
                    .frame(width: 56, height: 56)
                    .background(Palette.fill, in: Circle())
                    .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dialOpen ? "关闭" : "菜单")
            .accessibilityValue(dialOpen ? "1" : "0")
            .accessibilityIdentifier("fab.menu")
        }
        .padding(.trailing, Metrics.gutter)
        .padding(.bottom, 16)
    }

    private func dialButton(_ item: DialItem) -> some View {
        Button { pick(item) } label: {
            HStack(spacing: 12) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 4)
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 52, height: 52)
                    .background(Palette.surface, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(item.id)
    }

    /// Prototype: closed = 14 + k·10 pt lower, scale 0.86, transparent; opening is staggered 40 ms per step.
    private func dialTransition(k: Int) -> AnyTransition {
        if reduce { return .opacity.animation(Motion.fade) }
        let delay = Double(k) * 0.04
        let spring = AnyTransition.modifier(
            active: DialOffset(y: CGFloat(14 + k * 10), scale: 0.86), identity: DialOffset(y: 0, scale: 1))
        return .asymmetric(
            insertion: spring.animation(Motion.dial.delay(delay))
                .combined(with: .opacity.animation(.easeInOut(duration: 0.2).delay(delay))),
            removal: spring.animation(Motion.dial).combined(with: .opacity.animation(.easeInOut(duration: 0.2))))
    }

    private func setDial(_ open: Bool) {
        Motion.with(Motion.dial, reduce: reduce) { dialOpen = open }
    }

    private func pick(_ item: DialItem) {
        setDial(false)
        switch item {
        case .search: onSearch()
        case .notes: onNotes?()
        case .record: onRecord?()
        case .new: show(.new)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Project")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            ThemeToggle(theme: $theme)
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
        .frame(minHeight: 76)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(app.projects, id: \.id) { p in
                    card(p)
                        .transition(
                            reduce
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                                    removal: .scale(scale: 0.94).combined(with: .opacity)
                                )
                        )
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 96)
        }
    }

    private func card(_ p: Project) -> some View {
        Button {
            app.openProject(p, animation: reduce ? Motion.fade : Motion.push)
        } label: {
            HStack(spacing: 8) {
                Text(p.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 56)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名", systemImage: "pencil") { show(.rename(p)) }
            Button("删除", systemImage: "trash", role: .destructive) { deleting = p }
        }
        .accessibilityIdentifier("project.\(p.name)")
    }

    private var emptyState: some View {
        Group {
            if app.projects.isEmpty {
                Button { show(.new) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                        Text("新建").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Palette.onFill)
                    .padding(.leading, 18)
                    .padding(.trailing, 22)
                    .frame(minHeight: 48)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 76)
                .transition(reduce ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }

    private var nameSheet: some View {
        ProjectNameSheet(
            isPresented: Binding { sheet != nil } set: { if !$0 { sheet = nil } },
            title: { if case .rename = shown { "重命名" } else { "新建 Project" } }(),
            action: { if case .rename = shown { "保存" } else { "创建" } }(),
            initial: { if case .rename(let p) = shown { p.name } else { "" } }(),
            onSubmit: submit
        )
    }

    private func show(_ s: Sheet) {
        shown = s
        Motion.with(Motion.sheet, reduce: reduce) { sheet = s }
    }

    /// Returns true when the sheet may close.
    private func submit(_ name: String) async -> Bool {
        switch shown {
        case .rename(let p):
            return await app.renameProject(p.id, to: name, animation: Motion.fade)
        case .new:
            guard let p = await app.createProject(name: name, animation: listAnimation) else { return false }
            // Let the sheet slide away and the new card open, then push into it.
            Task {
                try? await Task.sleep(for: .milliseconds(reduce ? 200 : 520))
                app.openProject(p, animation: reduce ? Motion.fade : Motion.push)
            }
            return true
        }
    }
}

/// One-field sheet for 新建 Project / 重命名 (same look as 新建任务).
struct ProjectNameSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let action: String
    let initial: String
    let onSubmit: (String) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var name = ""
    @State private var submitting = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityLabel("关闭")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                form
                    .transition(reduce ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .motion(Motion.sheet, value: isPresented, reduce: reduce)
        .onChange(of: isPresented) { _, open in
            if open {
                name = initial
                Task {
                    try? await Task.sleep(for: .milliseconds(reduce ? 0 : 320))
                    focused = true
                }
            } else {
                focused = false
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.text)
            LabeledField(label: "名称", text: $name)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(submit)
            HStack(spacing: 10) {
                WideButton(title: "取消", kind: .secondary, height: 48, action: close)
                WideButton(title: action, kind: .primary, height: 48, busy: submitting, action: submit)
                    .disabled(submitting || trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.45 : 1)
                    .animation(Motion.fade, value: trimmed.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func submit() {
        guard !submitting, !trimmed.isEmpty else { return }
        submitting = true
        Task {
            let ok = await onSubmit(trimmed)
            submitting = false
            if ok { close() }
        }
    }

    private func close() {
        Motion.with(Motion.sheet, reduce: reduce) { isPresented = false }
    }
}

/// Failure toast for project changes (same look as the level toast).
struct AppToast: View {
    @Bindable var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Group {
            if let text = app.notice {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.onFill)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Palette.fill, in: Capsule())
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(Motion.fade) { app.notice = nil }
                    }
            }
        }
        .padding(.top, 8)
        .animation(reduce ? Motion.fade : Motion.sheet, value: app.notice)
    }
}

private struct DialOffset: ViewModifier {
    let y: CGFloat
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.scaleEffect(scale, anchor: .trailing).offset(y: y)
    }
}
