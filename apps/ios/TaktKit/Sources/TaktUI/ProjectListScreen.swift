import SwiftUI
import TaktAPI

/// Project 列表: name-only cards, newest first. Tap opens, long-press → 重命名 / 删除, ＋ creates.
/// Every change animates (design/guidelines.md 动效): cards open / collapse in place, the empty
/// state cross-fades with the ＋ button.
struct ProjectListScreen: View {
    @Bindable var app: AppModel
    @Binding var theme: ThemeChoice
    @Environment(\.accessibilityReduceMotion) private var reduce

    private enum Sheet: Equatable {
        case new
        case rename(Project)
    }

    @State private var sheet: Sheet?
    /// The last sheet shown, so its labels stay put while it slides away.
    @State private var shown: Sheet = .new
    @State private var deleting: Project?

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
        .overlay(alignment: .bottomTrailing) {
            if !app.projects.isEmpty {
                FloatingAddButton { show(.new) }
                    .padding(.trailing, Metrics.gutter)
                    .padding(.bottom, 16)
                    .transition(reduce ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
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
