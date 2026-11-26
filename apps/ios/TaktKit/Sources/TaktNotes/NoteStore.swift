import Foundation

/// Notes on disk: `{root}/{id}/note.json` plus `{root}/{id}/{index}.m4a` per segment (`{index}.caf` while it
/// records, see `SegmentFile`).
public actor NoteStore {
    private let root: URL
    // Default date coding (seconds as a double) round-trips a Date exactly.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Notes`.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Notes", directoryHint: .isDirectory)
    }

    /// Every readable note, newest first. A folder whose note.json is missing or unreadable is skipped.
    public func all() -> [LocalNote] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { read($0.appending(path: "note.json")) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func note(_ id: UUID) -> LocalNote? {
        read(noteURL(id))
    }

    public func save(_ n: LocalNote) throws {
        try FileManager.default.createDirectory(at: folder(n.id), withIntermediateDirectories: true)
        try encoder.encode(n).write(to: noteURL(n.id), options: .atomic)
    }

    /// Reads, changes and writes one note without another caller interleaving. Nil when the note doesn't exist.
    @discardableResult
    public func update(_ id: UUID, _ change: @Sendable (inout LocalNote) -> Void) throws -> LocalNote? {
        guard var n = note(id) else { return nil }
        change(&n)
        try save(n)
        return n
    }

    public func segmentURL(_ id: UUID, _ index: Int) -> URL {
        segmentFileURL(id, index)
    }

    /// Same path as `segmentURL`, readable without awaiting (the recorder asks for it synchronously).
    public nonisolated func segmentFileURL(_ id: UUID, _ index: Int) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory).appending(path: "\(index).m4a")
    }

    /// Removes one segment's audio; the note and its segment entry stay.
    public func deleteAudio(_ id: UUID, _ index: Int) throws {
        let url = segmentURL(id, index)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Audio of `id` on disk that no segment entry lists: a segment cut off by a kill (`{n}.caf`, encoded here) or
    /// one encoded but not listed yet (`{n}.m4a`). A file that can't be read is left as it is.
    public func recoverSegments(_ id: UUID, listed: Set<Int>) -> [LocalSegment] {
        let dir = folder(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found: [LocalSegment] = []
        for name in names where name.hasSuffix(".part.m4a") {
            try? FileManager.default.removeItem(at: dir.appending(path: name))  // an encode cut off by a kill
        }
        func indices(_ ext: String) -> Set<Int> {
            Set(names.compactMap { n in n.hasSuffix(".\(ext)") ? Int(n.dropLast(ext.count + 1)) : nil })
        }
        let recordings = indices("caf")
        for i in recordings.sorted() {
            let recording = dir.appending(path: "\(i).caf")
            if listed.contains(i) {
                // Listed means it was encoded; only the clean-up was cut off.
                try? FileManager.default.removeItem(at: recording)
            } else if let ms = try? SegmentFile.encode(recording, to: segmentURL(id, i)), ms > 0 {
                found.append(LocalSegment(index: i, durationMs: ms, file: "\(i).m4a"))
            }
        }
        for i in indices("m4a").subtracting(listed).subtracting(recordings).sorted() {
            if let ms = SegmentFile.durationMs(segmentURL(id, i)), ms > 0 {
                found.append(LocalSegment(index: i, durationMs: ms, file: "\(i).m4a"))
            }
        }
        return found.sorted { $0.index < $1.index }
    }

    public func delete(_ id: UUID) throws {
        let dir = folder(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private func folder(_ id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func noteURL(_ id: UUID) -> URL {
        folder(id).appending(path: "note.json")
    }

    private func read(_ url: URL) -> LocalNote? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LocalNote.self, from: data)
    }
}
