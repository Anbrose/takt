import Foundation
import SwiftUI
import TaktAPI

/// Entry view for the app target. Picks the backend from the launch environment:
/// - `-demo` launch argument → in-memory 日本旅行 sample, no server needed
/// - `TAKT_API_URL` environment variable → that server (Xcode scheme / simctl)
/// - `TaktAPIURL` in Info.plist, set at build time from the `TAKT_API_URL` build setting
///   (so a device build launched from the home screen still finds the Mac on the LAN)
/// - otherwise http://127.0.0.1:3000 (the simulator reaches the Mac's localhost)
public struct AppRoot: View {
    @State private var backend: (any TaktBackend)?
    @State private var routes: any RouteProvider = MapKitRouteProvider()
    @State private var splash = true
    /// First launch shows 重播 / 开始; afterwards the splash plays and hands over by itself.
    @AppStorage("splash.seen") private var splashSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    private let info: ProcessInfo

    public init(info: ProcessInfo = .processInfo) {
        self.info = info
    }

    public static let defaultServer = URL(string: "http://127.0.0.1:3000")!

    public var body: some View {
        ZStack {
            // Loads underneath while the splash plays.
            if let backend {
                RootView(backend: backend, routes: routes)
            } else {
                Palette.bg.ignoresSafeArea()
            }
            if splash && !info.arguments.contains("-skip-splash") {
                SplashView(interactive: !splashSeen) {
                    splashSeen = true
                    Motion.with(Motion.nav, reduce: reduce) { splash = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task {
            guard backend == nil else { return }
            // -demo: offline sample data and straight-line routes (deterministic for UI tests).
            if info.arguments.contains("-demo") {
                routes = StraightLineProvider()
                backend = await InMemoryBackend.sample()
            } else {
                let fromEnv = info.environment["TAKT_API_URL"].flatMap(URL.init(string:))
                let fromPlist = (Bundle.main.object(forInfoDictionaryKey: "TaktAPIURL") as? String)
                    .flatMap { $0.isEmpty ? nil : URL(string: $0) }
                backend = LiveBackend(baseURL: fromEnv ?? fromPlist ?? Self.defaultServer)
            }
        }
    }
}
