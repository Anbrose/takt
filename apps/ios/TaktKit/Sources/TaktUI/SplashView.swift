import SwiftUI

/// 开屏: TAKT drawn as a node flow — start node, lines drawn at constant speed, a node pops at every
/// turn or branch, thin connectors between letters, a filled end node; then 标语 and buttons fade in.
/// Geometry and timeline are copied from design/takt-handoff/prototype/Splash.dc.html (viewBox 305×120).
public struct SplashView: View {
    /// Show 重播 / 开始 at the end (first launch). Otherwise the splash dismisses itself.
    let interactive: Bool
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var run = 0
    @State private var playing = false

    public init(interactive: Bool, onFinish: @escaping () -> Void) {
        self.interactive = interactive
        self.onFinish = onFinish
    }

    struct Segment { let from: CGPoint; let to: CGPoint; let connector: Bool; let delay: Double }
    struct Node { let at: CGPoint; let filled: Bool; let delay: Double }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static let segments: [Segment] = [
        .init(from: p(10, 20), to: p(40, 20), connector: false, delay: 0.200),
        .init(from: p(40, 20), to: p(70, 20), connector: false, delay: 0.370),
        .init(from: p(40, 20), to: p(40, 100), connector: false, delay: 0.370),
        .init(from: p(40, 100), to: p(90, 100), connector: true, delay: 0.540),
        .init(from: p(90, 100), to: p(120, 20), connector: false, delay: 0.710),
        .init(from: p(120, 20), to: p(150, 100), connector: false, delay: 0.880),
        .init(from: p(102, 68), to: p(138, 68), connector: false, delay: 1.050),
        .init(from: p(150, 100), to: p(170, 100), connector: true, delay: 1.220),
        .init(from: p(170, 100), to: p(170, 60), connector: false, delay: 1.390),
        .init(from: p(170, 60), to: p(170, 20), connector: false, delay: 1.560),
        .init(from: p(170, 60), to: p(215, 100), connector: false, delay: 1.730),
        .init(from: p(170, 60), to: p(215, 20), connector: false, delay: 1.730),
        .init(from: p(215, 20), to: p(235, 20), connector: true, delay: 1.900),
        .init(from: p(235, 20), to: p(265, 20), connector: false, delay: 2.070),
        .init(from: p(265, 20), to: p(295, 20), connector: false, delay: 2.240),
        .init(from: p(265, 20), to: p(265, 100), connector: false, delay: 2.410),
    ]

    static let nodes: [Node] = [
        .init(at: p(10, 20), filled: true, delay: 0), .init(at: p(40, 20), filled: false, delay: 0.330),
        .init(at: p(70, 20), filled: false, delay: 0.500), .init(at: p(40, 100), filled: false, delay: 0.500),
        .init(at: p(90, 100), filled: false, delay: 0.670), .init(at: p(120, 20), filled: false, delay: 0.840),
        .init(at: p(150, 100), filled: false, delay: 1.010), .init(at: p(170, 100), filled: false, delay: 1.350),
        .init(at: p(170, 60), filled: false, delay: 1.520), .init(at: p(170, 20), filled: false, delay: 1.690),
        .init(at: p(215, 100), filled: false, delay: 1.860), .init(at: p(215, 20), filled: false, delay: 1.860),
        .init(at: p(235, 20), filled: false, delay: 2.030), .init(at: p(265, 20), filled: false, delay: 2.200),
        .init(at: p(295, 20), filled: false, delay: 2.370), .init(at: p(265, 100), filled: true, delay: 2.540),
    ]

    static let segmentDuration = 0.17
    static let taglineDelay = 2.73
    static let buttonsDelay = 3.03
    /// When a non-interactive splash hands over (tagline has landed).
    static let autoFinish = 3.1

    private let width: CGFloat = 270
    private var scale: CGFloat { width / 305 }

    public var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                logo
                Text("规划每一步")
                    .font(.system(size: 16))
                    .tracking(1.28)
                    .foregroundStyle(Palette.muted)
                    .modifier(FadeUp(on: playing, delay: Self.taglineDelay, reduce: reduce))
            }
            .padding(.horizontal, 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("TAKT，规划每一步")

            if interactive {
                VStack {
                    Spacer()
                    buttons.modifier(FadeUp(on: playing, delay: Self.buttonsDelay, reduce: reduce))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !interactive { onFinish() } }
        .task(id: run) {
            playing = false
            // One frame at the start state, then let every element run its own delayed animation.
            try? await Task.sleep(for: .milliseconds(30))
            playing = true
            if !interactive {
                try? await Task.sleep(for: .seconds(reduce ? 0.6 : Self.autoFinish))
                if !Task.isCancelled { onFinish() }
            }
        }
    }

    private var logo: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.segments.enumerated()), id: \.offset) { _, s in
                SegmentShape(from: s.from, to: s.to, scale: scale)
                    .trim(from: 0, to: playing || reduce ? 1 : 0)
                    .stroke(
                        s.connector ? Palette.muted.opacity(0.55) : Palette.text,
                        style: StrokeStyle(lineWidth: (s.connector ? 2 : 7) * scale, lineCap: .round)
                    )
                    .animation(playing && !reduce ? .linear(duration: Self.segmentDuration).delay(s.delay) : nil,
                               value: playing)
            }
            ForEach(Array(Self.nodes.enumerated()), id: \.offset) { _, n in
                let r = (n.filled ? 7 : 5.5) * scale
                Circle()
                    .fill(n.filled ? Palette.accent : Palette.bg)
                    .overlay(Circle().strokeBorder(Palette.accent, lineWidth: 3 * scale))
                    .frame(width: (r + 1.5 * scale) * 2, height: (r + 1.5 * scale) * 2)
                    .scaleEffect(playing || reduce ? 1 : 0.001)
                    .opacity(playing || reduce ? 1 : 0)
                    .position(x: n.at.x * scale, y: n.at.y * scale)
                    .animation(
                        playing && !reduce
                            ? .timingCurve(0.2, 1.5, 0.4, 1, duration: 0.28).delay(n.delay) : nil,
                        value: playing
                    )
            }
        }
        .frame(width: width, height: 120 * scale, alignment: .topLeading)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button { run += 1 } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 48, height: 48)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重播动画")

            Button(action: onFinish) {
                HStack(spacing: 6) {
                    Text("开始").font(.system(size: 16, weight: .bold))
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Palette.onFill)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SegmentShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: from.x * scale, y: from.y * scale))
        p.addLine(to: CGPoint(x: to.x * scale, y: to.y * scale))
        return p
    }
}

/// opacity 0 → 1 and 10pt rise, 520 ms ease, after `delay` (prototype `.fade`).
private struct FadeUp: ViewModifier {
    let on: Bool
    let delay: Double
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .opacity(on || reduce ? 1 : 0)
            .offset(y: on || reduce ? 0 : 10)
            .animation(on && !reduce ? .easeInOut(duration: 0.52).delay(delay) : nil, value: on)
    }
}

#Preview("开屏") {
    SplashView(interactive: true) {}
}
