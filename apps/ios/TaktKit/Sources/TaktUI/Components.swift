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

/// Bordered pill with icon + short label ("地图").
struct ToolButton: View {
    let icon: String
    let title: String
    var pressed = false
    /// Stretch to the full width, content centred.
    var wide = false
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
            .frame(maxWidth: wide ? .infinity : nil, minHeight: Metrics.hit)
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

/// 深浅色切换 (header, top right).
struct ThemeToggle: View {
    @Binding var theme: ThemeChoice
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
}

/// 44×26 switch (prototype `switchVals`): fill track and the knob slides 20 pt when on.
struct SwitchTrack: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Capsule()
            .fill(on ? Palette.fill : Palette.line)
            .frame(width: 44, height: 26)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: 22, height: 22)
                    .padding(.leading, 2)
                    .offset(x: on ? 18 : 0)
            }
            .animation(reduce ? Motion.fade : Motion.toggle, value: on)
            .accessibilityHidden(true)
    }
}

/// Indeterminate ring (prototype `spin`, 900 ms a turn): a quarter arc over a faint track.
struct Spinner: View {
    var size: CGFloat = 28
    var radius: CGFloat = 9
    var lineWidth: CGFloat = 2.5
    var track: Color = Palette.line
    var arc: Color = Palette.accent

    var body: some View {
        TimelineView(.animation) { t in
            let turn = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(track, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(arc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90 + turn * 360))
            }
            .frame(width: radius * 2, height: radius * 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 返回 chevron, 44 pt, pulled 8 pt into the gutter (screen headers).
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: Metrics.hit, height: Metrics.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
        .padding(.leading, -8)
    }
}
