import SwiftUI

/// First 录音: 录音 → 任务 illustration, 「录完自动整理成任务」, the 自动生成任务 switch and 「开始录音」.
/// Closing by the backdrop doesn't count as seen.
@available(iOS 26, macOS 26, *)
struct RecordIntroSheet: View {
    @Binding var isPresented: Bool
    /// The switch's starting position (the current 自动生成任务 setting).
    let autoExtract: Bool
    let onStart: (_ autoExtract: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var auto = true

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
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
        .motion(Motion.introSheet, value: isPresented, reduce: reduce)
        .onChange(of: isPresented, initial: true) { _, open in
            if open { auto = autoExtract }
        }
    }

    private var sheet: some View {
        VStack(spacing: 18) {
            FlowIllustration(on: auto)
            Text("录完自动整理成任务")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button { auto.toggle() } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动生成任务")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        Text("之后可在「笔记」里关闭")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SwitchTrack(on: auto)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(minHeight: 56)
                .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("自动生成任务")
            .accessibilityHint("之后可在「笔记」里关闭")
            .accessibilityValue(auto ? "1" : "0")
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityIdentifier("intro.auto")

            Button { onStart(auto) } label: {
                HStack(spacing: 8) {
                    Circle().fill(Palette.onFill).frame(width: 10, height: 10)
                    Text("开始录音").font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(Palette.onFill)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intro.start")
        }
        .padding(EdgeInsets(top: 28, leading: Metrics.gutter, bottom: 32, trailing: Metrics.gutter))
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func close() {
        Motion.with(Motion.introSheet, reduce: reduce) { isPresented = false }
    }
}

/// 录音 tile → dashed line with two dots travelling along it → 任务 tile. Dims when the switch is off.
@available(iOS 26, macOS 26, *)
private struct FlowIllustration: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 56, y: 32))
                p.addLine(to: CGPoint(x: 176, y: 32))
            }
            .stroke(Palette.line, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

            if !reduce {
                TimelineView(.animation) { t in
                    let now = t.date.timeIntervalSinceReferenceDate
                    ZStack(alignment: .topLeading) {
                        dot(Self.phase(now))
                        dot(Self.phase(now - 0.9))
                    }
                    .frame(width: 232, height: 64, alignment: .topLeading)
                }
            }

            HStack {
                tile(icon: "mic", bg: Palette.soft, fg: Palette.accentText)
                Spacer()
                tile(icon: "checklist", bg: Palette.fill, fg: Palette.onFill)
            }
        }
        .frame(width: 232, height: 64)
        .opacity(on ? 1 : 0.25)
        .animation(.easeInOut(duration: 0.26), value: on)
        .accessibilityHidden(true)
    }

    /// Prototype `flow` keyframes: 1.8 s ease-in-out, 0 → 122 pt, fading in over the first and out over the last 20%.
    private static func phase(_ t: Double) -> (x: Double, o: Double) {
        let p = (t.truncatingRemainder(dividingBy: 1.8) + 1.8).truncatingRemainder(dividingBy: 1.8) / 1.8
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        let o = p < 0.2 ? p / 0.2 : (p > 0.8 ? (1 - p) / 0.2 : 1)
        return (eased * 122, o)
    }

    private func dot(_ v: (x: Double, o: Double)) -> some View {
        Circle()
            .fill(Palette.accent)
            .frame(width: 10, height: 10)
            .offset(x: 50 + v.x, y: 27)
            .opacity(v.o)
    }

    private func tile(icon: String, bg: Color, fg: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 56, height: 56)
            .background(bg, in: RoundedRectangle(cornerRadius: 18))
    }
}
