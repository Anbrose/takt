import SwiftUI
import TaktAPI

/// App root: Project 列表, with the open project pushed over it (规划页 slides in from the right,
/// the list drifts left and dims; back reverses it). Loading / error states cross-fade.
public struct RootView: View {
    @State private var app: AppModel
    /// Note taking; nil where it isn't available (before iOS 26).
    private let notes: NotesModel?
    /// Asks for the microphone before the first recording.
    private let allowRecording: @MainActor () async -> Bool
    @AppStorage("theme") private var themeRaw = ThemeChoice.system.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The list is taken out of the hierarchy once a screen fully covers it (so VoiceOver and
    /// UI tests only see one screen), and put back under it just before popping.
    @State private var listMounted = true
    /// Screens pushed over the list from the 悬浮按钮 menu (笔记 › note, 查找).
    @State private var routes: [Route] = []
    @State private var introOn = false
    /// A 录音 tap or note open is being handled; repeated taps meanwhile are ignored.
    @State private var recordBusy = false
    @State private var opening = false

    struct Route: Identifiable {
        enum Kind {
            case notes, search
            case note(NoteDetailModel)
        }
        let id = UUID()
        let kind: Kind

        var isNotes: Bool { if case .notes = kind { true } else { false } }
    }

    public init(
        backend: any TaktBackend, notes: NotesModel? = nil,
        allowRecording: @escaping @MainActor () async -> Bool = { true }
    ) {
        _app = State(initialValue: AppModel(backend: backend))
        self.notes = notes
        self.allowRecording = allowRecording
    }

    private var theme: Binding<ThemeChoice> {
        Binding { ThemeChoice(rawValue: themeRaw) ?? .system } set: { themeRaw = $0.rawValue }
    }

    /// 笔记 / 录音 exist only from iOS 26 (SpeechTranscriber).
    private var notesOn: Bool {
        guard notes != nil else { return false }
        if #available(iOS 26, macOS 26, *) { return true }
        return false
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
        // The recording view covers everything; VoiceOver shouldn't find the screens under it.
        .accessibilityHidden(notes?.recording != nil)
        .overlay { recordingLayers }
        .background(Palette.bg.ignoresSafeArea())
        .preferredColorScheme(theme.wrappedValue.colorScheme)
        .task { await app.start(animation: Motion.fade) }
        .task { if notesOn { await notes?.load() } }
    }

    private var covered: Bool { app.open != nil || !routes.isEmpty }
    private var pushAnimation: Animation { reduce ? Motion.fade : Motion.push }

    private var stack: some View {
        GeometryReader { geo in
            ZStack {
                listLayer(geo.size.width)
                planLayer
                routeLayers(geo.size.width)
            }
            .onChange(of: covered) { _, now in
                guard now else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(480))
                    if covered { listMounted = false }
                }
            }
        }
    }

    @ViewBuilder
    private func listLayer(_ width: CGFloat) -> some View {
        if listMounted || !covered {
            ProjectListScreen(
                app: app, theme: theme,
                onSearch: { push(.search) },
                onNotes: notesOn ? { push(.notes) } : nil,
                onRecord: notesOn ? { record() } : nil
            )
            .modifier(Covered(on: covered, width: width, reduce: reduce))
        }
    }

    @ViewBuilder
    private var planLayer: some View {
        if let plan = app.open {
            PlanScreen(plan: plan, theme: theme) {
                listMounted = true
                // Next runloop: the list is laid out (drifted left, dimmed) before it slides back.
                DispatchQueue.main.async {
                    app.closeProject(animation: pushAnimation)
                }
            }
            .id(plan.project.id)
            .modifier(Pushed(reduce: reduce))
            .zIndex(1)
        }
    }

    private func routeLayers(_ width: CGFloat) -> some View {
        let top = routes.count - 1
        return ForEach(Array(routes.enumerated()), id: \.element.id) { (i: Int, route: Route) in
            screen(route)
                .modifier(Covered(on: i < top, width: width, reduce: reduce))
                .modifier(Pushed(reduce: reduce))
                .zIndex(Double(2 + i))
        }
    }

    @ViewBuilder
    private func screen(_ route: Route) -> some View {
        switch route.kind {
        case .search:
            SearchScreen(onBack: pop)
        case .notes:
            if #available(iOS 26, macOS 26, *), let notes {
                NotesListScreen(notes: notes, onBack: pop, onOpen: openNote, onRecord: record)
            }
        case .note(let detail):
            if #available(iOS 26, macOS 26, *) {
                NoteDetailScreen(detail: detail, onBack: pop)
            }
        }
    }

    // MARK: Navigation

    private func push(_ kind: Route.Kind) {
        withAnimation(pushAnimation) { routes.append(Route(kind: kind)) }
    }

    private func pop() {
        guard !routes.isEmpty else { return }
        if routes.count == 1 && app.open == nil { listMounted = true }
        // Next runloop: the screen below is laid out (drifted left, dimmed) before it slides back.
        DispatchQueue.main.async {
            withAnimation(pushAnimation) { _ = routes.popLast() }
        }
    }

    private func openNote(_ id: UUID) {
        guard let notes, !opening else { return }
        opening = true
        Task {
            let detail = await notes.open(id)
            opening = false
            if case .note = routes.last?.kind { return }
            push(.note(detail))
        }
    }

    // MARK: Recording

    /// 录音 (menu or 笔记): the intro the first time, otherwise straight into recording.
    private func record() {
        guard let notes, !recordBusy, notes.recording == nil else { return }
        recordBusy = true
        Task {
            defer { recordBusy = false }
            guard await allowRecording() else { return failed() }
            do {
                if try await !notes.requestRecording() {
                    Motion.with(Motion.introSheet, reduce: reduce) { introOn = true }
                }
            } catch {
                failed()
            }
        }
    }

    private func startAfterIntro(_ auto: Bool) {
        guard let notes else { return }
        Motion.with(Motion.introSheet, reduce: reduce) { introOn = false }
        Task {
            // The sheet is on its way down before the recording view rises.
            try? await Task.sleep(for: .milliseconds(240))
            do { try await notes.finishIntro(autoExtract: auto) } catch { failed() }
        }
    }

    /// After 停止 the notes list is underneath, the new note on top.
    private func stop() {
        guard let notes else { return }
        if routes.last?.isNotes != true {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { routes.append(Route(kind: .notes)) }
        }
        Task { await notes.stopRecording() }
    }

    private func failed() {
        if routes.isEmpty { app.notice = "无法录音" } else { notes?.notice = "无法录音" }
    }

    @ViewBuilder
    private var recordingLayers: some View {
        if #available(iOS 26, macOS 26, *), let notes {
            ZStack {
                RecordIntroSheet(isPresented: $introOn, autoExtract: notes.autoExtract, onStart: startAfterIntro)
                ZStack {
                    if let rec = notes.recording {
                        RecordingView(notes: notes, startedAt: rec.startedAt, onStop: stop)
                            .transition(reduce ? .opacity : .move(edge: .bottom))
                    }
                }
                .animation(reduce ? Motion.fade : Motion.cover, value: notes.recording?.id)
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

/// A screen under another one: drifts 28% left and dims; hidden from VoiceOver and touches.
private struct Covered: ViewModifier {
    let on: Bool
    let width: CGFloat
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                Color.black
                    .opacity(on ? 0.18 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .offset(x: on && !reduce ? -width * 0.28 : 0)
            .allowsHitTesting(!on)
            .accessibilityHidden(on)
    }
}

/// A screen pushed from the right, with the shadow on its left edge.
private struct Pushed: ViewModifier {
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .background(Palette.bg.ignoresSafeArea())
            .compositingGroup()
            .shadow(color: .black.opacity(0.12), radius: 15, x: -10)
            .transition(reduce ? .opacity : .move(edge: .trailing))
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
