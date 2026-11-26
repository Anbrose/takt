import Foundation
import Testing
import TaktCore
@testable import TaktNotes

func tempStore() -> (NoteStore, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
    return (NoteStore(root: root), root)
}

@Suite struct NoteStoreTests {
    @Test func roundTrip() async throws {
        let (store, root) = tempStore()
        let note = LocalNote(
            title: "京都", locale: "zh-CN", createdAt: Date(timeIntervalSince1970: 1_795_000_000),
            segments: [LocalSegment(index: 0, durationMs: 300_000, file: "0.m4a", transcribed: true)],
            tokens: [TimedText(startMs: 0, endMs: 400, text: "先去")],
            lines: [AlignedLine(startMs: 0, endMs: 400, text: "先去", speaker: "1")],
            recording: false, synced: SyncState(created: true, transcriptSent: false))
        let older = LocalNote(locale: "en-US", createdAt: Date(timeIntervalSince1970: 1_000))
        try await store.save(older)
        try await store.save(note)
        #expect(await store.all() == [note, older])
        #expect(await NoteStore(root: root).note(note.id) == note)
    }

    @Test func deleteAudioKeepsNote() async throws {
        let (store, _) = tempStore()
        let note = LocalNote(locale: "zh-CN", segments: [LocalSegment(index: 0, durationMs: 1000, file: "0.m4a")])
        try await store.save(note)
        let audio = await store.segmentURL(note.id, 0)
        try Data([1, 2, 3]).write(to: audio)

        try await store.deleteAudio(note.id, 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(await store.note(note.id) == note)

        try await store.delete(note.id)
        #expect(await store.all().isEmpty)
    }
}
