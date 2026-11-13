import Foundation
import SwiftUI
import TaktAPI

/// Entry view for the app target. Picks the backend from the launch environment:
/// - `-demo` launch argument → in-memory 日本旅行 sample, no server needed
/// - `TAKT_API_URL` environment variable → that server
/// - otherwise http://127.0.0.1:3000 (the simulator reaches the Mac's localhost)
public struct AppRoot: View {
    @State private var backend: (any TaktBackend)?
    private let info: ProcessInfo

    public init(info: ProcessInfo = .processInfo) {
        self.info = info
    }

    public static let defaultServer = URL(string: "http://127.0.0.1:3000")!

    public var body: some View {
        Group {
            if let backend {
                RootView(backend: backend)
            } else {
                Palette.bg.ignoresSafeArea()
            }
        }
        .task {
            guard backend == nil else { return }
            if info.arguments.contains("-demo") {
                backend = await InMemoryBackend.sample()
            } else {
                let url = info.environment["TAKT_API_URL"].flatMap(URL.init(string:)) ?? Self.defaultServer
                backend = LiveBackend(baseURL: url)
            }
        }
    }
}
