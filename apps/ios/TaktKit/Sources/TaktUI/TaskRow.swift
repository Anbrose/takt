import SwiftUI
import TaktAPI

/// One task card: check box · number + name · place · prerequisite tags · "N 项 ›" · drag handle.
struct TaskRow: View {
    let task: TaskSummary
    let number: Int
    let selected: Bool
    let dragging: Bool
    /// 地图 mode: the card compresses in place to check box · number · name · leg · handle.
    var compact = false
    /// "起点" / "+2.4 km" / "未定位" — shown only when compact.
    var leg = ""
    /// 左滑: the red 删除 button is showing over the handle.
    var revealed = false
    let onToggle: () -> Void
    let onOpen: () -> Void
    /// Horizontal swipe on the card: left (true) shows 删除, right (false) hides it.
    var onSwipe: (_ open: Bool) -> Void = { _ in }
    var onDelete: () -> Void = {}
    /// Drag handle callbacks; `offset` is the finger's vertical travel since touch-down.
    let onDragChanged: (_ offset: CGFloat) -> Void
    let onDragEnded: () -> Void
    let onMove: (_ delta: Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            CheckBox(on: selected, label: task.name, action: onToggle)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(number).").foregroundStyle(Palette.muted).fontWeight(.medium)
                    Text(task.name).frame(maxWidth: .infinity, alignment: .leading)
                    Text(leg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(compact ? 1 : 0)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(minHeight: 24)

                if !compact {
                    details.transition(.opacity)
                }
            }
            .padding(.vertical, 10)

            DragHandle(
                label: task.name,
                onChanged: onDragChanged,
                onEnded: onDragEnded,
                onMove: onMove
            )
        }
        .padding(EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 4))
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(alignment: .trailing) { deleteButton }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(selected ? Palette.accent : Palette.line, lineWidth: 1.5)
        )
        // Simultaneous, so vertical scrolling and the handle's own drag keep working;
        // only a clearly horizontal swipe counts.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard !dragging, abs(dx) > 40, abs(dx) > abs(dy) * 1.5 else { return }
                    onSwipe(dx < 0)
                }
        )
        .shadow(color: .black.opacity(dragging ? 0.22 : 0), radius: dragging ? 12 : 0, y: dragging ? 10 : 0)
        .opacity(compact && leg == "未定位" ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row.\(task.name)")
        .accessibilityAction(named: "删除") { onDelete() }
    }

    /// Slides in from the right edge and covers the drag handle. Hidden = not in the hierarchy at
    /// all (as with the sheets), so VoiceOver and UI tests never find it; VoiceOver users get the
    /// row's 删除 action instead.
    @ViewBuilder private var deleteButton: some View {
        if revealed {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64)
                    .frame(maxHeight: .infinity)
                    .background(Palette.danger)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除：\(task.name)")
            .transition(.move(edge: .trailing))
        }
    }

    /// 地点 · 前置条件 · "N 项 ›" — folded away in 地图 mode.
    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
                if !task.place.isEmpty {
                    Label {
                        Text(task.place)
                    } icon: {
                        Image(systemName: "mappin").font(.system(size: 11))
                    }
                    .labelStyle(.tight)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                }

                if !task.prerequisites.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(task.prerequisites, id: \.id) { PrerequisiteTag(prerequisite: $0) }
                    }
                }

                if task.childCount > 0 {
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text("\(task.childCount) 项")
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                        .frame(minHeight: Metrics.hit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, -6)
                    .padding(.bottom, -10)
                    .accessibilityLabel("进入 \(task.name)，\(task.childCount) 项")
                }
        }
    }
}

/// 三横把手: press and drag to reorder. Also adjustable with VoiceOver and the arrow keys.
struct DragHandle: View {
    let label: String
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: Metrics.hit, height: Metrics.hit)
            .contentShape(Rectangle())
            // minimumDistance 0: the handle owns its touches (touch-action: none), the rest of the
            // card still scrolls the list.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { onChanged($0.translation.height) }
                    .onEnded { _ in onEnded() }
            )
            .focusable()
            .onKeyPress(.upArrow) { onMove(-1); return .handled }
            .onKeyPress(.downArrow) { onMove(1); return .handled }
            .accessibilityElement()
            .accessibilityLabel("拖动调整顺序：\(label)")
            .accessibilityIdentifier("handle.\(label)")
            .accessibilityHint("上下轻扫调整位置")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: onMove(1)
                case .decrement: onMove(-1)
                @unknown default: break
                }
            }
    }
}

/// Icon hugging its label (Label's default spacing is too loose for 13pt meta lines).
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == TightLabelStyle {
    static var tight: TightLabelStyle { TightLabelStyle() }
}

/// Wrapping row of tags (CSS flex-wrap).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if !cur.items.isEmpty, cur.width + spacing + size.width > width {
                rows.append(cur)
                cur = Row(y: cur.y + cur.height + spacing)
            }
            cur.width += (cur.items.isEmpty ? 0 : spacing) + size.width
            cur.height = max(cur.height, size.height)
            cur.items.append(i)
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
