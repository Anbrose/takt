import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Recognition languages offered on the recording screen (prototype `langList`).
enum NoteLanguage {
    struct Entry: Identifiable { let id: String; let short: String; let name: String }

    static let all: [Entry] = [
        .init(id: "zh_CN", short: "中", name: "普通话"), .init(id: "zh_TW", short: "繁", name: "國語"),
        .init(id: "yue_CN", short: "粵", name: "粵語"), .init(id: "ja_JP", short: "日", name: "日本語"),
        .init(id: "ko_KR", short: "한", name: "한국어"), .init(id: "en_US", short: "EN", name: "English"),
        .init(id: "fr_FR", short: "FR", name: "Français"), .init(id: "de_DE", short: "DE", name: "Deutsch"),
        .init(id: "es_ES", short: "ES", name: "Español"),
    ]

    /// `zh-CN` (server) and `zh_CN` (device) name the same language.
    static func normalized(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "_") }

    static func entry(_ id: String) -> Entry? { all.first { $0.id == normalized(id) } }

    static func short(_ id: String) -> String {
        entry(id)?.short ?? normalized(id).split(separator: "_").first.map { $0.uppercased() } ?? id
    }

    /// `m:ss`, or `h:mm:ss` from an hour on.
    static func clock(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// A note not yet on the server shows the title the server will give it (`YYYY-MM-DD HH:mm`, UTC).
    static func title(_ title: String, createdAt: Date) -> String {
        guard title.isEmpty else { return title }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: createdAt)
    }
}

/// 笔记: back, 自动生成任务 switch, one 64 pt row per note (title, `m:ss · 中`, chain badge / spinner / check),
/// swipe left for 删除, 录音 button bottom right.
@available(iOS 26, macOS 26, *)
struct NotesListScreen: View {
    @Bindable var notes: NotesModel
    let onBack: () -> Void
    let onOpen: (UUID) -> Void
    let onRecord: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The row whose 删除 button is showing.
    @State private var swiped: UUID?
    /// A swipe ends with the finger lifting over the row's button; that release isn't a tap (prototype: 450 ms).
    @State private var swipedAt = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                list
                if notes.items.isEmpty {
                    Image(systemName: "mic")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Palette.line)
                        .padding(.bottom, 76)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: notes.items.isEmpty)
        }
        .background(Palette.bg.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) {
            if notes.recording == nil {
                RecordButton(action: onRecord)
                    .padding(.trailing, Metrics.gutter)
                    .padding(.bottom, 16)
                    .transition(reduce ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduce ? Motion.fade : Motion.toggle, value: notes.recording == nil)
        .overlay(alignment: .top) { NotesToast(notes: notes) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BackButton(action: onBack)
            Text("笔记")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { notes.autoExtract.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                    SwitchTrack(on: notes.autoExtract)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: Metrics.hit)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("自动生成任务")
            .accessibilityValue(notes.autoExtract ? "1" : "0")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier("notes.auto")
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
        .frame(minHeight: 76)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(notes.items) { item in
                    NoteRow(
                        item: item,
                        swiped: Binding { swiped == item.id } set: { on in
                            swipedAt = Date()
                            Motion.with(Motion.collapse, reduce: reduce) { swiped = on ? item.id : nil }
                        },
                        onOpen: {
                            if Date().timeIntervalSince(swipedAt) < 0.45 { return }
                            if swiped != nil {
                                Motion.with(Motion.collapse, reduce: reduce) { swiped = nil }
                            } else {
                                onOpen(item.id)
                            }
                        },
                        onDelete: {
                            swiped = nil
                            Task { await notes.delete(item.id) }
                        }
                    )
                    .transition(
                        reduce
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.94).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 112)
            .animation(reduce ? Motion.fade : Motion.collapse, value: notes.items)
        }
        .refreshable { await notes.load() }
    }
}

/// One note: tap opens, swipe left shows 删除 sliding in over the right end.
@available(iOS 26, macOS 26, *)
private struct NoteRow: View {
    let item: NoteItem
    @Binding var swiped: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var title: String { NoteLanguage.title(item.title, createdAt: item.createdAt) }
    private var chains: Int { item.chainCount ?? 0 }
    private var busy: Bool { item.processing }
    private var done: Bool { !busy && chains == 0 && (item.importedCount ?? 0) > 0 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Text("\(NoteLanguage.clock(item.durationMs)) · \(NoteLanguage.short(item.locale))")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    status
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(height: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(chains > 0 && !busy ? "\(chains)" : "")
            .accessibilityIdentifier("note.\(title)")

            if swiped {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 64)
                        .frame(maxHeight: .infinity)
                        .background(Palette.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除：\(title)")
                .accessibilityIdentifier("delete：\(title)")
                .transition(.move(edge: .trailing))
            }
        }
        .frame(height: 64)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.line, lineWidth: 1.5))
        .modifier(SideSwipe { left in if swiped != left { swiped = left } })
        .accessibilityAction(named: "删除", onDelete)
    }

    /// Badge (chains left), spinner (still on the device / being processed) or check (all imported), cross-faded.
    private var status: some View {
        ZStack {
            Text(chains > 0 ? "\(chains)" : "")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.accentText)
                .frame(width: 28, height: 28)
                .background(Palette.soft, in: Circle())
                .contentTransition(.numericText())
                .opacity(!busy && chains > 0 ? 1 : 0)
                .scaleEffect(!busy && chains > 0 ? 1 : 0.6)
            Spinner()
                .opacity(busy ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .opacity(done ? 1 : 0)
        }
        .frame(width: 28, height: 28)
        .animation(.easeInOut(duration: 0.24), value: busy)
        .animation(.easeInOut(duration: 0.24), value: chains)
        .animation(.easeInOut(duration: 0.24), value: done)
        .accessibilityHidden(true)
    }
}

/// Prototype swipe: decided once the finger has moved 28 pt mostly sideways (left = true).
/// A UIKit pan that starts only for sideways movement, so the list keeps scrolling vertically.
@available(iOS 26, macOS 26, *)
private struct SideSwipe: ViewModifier {
    let onSwipe: (Bool) -> Void

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.gesture(SidePan(onSwipe: onSwipe))
        #else
        content
        #endif
    }
}

#if canImport(UIKit)
@available(iOS 26, *)
private struct SidePan: UIGestureRecognizerRepresentable {
    let onSwipe: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        guard pan.state == .changed || pan.state == .ended else { return }
        let t = pan.translation(in: pan.view)
        guard abs(t.x) >= 28, abs(t.x) >= abs(t.y) * 1.5 else { return }
        onSwipe(t.x < 0)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return abs(t.x) > abs(t.y)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

/// Round filled 录音 button (same place and look as the home ＋).
struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Palette.onFill)
                .frame(width: 56, height: 56)
                .background(Palette.fill, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("录音")
        .accessibilityIdentifier("notes.record")
    }
}

/// Failure toast for the notes screens (same look as the list toast).
struct NotesToast: View {
    @Bindable var notes: NotesModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Group {
            if let text = notes.notice {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.onFill)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Palette.fill, in: Capsule())
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation(Motion.fade) { notes.notice = nil }
                    }
            }
        }
        .padding(.top, 8)
        .animation(reduce ? Motion.fade : Motion.sheet, value: notes.notice)
    }
}
