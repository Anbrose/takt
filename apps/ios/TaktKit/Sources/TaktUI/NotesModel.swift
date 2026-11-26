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
    /// Still recording, not yet diarized (or given up on), or its transcript not yet on the server.
    public var processing: Bool
    /// Known only once the server has the note.
    public var chainCount: Int?
    public var importedCount: Int?
    /// Segments wait for a language model whose download failed (it is retried at launch, when the network
    /// returns and when the app comes back).
    public var waitingForModel = false
}

/// State of the notes list and of the recording in progress.
@MainActor
@Observable
public final class NotesModel {
    private static let localeKey = "notes.locale"
    private static let fallbackLocale = "zh_CN"
    private static let autoExtractKey = "notes.autoExtract"
    private static let introSeenKey = "notes.introSeen"
    private static let autoPendingKey = "notes.autoPending"

    private let backend: any TaktBackend
    private let store: NoteStore
    private let processor: NoteProcessor
    private let sync: NoteSync
    private let capture: AudioCapture
    private let defaults: UserDefaults
    private let deviceLocale: String
    private let supportedLocales: @Sendable () async -> [String]
    private var recovered = false
    /// A start is in flight (between the 录音 tap and `recording` being set).
    private var starting = false
    private var applyingDefault = false

    private var summaries: [NoteSummary] = []
    private var locals: [LocalNote] = []
    /// Notes being deleted: a refresh finishing meanwhile must not bring their rows back.
    private var deleting: Set<UUID> = []
    /// Segment writes of the current recording, chained so they land in order.
    private var pendingWrites: Task<Void, Never>?
    /// The background sync started by `load()`.
    public private(set) var syncTask: Task<Void, Never>?
    /// The latest 自动生成任务 pass, started after the list is rebuilt so loading never waits on the language model.
    public private(set) var autoExtractTask: Task<Void, Never>?
    private let transcriber: (any Transcribing)?
    /// Languages whose on-device model is installed, as far as this model has checked.
    public private(set) var installed: Set<String> = []
    /// Languages whose model is downloading now.
    public private(set) var preparing: Set<String> = []
    /// Languages whose last model download failed; cleared when one succeeds.
    public private(set) var downloadFailed: Set<String> = []

    public private(set) var items: [NoteItem] = []
    /// Notes whose 自动生成任务 extract call is running now (the detail shows a spinner meanwhile).
    public private(set) var autoExtracting: Set<UUID> = []
    public var locale: String {
        didSet { if !applyingDefault { defaults.set(locale, forKey: Self.localeKey) } }
    }
    public private(set) var recording: (id: UUID, startedAt: Date)?
    /// 自动生成任务: once a recording's transcript is on the server, extract is called for it once. Device-local.
    public var autoExtract: Bool {
        didSet { defaults.set(autoExtract, forKey: Self.autoExtractKey) }
    }
    /// The first-recording intro was finished with 「开始录音」 (closing it by the backdrop doesn't count).
    public var introSeen: Bool {
        didSet { defaults.set(introSeen, forKey: Self.introSeenKey) }
    }
    /// Short, user-facing message for the last failure. Cleared on the next action.
    public var notice: String?

    public init(
        backend: any TaktBackend, store: NoteStore, processor: NoteProcessor, sync: NoteSync,
        capture: AudioCapture, transcriber: (any Transcribing)? = nil, defaults: UserDefaults = .standard,
        deviceLocale: String = Locale.current.identifier,
        supportedLocales: @escaping @Sendable () async -> [String] = NotesModel.systemSupportedLocales
    ) {
        self.backend = backend; self.store = store; self.processor = processor; self.sync = sync
        self.capture = capture; self.transcriber = transcriber; self.defaults = defaults
        self.deviceLocale = deviceLocale; self.supportedLocales = supportedLocales
        locale = defaults.string(forKey: Self.localeKey) ?? Self.fallbackLocale
        autoExtract = defaults.object(forKey: Self.autoExtractKey) as? Bool ?? true
        introSeen = defaults.bool(forKey: Self.introSeenKey)
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

    /// Recovers notes cut off by a kill and shows the list; uploads, then transcription and diarization left
    /// over (which can take minutes), run in the background.
    public func load() async {
        await recoverOnce()
        await resolveDefaultLocale()
        locals = await store.all()
        rebuild()
        let sync = sync, processor = processor
        syncTask = Task { [weak self] in
            await sync.syncAll()
            await self?.refresh()
            await processor.processPending()
            await sync.syncAll()
            await self?.refresh()
            await self?.retryDownloads()
        }
        await fetchSummaries()
    }

    /// Once per model, before the first recording: marks notes cut off by a kill as stopped (quick; the
    /// processing they still need runs in `load()`'s background task).
    private func recoverOnce() async {
        guard !recovered else { return }
        recovered = true
        await processor.recoverInterrupted()
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
        let previous = autoExtractTask
        autoExtractTask = Task { [weak self] in
            await previous?.value
            await self?.runAutoExtract()
        }
    }

    // MARK: 自动生成任务

    /// Notes recorded with 自动生成任务 on that haven't had their one extract call yet.
    private var autoPending: [String] {
        get { defaults.stringArray(forKey: Self.autoPendingKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.autoPendingKey) }
    }

    /// One extract call per pending note whose transcript has reached the server. The id is dropped before the
    /// call, so a failure (or a kill mid-call) is never retried; failures stay silent — 「提取」 is still there.
    private func runAutoExtract() async {
        // Postgres hands uuids back in lower case; the device writes them in upper case.
        let pending = Set(autoPending)
        let due = summaries.filter { $0.hasTranscript && pending.contains($0.id.lowercased()) }.map(\.id)
        guard !due.isEmpty else { return }
        let done = Set(due.map { $0.lowercased() })
        autoPending.removeAll { done.contains($0) }
        for id in due {
            let uuid = UUID(uuidString: id)
            if let uuid { autoExtracting.insert(uuid) }
            _ = try? await backend.extract(note: id)
            if let uuid { autoExtracting.remove(uuid) }
        }
        if let fresh = try? await backend.notes() {
            summaries = fresh
            rebuild()
        }
    }

    // MARK: Language models

    /// Checks which of `locales` have their model installed (for the language sheet's download marks).
    public func checkInstalled(_ locales: [String]) async {
        guard let transcriber else { return }
        for l in locales where await transcriber.isReady(locale: l) { installed.insert(l) }
    }

    /// Downloads the model for `locale` when it is missing, then transcribes whatever was waiting for it.
    /// Recording never waits for this.
    public func prepare(_ locale: String) async {
        guard let transcriber, !preparing.contains(locale) else { return }
        if await transcriber.isReady(locale: locale) {
            installed.insert(locale)
            if downloadFailed.remove(locale) != nil { rebuild() }
            return
        }
        guard await transcriber.supports(locale: locale) else { return }
        preparing.insert(locale)
        let ok = (try? await transcriber.prepare(locale: locale)) != nil
        preparing.remove(locale)
        guard ok else {
            downloadFailed.insert(locale)
            rebuild()
            return
        }
        downloadFailed.remove(locale)
        installed.insert(locale)
        rebuild()
        await resume()
    }

    /// Downloads the model of every language a note's segments are waiting for. At launch, when the network
    /// returns and when the app becomes active, so a note recorded offline is transcribed without another
    /// recording in that language.
    public func retryDownloads() async {
        let waiting = Set(await store.all().filter { $0.segments.contains { !$0.transcribed } }.map(\.locale))
        for l in waiting.sorted() { await prepare(l) }
    }

    /// The language chip. During a recording it also applies to that recording (one language per note).
    public func chooseLocale(_ l: String) async {
        locale = l
        if let id = recording?.id {
            _ = try? await store.update(id) { $0.locale = l }
            locals = await store.all()
            rebuild()
        }
        await prepare(l)
    }

    /// At launch and when the network returns: finishes processing and uploads left over, then refreshes.
    /// Skipped while recording — the processor's recovery would take the live note for one cut off by a kill.
    public func resume() async {
        guard recording == nil else { return }
        await processor.recoverAfterLaunch()
        await sync.syncAll()
        await refresh()
        await retryDownloads()
    }

    private func rebuild() {
        let local = Dictionary(locals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [NoteItem] = summaries.compactMap { s in
            guard let id = UUID(uuidString: s.id) else { return nil }
            let l = local[id]
            return NoteItem(
                id: id, title: s.title, durationMs: s.durationMs, locale: s.locale, createdAt: s.createdAt,
                processing: l.map(Self.isProcessing) ?? false, chainCount: s.chainCount, importedCount: s.importedCount,
                waitingForModel: l.map(waitsForModel) ?? false)
        }
        let known = Set(merged.map(\.id))
        merged += locals.filter { !known.contains($0.id) }.map { l in
            NoteItem(
                id: l.id, title: l.title, durationMs: l.durationMs, locale: l.locale, createdAt: l.createdAt,
                processing: true, chainCount: nil, importedCount: nil, waitingForModel: waitsForModel(l))
        }
        items = merged.filter { !deleting.contains($0.id) }.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    private func waitsForModel(_ n: LocalNote) -> Bool {
        downloadFailed.contains(n.locale) && n.segments.contains { !$0.transcribed }
    }

    private static func isProcessing(_ n: LocalNote) -> Bool {
        n.recording || !n.diarizationSettled || !n.synced.created || !n.synced.transcriptSent
            || (n.diarized && !n.synced.diarizedSent)
    }

    // MARK: Recording

    /// The 录音 button. Before the intro has been seen it starts nothing and returns false: show the intro.
    public func requestRecording() async throws -> Bool {
        guard introSeen else { return false }
        try await startRecording()
        return true
    }

    /// A new note's title: when recording started, in the phone's time zone (`11-23 14:05`). Sent with the
    /// note, so the title is the same before and after it reaches the server.
    public nonisolated static func defaultTitle(_ at: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: at)
    }

    /// 「开始录音」 in the first-recording intro.
    public func finishIntro(autoExtract: Bool) async throws {
        self.autoExtract = autoExtract
        introSeen = true
        try await startRecording()
    }

    /// Creates the local note and starts the recorder. Segments are saved (and transcribed) as they finish.
    public func startRecording() async throws {
        // Set before the first await: a second tap arriving meanwhile must not start another recording.
        guard recording == nil, !starting else { return }
        starting = true
        defer { starting = false }
        notice = nil
        await recoverOnce()
        let now = Date()
        let note = LocalNote(title: Self.defaultTitle(now), locale: locale, createdAt: now)
        try await store.save(note)
        let id = note.id
        let store = store
        await processor.recordingStarted(id)
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
            await processor.recordingEnded(id)
            try? await store.delete(id)
            throw error
        }
        recording = (id, Date())
        locals.append(note)
        rebuild()
        let locale = note.locale
        Task { [weak self] in await self?.prepare(locale) }
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
        let key = id.uuidString.lowercased()
        if autoExtract, !autoPending.contains(key) { autoPending.append(key) }
        await pendingWrites?.value
        _ = try? await store.update(id) { $0.recording = false }
        await processor.recordingEnded(id)
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
        let d = detail(id)
        await d.load()
        return d
    }

    /// The detail model for `id`, not loaded yet (the screen is pushed at once and shows its loading state).
    public func detail(_ id: UUID) -> NoteDetailModel {
        NoteDetailModel(id: id, backend: backend, store: store) { [weak self] in
            Task { await self?.fetchSummaries() }
        }
    }

    /// The 「加入到项目」 dock's model over the same backend.
    public func importDock() -> ImportDockModel { ImportDockModel(backend: backend) }

    /// Optimistic: the row goes at once and comes back if the server refuses.
    public func delete(_ id: UUID) async {
        guard recording?.id != id, let before = items.firstIndex(where: { $0.id == id }) else { return }
        let row = items[before]
        notice = nil
        items.remove(at: before)
        deleting.insert(id)
        defer { deleting.remove(id) }
        // The server's ids are lower case; compare as UUIDs.
        let onServer = summaries.contains { UUID(uuidString: $0.id) == id }
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
        summaries.removeAll { UUID(uuidString: $0.id) == id }
        locals.removeAll { $0.id == id }
        try? await store.delete(id)
    }
}
