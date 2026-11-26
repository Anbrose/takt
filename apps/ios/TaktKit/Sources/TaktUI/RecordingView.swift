import SwiftUI

/// While recording: language chip (top right), the elapsed time, level bars and 停止. Nothing else.
@available(iOS 26, macOS 26, *)
struct RecordingView: View {
    @Bindable var notes: NotesModel
    let startedAt: Date
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                chip
            }
            .frame(minHeight: Metrics.hit)

            VStack(spacing: 28) {
                TimelineView(.periodic(from: startedAt, by: 1)) { t in
                    let text = NoteLanguage.clock(Int(t.date.timeIntervalSince(startedAt) * 1000))
                    Text(text)
                        .font(.system(size: 60, weight: .bold))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                        .contentTransition(.numericText())
                        .animation(reduce ? nil : Motion.fade, value: text)
                        .accessibilityLabel(text)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                LevelBars()
            }
            .frame(maxHeight: .infinity)

            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.stop)
                    .frame(width: 30, height: 30)
                    .frame(width: 80, height: 80)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 4))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
            .accessibilityIdentifier("recording.stop")
        }
        .padding(EdgeInsets(top: 8, leading: Metrics.gutter, bottom: 40, trailing: Metrics.gutter))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg.ignoresSafeArea())
        .overlay {
            LanguageSheet(isPresented: $picking, current: notes.locale, installed: notes.installed) { id in
                Task { await notes.chooseLocale(id) }
            }
        }
        .task { await notes.checkInstalled(NoteLanguage.all.map(\.id)) }
    }

    private var downloading: Bool { notes.preparing.contains(notes.locale) }

    private var chip: some View {
        Button { Motion.with(Motion.langSheet, reduce: reduce) { picking = true } } label: {
            HStack(spacing: 6) {
                Text(NoteLanguage.short(notes.locale))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .contentTransition(.opacity)
                ZStack {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .opacity(downloading ? 0 : 1)
                    Spinner(size: 16, radius: 6, lineWidth: 2)
                        .opacity(downloading ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .animation(.easeInOut(duration: 0.2), value: downloading)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minWidth: 64, minHeight: Metrics.hit)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.fade, value: notes.locale)
        .accessibilityLabel("识别语言：\(NoteLanguage.entry(notes.locale)?.name ?? notes.locale)")
        .accessibilityValue(NoteLanguage.short(notes.locale))
        .accessibilityIdentifier("recording.locale")
    }
}

/// Twelve bars breathing at slightly different rates (prototype `lvl`). Still under 减少动态效果.
@available(iOS 26, macOS 26, *)
private struct LevelBars: View {
    private static let heights: [CGFloat] = [18, 34, 52, 28, 44, 56, 38, 22, 48, 30, 42, 20]
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TimelineView(.animation(paused: reduce)) { t in
            let now = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(Self.heights.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: 4, height: Self.heights[i])
                        .scaleEffect(y: reduce ? 1 : Self.scale(i, now))
                }
            }
            .frame(height: 56)
        }
        .accessibilityHidden(true)
    }

    /// scaleY 0.15 ↔ 1, ease-in-out, alternating; duration 420 + (i·137 mod 380) ms, offset by i·173 mod 600 ms.
    private static func scale(_ i: Int, _ now: Double) -> CGFloat {
        let d = Double(420 + (i * 137) % 380) / 1000
        let delay = Double((i * 173) % 600) / 1000
        let cycles = (now + delay) / d
        var p = cycles.truncatingRemainder(dividingBy: 2)
        if p > 1 { p = 2 - p }
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        return 0.15 + 0.85 * eased
    }
}

/// 识别语言: a 3-column grid of the languages; a mark on the ones that still need downloading.
@available(iOS 26, macOS 26, *)
private struct LanguageSheet: View {
    @Binding var isPresented: Bool
    let current: String
    let installed: Set<String>
    let onPick: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityLabel("关闭")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                grid
                    .transition(reduce ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .motion(Motion.langSheet, value: isPresented, reduce: reduce)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(NoteLanguage.all) { l in
                let on = NoteLanguage.normalized(current) == l.id
                Button {
                    onPick(l.id)
                    close()
                } label: {
                    Text(l.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(on ? Palette.soft : Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.controlRadius)
                                .strokeBorder(on ? Palette.accent : Palette.line, lineWidth: 1.5))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .padding(7)
                                .opacity(installed.contains(l.id) ? 0 : 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: on)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("locale.\(l.id)")
            }
        }
        .padding(EdgeInsets(top: 20, leading: Metrics.gutter, bottom: 32, trailing: Metrics.gutter))
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("识别语言")
        .accessibilityAddTraits(.isModal)
    }

    private func close() {
        Motion.with(Motion.langSheet, reduce: reduce) { isPresented = false }
    }
}
