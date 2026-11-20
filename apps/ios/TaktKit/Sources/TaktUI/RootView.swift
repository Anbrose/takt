import SwiftUI
import TaktAPI

/// App root: Project 列表, with the open project pushed over it (规划页 slides in from the right,
/// the list drifts left and dims; back reverses it). Loading / error states cross-fade.
public struct RootView: View {
    @State private var app: AppModel
    @AppStorage("theme") private var themeRaw = ThemeChoice.system.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The list is taken out of the hierarchy once a project fully covers it (so VoiceOver and
    /// UI tests only see one screen), and put back under the project just before popping.
    @State private var listMounted = true

    public init(backend: any TaktBackend) {
        _app = State(initialValue: AppModel(backend: backend))
    }

    private var theme: Binding<ThemeChoice> {
        Binding { ThemeChoice(rawValue: themeRaw) ?? .system } set: { themeRaw = $0.rawValue }
    }

    public var body: some View {
        ZStack {
            switch app.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            case .failed(let message):
                status(icon: "wifi.exclamationmark", text: message) {
                    WideButton(title: "重试", kind: .primary) { Task { await app.start(animation: Motion.fade) } }
                        .frame(width: 160)
                }
                .transition(.opacity)
            case .ready:
                stack.transition(.opacity)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .preferredColorScheme(theme.wrappedValue.colorScheme)
        .task { await app.start(animation: Motion.fade) }
    }

    private var stack: some View {
        GeometryReader { geo in
            let pushed = app.open != nil
            ZStack {
                if listMounted || !pushed {
                ProjectListScreen(app: app, theme: theme)
                    .overlay {
                        Color.black
                            .opacity(pushed ? 0.18 : 0)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                    .offset(x: pushed && !reduce ? -geo.size.width * 0.28 : 0)
                    .allowsHitTesting(!pushed)
                    .accessibilityHidden(pushed)
                }

                if let plan = app.open {
                    PlanScreen(plan: plan, theme: theme) {
                        listMounted = true
                        // Next runloop: the list is laid out (drifted left, dimmed) before it slides back.
                        DispatchQueue.main.async {
                            app.closeProject(animation: reduce ? Motion.fade : Motion.push)
                        }
                    }
                    .id(plan.project.id)
                    .background(Palette.bg.ignoresSafeArea())
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.12), radius: 15, x: -10)
                    .transition(reduce ? .opacity : .move(edge: .trailing))
                    .zIndex(1)
                }
            }
            .onChange(of: app.open?.project.id) { _, id in
                guard id != nil else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(480))
                    if app.open != nil { listMounted = false }
                }
            }
        }
    }

    private func status<C: View>(icon: String, text: String, @ViewBuilder actions: () -> C) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
            actions()
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("规划 · 浅色") {
    PreviewHost()
}

#Preview("规划 · 深色") {
    PreviewHost().preferredColorScheme(.dark)
}

private struct PreviewHost: View {
    @State private var backend: InMemoryBackend?
    var body: some View {
        Group {
            if let backend { RootView(backend: backend) } else { Color.clear }
        }
        .task { backend = await InMemoryBackend.sample() }
    }
}
