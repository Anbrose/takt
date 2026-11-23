import Foundation
import Observation
import TaktAPI
import TaktNotes

/// One row of the notes list: the server's summary merged with what is still only on the device.
public struct NoteItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var durationMs: Int
    public var locale: String
    public var createdAt: Date
    /// Still recording, not yet diarized, or not yet fully on the server.
    public var processing: Bool
    /// Known only once the server has the note.
    public var chainCount: Int?
    public var importedCount: Int?
}

/// State of the notes list and of the recording in progress.
@MainActor
@Observable
public final class NotesModel {
    private static let localeKey = "notes.locale"
    private static let fallbackLocale = "zh_CN"

    private let backend: any TaktBackend
    private let store: NoteStore
    private let processor: NoteProcessor
    private let sync: NoteSync
    private let capture: AudioCapture
    private let defaults: UserDefaults
    private let deviceLocale: String
    private let supportedLocales: @Sendable () async -> [String]
    private var recovered = false
    private var applyingDefault = false

    private var summaries: [NoteSummary] = []
    private var locals: [LocalNote] = []
    /// Notes being deleted: a refresh finishing meanwhile must not bring their rows back.
    private var deleting: Set<UUID> = []
    /// Segment writes of the current recording, chained so they land in order.
    private var pendingWrites: Task<Void, Never>?
    /// The background sync started by `load()`.
    public private(set) var syncTask: Task<Void, Never>?

    public private(set) var items: [NoteItem] = []
    public var locale: String {
        didSet { if !applyingDefault { defaults.set(locale, forKey: Self.localeKey) } }
    }
    public private(set) var recording: (id: UUID, startedAt: Date)?
    /// Short, user-facing message for the last failure. Cleared on the next action.
    public var notice: String?

    public init(
        backend: any TaktBackend, store: NoteStore, processor: NoteProcessor, sync: NoteSync,
        capture: AudioCapture, defaults: UserDefaults = .standard,
        deviceLocale: String = Locale.current.identifier,
        supportedLocales: @escaping @Sendable () async -> [String] = NotesModel.systemSupportedLocales
    ) {
        self.backend = backend; self.store = store; self.processor = processor; self.sync = sync
        self.capture = capture; self.defaults = defaults
        self.deviceLocale = deviceLocale; self.supportedLocales = supportedLocales
        locale = defaults.string(forKey: Self.localeKey) ?? Self.fallbackLocale
    }

    /// Identifiers (`zh_CN`) of the languages on-device transcription supports; empty before iOS 26.
    public static let systemSupportedLocales: @Sendable () async -> [String] = {
        if #available(iOS 26, macOS 26, *) { return await SupportedLanguages.all().map(\.identifier) }
        return []
    }

    /// Without a remembered choice, the device language is used once it is known to be supported.
    private func resolveDefaultLocale() async {
        guard defaults.string(forKey: Self.localeKey) == nil else { return }
        let supported = await supportedLocales()
        guard supported.contains(deviceLocale), defaults.string(forKey: Self.localeKey) == nil else { return }
        applyingDefault = true
        locale = deviceLocale
        applyingDefault = false
    }

    // MARK: Loading

    /// Recovers notes cut off by a kill, resumes unsent work in the background, and shows the server's list.
    public func load() async {
        await recoverOnce()
        await resolveDefaultLocale()
        locals = await store.all()
        rebuild()
        let sync = sync
        syncTask = Task { [weak self] in
            await sync.syncAll()
            await self?.refresh()
        }
        await fetchSummaries()
    }

    /// Once per model, and before the first recording: a later run would mistake the live recording for one
    /// cut off by a kill.
    private func recoverOnce() async {
        guard !recovered else { return }
        recovered = true
        await processor.recoverAfterLaunch()
    }

    private func refresh() async {
        locals = await store.all()
        await fetchSummaries()
    }

    private func fetchSummaries() async {
        do {
            summaries = try await backend.notes()
        } catch {
            notice = "加载失败"
        }
        rebuild()
    }

    private func rebuild() {
        let local = Dictionary(locals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [NoteItem] = summaries.compactMap { s in
            guard let id = UUID(uuidString: s.id) else { return nil }
            let l = local[id]
            return NoteItem(
                id: id, title: s.title, durationMs: s.durationMs, locale: s.locale, createdAt: s.createdAt,
                processing: l.map(Self.isProcessing) ?? false, chainCount: s.chainCount, importedCount: s.importedCount)
        }
        let known = Set(merged.map(\.id))
        merged += locals.filter { !known.contains($0.id) }.map { l in
            NoteItem(
                id: l.id, title: l.title, durationMs: l.durationMs, locale: l.locale, createdAt: l.createdAt,
                processing: true, chainCount: nil, importedCount: nil)
        }
        items = merged.filter { !deleting.contains($0.id) }.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    private static func isProcessing(_ n: LocalNote) -> Bool {
        n.recording || !n.diarized || !n.synced.created || !n.synced.diarizedSent
    }

    // MARK: Recording

    /// Creates the local note and starts the recorder. Segments are saved (and transcribed) as they finish.
    public func startRecording() async throws {
        guard recording == nil else { return }
        notice = nil
        await recoverOnce()
        let note = LocalNote(locale: locale)
        try await store.save(note)
        let id = note.id
        let store = store
        do {
            try capture.start(
                segmentURL: { store.segmentFileURL(id, $0) },
                segmentSeconds: SegmentRecorder.defaultSegmentSeconds,
                onSegment: { [weak self] index, durationMs in
                    MainActor.assumeIsolated { self?.queueSegment(id, index, durationMs) }
                },
                onError: { [weak self] _ in
                    MainActor.assumeIsolated { self?.recorderFailed(id) }
                })
        } catch {
            try? await store.delete(id)
            throw error
        }
        recording = (id, Date())
        locals.append(note)
        rebuild()
    }

    /// Closes the last segment, then transcribes, diarizes and uploads. The list shows the note at once.
    public func stopRecording() async {
        guard let current = recording else { return }
        let last = await capture.stop()
        if let last { queueSegment(current.id, last.index, last.durationMs) }
        recording = nil
        await finish(current.id)
    }

    private func recorderFailed(_ id: UUID) {
        guard recording?.id == id else { return }
        recording = nil
        notice = "录音中断"
        Task { await finish(id) }
    }

    /// Waits for queued segment writes, marks the note stopped, then processes and syncs it.
    private func finish(_ id: UUID) async {
        await pendingWrites?.value
        _ = try? await store.update(id) { $0.recording = false }
        locals = await store.all()
        rebuild()
        await processor.process(id)
        await sync.sync(id)
        await refresh()
    }

    /// Test seam: waits until segment writes queued so far have landed.
    func finishPendingWork() async {
        await pendingWrites?.value
        locals = await store.all()
        rebuild()
    }

    private func queueSegment(_ id: UUID, _ index: Int, _ durationMs: Int) {
        guard durationMs > 0 else { return }
        let store = store, processor = processor
        let previous = pendingWrites
        pendingWrites = Task {
            await previous?.value
            _ = try? await store.update(id) { n in
                guard !n.segments.contains(where: { $0.index == index }) else { return }
                n.segments.append(LocalSegment(index: index, durationMs: durationMs, file: "\(index).m4a"))
            }
            await processor.process(id)
        }
    }

    // MARK: Opening and deleting

    public func open(_ id: UUID) async -> NoteDetailModel {
        let detail = NoteDetailModel(id: id, backend: backend, store: store) { [weak self] in
            Task { await self?.fetchSummaries() }
        }
        await detail.load()
        return detail
    }

    /// Optimistic: the row goes at once and comes back if the server refuses.
    public func delete(_ id: UUID) async {
        guard recording?.id != id, let before = items.firstIndex(where: { $0.id == id }) else { return }
        let row = items[before]
        notice = nil
        items.remove(at: before)
        deleting.insert(id)
        defer { deleting.remove(id) }
        let onServer = summaries.contains { $0.id == id.uuidString }
        do {
            if onServer { try await backend.deleteNote(id.uuidString) }
        } catch let e as BackendError where e.code == "not_found" {
            // already gone elsewhere
        } catch {
            deleting.remove(id)
            items.insert(row, at: min(before, items.count))
            notice = "删除失败"
            return
        }
        summaries.removeAll { $0.id == id.uuidString }
        locals.removeAll { $0.id == id }
        try? await store.delete(id)
    }
}
