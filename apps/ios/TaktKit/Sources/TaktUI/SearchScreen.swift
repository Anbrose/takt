import SwiftUI

/// 查找 (prototype `searchVals`): the field (focused on arrival, × clears), then Project / 任务 / 笔记 groups with
/// the match highlighted. A hit opens its Project, its task's level or its note; going back returns here.
struct SearchScreen: View {
    @Bindable var model: SearchModel
    let onBack: () -> Void
    let onOpen: (SearchHit.Target) -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var none: Bool {
        model.answered && model.groups.isEmpty && !model.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.groups) { g in
                        section(g)
                            .transition(reduce ? .opacity : .offset(x: 28).combined(with: .opacity))
                    }
                }
                .padding(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 32, trailing: Metrics.gutter))
                .animation(.easeOut(duration: 0.22), value: model.groups.map(\.kind))
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                Text(none ? "无结果" : "")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 120)
                    .opacity(none ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: none)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!none)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .task {
            // Focused once the push has settled, so the keyboard doesn't ride in with the screen.
            try? await Task.sleep(for: .milliseconds(440))
            focused = true
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            BackButton {
                focused = false
                onBack()
            }
            ZStack(alignment: .leading) {
                TextField("", text: $model.query)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityLabel("查找")
                    .accessibilityIdentifier("search.field")
                    .padding(.leading, 38)
                    .padding(.trailing, 40)
                    .frame(height: Metrics.hit)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1))
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .trailing) { clearButton }
        }
        .padding(EdgeInsets(top: 20, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
        .frame(minHeight: 76)
    }

    private var clearButton: some View {
        let on = !model.query.isEmpty
        return Button {
            model.query = ""
            focused = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 40, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(on ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: on)
        .disabled(!on)
        .accessibilityHidden(!on)
        .accessibilityLabel("清除")
    }

    private func section(_ g: SearchGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(g.hits) { h in
                SearchHitRow(hit: h) {
                    focused = false
                    onOpen(h.target)
                }
            }
        }
    }

    @ViewBuilder private var toast: some View {
        ZStack {
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
            }
        }
        .padding(.top, 8)
        .motion(Motion.sheet, value: model.notice, reduce: reduce)
    }
}

/// One hit: the text with the match marked, the path / note · time under it, a chevron.
struct SearchHitRow: View {
    let hit: SearchHit
    let action: () -> Void

    /// Transcript lines are clipped around the match (prototype `clip`: 8 characters before, 22 after).
    private var parts: (pre: String, hit: String, post: String) {
        guard case .note(_, .some, _) = hit.target else { return (hit.pre, hit.hit, hit.post) }
        let pre = hit.pre.count > 8 ? "…" + hit.pre.suffix(8) : hit.pre
        let post = hit.post.count > 22 ? hit.post.prefix(22) + "…" : hit.post
        return (pre, hit.hit, post)
    }

    private var text: AttributedString {
        let p = parts
        var marked = AttributedString(p.hit)
        marked.backgroundColor = Palette.soft
        marked.foregroundColor = Palette.accentText
        return AttributedString(p.pre) + marked + AttributedString(p.post)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                    if !hit.sub.isEmpty {
                        Text(hit.sub)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
            .frame(minHeight: 56)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hit.sub.isEmpty ? hit.text : "\(hit.text)，\(hit.sub)")
        .accessibilityIdentifier("search.hit.\(hit.text)")
    }
}
