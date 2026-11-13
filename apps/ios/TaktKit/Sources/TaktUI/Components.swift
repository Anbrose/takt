import SwiftUI
import TaktAPI

/// 尽早订 / 行前订 / 现场办 tag colours (prototype `tagStyle`).
struct UrgencyStyle {
    let label: String
    let bg: Color
    let fg: Color
    let border: Color

    init(_ u: Urgency) {
        switch u {
        case .early: (label, bg, fg, border) = ("尽早订", Palette.fill, Palette.onFill, Palette.fill)
        case .before: (label, bg, fg, border) = ("行前订", Palette.soft, Palette.accentText, Palette.accent)
        case .onsite: (label, bg, fg, border) = ("现场办", .clear, Palette.muted, Palette.line)
        }
    }
}

/// A prerequisite shown as a small tag on a task row.
struct PrerequisiteTag: View {
    let prerequisite: Prerequisite

    var body: some View {
        let s = UrgencyStyle(prerequisite.urgency)
        Text(prerequisite.action)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(s.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(s.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(s.border, lineWidth: 1))
            .accessibilityLabel("\(prerequisite.action)，\(s.label)")
    }
}

/// 22pt square check box inside a 44pt hit area.
struct CheckBox: View {
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(on ? Palette.fill : .clear)
                .strokeBorder(on ? Palette.fill : Palette.muted, lineWidth: 1.5)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.onFill)
                        .opacity(on ? 1 : 0)
                }
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((on ? "取消勾选：" : "勾选：") + label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Bordered pill with icon + short label ("新建", "地图").
struct ToolButton: View {
    let icon: String
    let title: String
    var pressed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Palette.accentText)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(minHeight: Metrics.hit)
            .background(pressed ? Palette.soft : Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.controlRadius)
                    .strokeBorder(pressed ? Palette.accent : Palette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Primary (filled) / secondary (outlined) wide button used in the bottom bar and the form.
struct WideButton: View {
    enum Kind { case primary, secondary }
    let title: String
    let kind: Kind
    var height: CGFloat = Metrics.hit
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(Palette.onFill) }
            }
            .font(.system(size: 15, weight: kind == .primary ? .bold : .semibold))
            .foregroundStyle(kind == .primary ? Palette.onFill : Palette.text)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(kind == .primary ? Palette.fill : Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Field with a small label above it (新建任务 form).
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            InputField(text: $text, placeholder: placeholder)
        }
    }
}

struct InputField: View {
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 16))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1))
    }
}
