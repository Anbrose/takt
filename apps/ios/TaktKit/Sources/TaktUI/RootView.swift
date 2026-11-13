import SwiftUI
import TaktAPI

/// App root: loads the first project and shows 规划模式, or a minimal empty / error state.
public struct RootView: View {
    @State private var app: AppModel
    @AppStorage("theme") private var themeRaw = ThemeChoice.system.rawValue
    @State private var newName = ""

    public init(backend: any TaktBackend) {
        _app = State(initialValue: AppModel(backend: backend))
    }

    private var theme: Binding<ThemeChoice> {
        Binding { ThemeChoice(rawValue: themeRaw) ?? .system } set: { themeRaw = $0.rawValue }
    }

    public var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                status(icon: "wifi.exclamationmark", text: message) {
                    WideButton(title: "重试", kind: .primary) { Task { await app.start() } }
                        .frame(width: 160)
                }
            case .empty:
                status(icon: "square.stack.3d.up", text: "还没有 Project") {
                    InputField(text: $newName, placeholder: "名称").frame(maxWidth: 280)
                    WideButton(title: "新建", kind: .primary) { Task { await app.createProject(name: newName) } }
                        .frame(width: 160)
                }
            case .ready(let plan):
                PlanScreen(plan: plan, theme: theme)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .preferredColorScheme(theme.wrappedValue.colorScheme)
        .task { await app.start() }
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
