import SwiftUI
import TaktAPI

/// 「加入到项目」 without dragging (the VoiceOver path, from a chain's or step's accessibility action): pick a
/// Project, then 「放这里」 (the end of its first level) or a task to put it into (asks 「放入「X」？」 first).
/// The same destinations as a drop; the result shows in the dock as 「✓ 名」.
@available(iOS 26, macOS 26, *)
struct ImportPicker: View {
    /// The chain (and step) being placed; nil = closed.
    @Binding var item: Item?
    let drag: ImportDrag
    @Environment(\.accessibilityReduceMotion) private var reduce

    struct Item: Equatable {
        let chain: String
        let step: String?
        let name: String
    }

    private var dock: ImportDockModel { drag.dock }

    var body: some View {
        ZStack(alignment: .bottom) {
            if item != nil {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityLabel("关闭")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                sheet
                    .transition(reduce ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .motion(Motion.sheet, value: item, reduce: reduce)
        .onChange(of: item) { _, now in
            guard now != nil else { return }
            dock.back()
            Task { await dock.load() }
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                if dock.opened != nil {
                    Button { Motion.with(Motion.nav, reduce: reduce) { dock.back() } } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .frame(width: Metrics.hit, height: Metrics.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    .padding(.leading, -8)
                    .transition(.opacity)
                }
                Text(dock.opened?.project.name ?? "加入到项目")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, minHeight: Metrics.hit, alignment: .leading)
            }
            if let item { Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted).lineLimit(1) }
            ScrollView {
                VStack(spacing: 8) {
                    if let opened = dock.opened {
                        Button { place(.end(parent: opened.level.task.id), into: nil) } label: {
                            row(name: "放这里", count: nil, icon: "arrow.down.to.line", strong: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("picker.here")
                        ForEach(opened.level.children, id: \.id) { t in
                            Button { place(.into(task: t.id), into: t.name) } label: {
                                row(name: t.name, count: t.childCount, icon: "plus", strong: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("放入「\(t.name)」")
                            .accessibilityIdentifier("picker.task.\(t.name)")
                        }
                    } else {
                        ForEach(dock.projects, id: \.id) { p in
                            Button { Task { await open(p.id) } } label: {
                                row(name: p.name, count: dock.counts[p.id], icon: "chevron.right", strong: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("picker.project.\(p.name)")
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            WideButton(title: "取消", kind: .secondary, height: 48, action: close)
        }
        .padding(20)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func row(name: String, count: Int?, icon: String, strong: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 16, weight: strong ? .bold : .semibold))
                .foregroundStyle(strong ? Palette.accentText : Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count, count > 0 {
                Text("\(count) 项").font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(strong ? Palette.accentText : Palette.muted)
                .accessibilityHidden(true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(strong ? Palette.soft : Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(strong ? Palette.accent : Palette.line, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private func open(_ id: String) async {
        await dock.open(id)
        // Let VoiceOver know the list changed under it.
        AccessibilityNotification.ScreenChanged().post()
    }

    private func place(_ destination: DropDestination, into name: String?) {
        guard let item else { return }
        close()
        drag.pick(chain: item.chain, step: item.step, to: destination, intoName: name)
    }

    private func close() {
        Motion.with(Motion.sheet, reduce: reduce) { item = nil }
    }
}
