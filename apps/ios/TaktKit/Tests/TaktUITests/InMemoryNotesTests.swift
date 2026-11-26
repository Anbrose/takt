import Foundation
import Testing
import TaktAPI
@testable import TaktUI

private let noteId = "11111111-1111-4111-8111-111111111111"

private func line(_ i: Int, _ text: String) -> TranscriptLine {
    TranscriptLine(startMs: i * 6000, endMs: i * 6000 + 5800, text: text, speaker: "1")
}

/// A backend with a project, a note and an extracted draft (2 matching lines of 3).
private func extracted() async throws -> (InMemoryBackend, Level, Note) {
    let b = InMemoryBackend()
    let p = try await b.createProject(name: "京都")
    let level = try await b.level(p.rootTaskId)
    _ = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: Date())
    _ = try await b.updateNote(
        noteId, title: nil, durationMs: nil,
        transcript: [line(0, "先去伏见稻荷"), line(1, "好的"), line(2, "我来订酒店")], speakers: nil)
    return (b, level, try await b.extract(note: noteId))
}

@Suite struct InMemoryNotesTests {
    @Test func createIsIdempotent() async throws {
        let b = InMemoryBackend()
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let first = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: at)
        _ = try await b.updateNote(noteId, title: "改名", durationMs: nil, transcript: nil, speakers: nil)
        let again = try await b.createNote(id: noteId, title: "other", locale: "en", createdAt: Date())
        #expect(again.title == "改名")
        #expect(again.createdAt == first.createdAt)
        #expect(try await b.notes().count == 1)
    }

    @Test func notesAreNewestFirst() async throws {
        let b = InMemoryBackend()
        _ = try await b.createNote(id: "a", title: "old", locale: "zh", createdAt: Date(timeIntervalSince1970: 100))
        _ = try await b.createNote(id: "b", title: "new", locale: "zh", createdAt: Date(timeIntervalSince1970: 200))
        #expect(try await b.notes().map(\.title) == ["new", "old"])
    }

    @Test func importingATwoStepChainAddsAParentWithTwoChildren() async throws {
        let (b, level, note) = try await extracted()
        let a = note.extraction.chains[0].steps[0]
        let c = note.extraction.chains[1].steps[0]
        // Merge both steps into one chain through the edit endpoint, as the draft editor would.
        let merged = Chain(id: "00000000-0000-4000-8000-0000000000aa", name: "京都行程", steps: [a, c])
        let edited = try await b.updateExtraction(note: noteId, version: note.extraction.version, chains: [merged])
        let r = try await b.importNote(
            noteId, parent: level.task.id,
            picks: [ImportPick(chainId: merged.id, stepIds: [a.id, c.id], places: [:])])
        #expect(r.level.children.map(\.name) == ["京都行程"])
        #expect(r.level.children[0].childCount == 2)
        let inner = try await b.level(r.level.children[0].id)
        #expect(inner.children.map(\.name) == [a.name, c.name])
        #expect(r.note.extraction.chains.isEmpty)
        #expect(r.note.imported.count == 2)
        #expect(r.note.extraction.version == edited.extraction.version + 1)
    }

    @Test func importingOneStepAddsAPlainTask() async throws {
        let (b, level, note) = try await extracted()
        let chain = note.extraction.chains[0]
        let place = PickedPlace(place: "伏见稻荷大社", address: "京都市伏见区", lat: 34.97, lng: 135.77)
        let r = try await b.importNote(
            noteId, parent: level.task.id,
            picks: [ImportPick(chainId: chain.id, stepIds: [chain.steps[0].id], places: [chain.steps[0].id: place])])
        #expect(r.level.children.count == 1)
        #expect(r.level.children[0].name == chain.steps[0].name)
        #expect(r.level.children[0].childCount == 0)
        #expect(r.level.children[0].place == "伏见稻荷大社")
        #expect(r.level.children[0].lat == 34.97)
        #expect(r.note.extraction.chains.count == 1)
        #expect(r.note.importedCount == 1)
    }

    @Test func staleIdsThrowStaleDraftAndWriteNothing() async throws {
        let (b, level, note) = try await extracted()
        let chain = note.extraction.chains[0]
        let good = ImportPick(chainId: chain.id, stepIds: [chain.steps[0].id], places: [:])
        let stale = ImportPick(chainId: chain.id, stepIds: ["00000000-0000-4000-8000-00000000ffff"], places: [:])
        await #expect(throws: BackendError.api(status: 409, code: "stale_draft", message: "reload the draft")) {
            _ = try await b.importNote(noteId, parent: level.task.id, picks: [good, stale])
        }
        #expect(try await b.level(level.task.id).children.isEmpty)
        #expect(try await b.note(noteId).importedCount == 0)
    }

    @Test func importingTwiceIsStale() async throws {
        let (b, level, note) = try await extracted()
        let chain = note.extraction.chains[0]
        let pick = ImportPick(chainId: chain.id, stepIds: [chain.steps[0].id], places: [:])
        _ = try await b.importNote(noteId, parent: level.task.id, picks: [pick])
        await #expect(throws: BackendError.self) {
            _ = try await b.importNote(noteId, parent: level.task.id, picks: [pick])
        }
        #expect(try await b.level(level.task.id).children.count == 1)
    }

    @Test func extractionIsDeterministicAndReusedWhenUnchanged() async throws {
        let (b, _, note) = try await extracted()
        #expect(note.extraction.chains.map { $0.steps[0].name } == ["先去伏见稻荷", "我来订酒店"])
        #expect(note.extraction.chains[1].steps[0].quote == Quote(startMs: 12000, endMs: 17800))
        let again = try await b.extract(note: noteId)
        #expect(again.extraction == note.extraction)
        _ = try await b.updateNote(noteId, title: nil, durationMs: nil, transcript: [line(0, "去海边")], speakers: nil)
        #expect(try await b.extract(note: noteId).extraction.version == note.extraction.version + 1)
    }

    @Test func emptyTranscriptCannotBeExtracted() async throws {
        let b = InMemoryBackend()
        _ = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: Date())
        await #expect(throws: BackendError.api(status: 400, code: "empty_transcript", message: "empty")) {
            _ = try await b.extract(note: noteId)
        }
    }

    @Test func editingTheDraftChecksTheVersion() async throws {
        let (b, _, note) = try await extracted()
        let ok = try await b.updateExtraction(note: noteId, version: note.extraction.version, chains: [])
        #expect(ok.extraction.version == note.extraction.version + 1)
        await #expect(throws: BackendError.api(status: 409, code: "version_conflict", message: "changed")) {
            _ = try await b.updateExtraction(note: noteId, version: note.extraction.version, chains: [])
        }
    }

    @Test func segmentsNeedATicketAndAddUpDurations() async throws {
        let b = InMemoryBackend()
        _ = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: Date())
        await #expect(throws: BackendError.api(status: 409, code: "segment_missing", message: "not uploaded")) {
            _ = try await b.completeSegment(note: noteId, segment: 0, durationMs: 1000)
        }
        let ticket = try await b.uploadTicket(note: noteId, segment: 0)
        #expect(ticket.uploadUrl.hasPrefix("memory://"))
        _ = try await b.completeSegment(note: noteId, segment: 0, durationMs: 1000)
        _ = try await b.uploadTicket(note: noteId, segment: 1)
        let n = try await b.completeSegment(note: noteId, segment: 1, durationMs: 2500)
        #expect(n.durationMs == 3500)
        #expect(n.segments.map(\.index) == [0, 1])
        #expect(try await b.noteAudio(noteId).segments.map(\.url).allSatisfy { $0.hasPrefix("memory://") })
    }

    @Test func deleteRemovesTheNote() async throws {
        let b = InMemoryBackend()
        _ = try await b.createNote(id: noteId, title: nil, locale: "zh-CN", createdAt: Date())
        try await b.deleteNote(noteId)
        await #expect(throws: BackendError.self) { _ = try await b.note(noteId) }
    }

    @Test func demoSeedsTheKyotoNote() async throws {
        let b = await InMemoryBackend.sample()
        let list = try await b.notes()
        #expect(list.map(\.title) == ["京都讨论"])
        let n = try await b.note(list[0].id)
        #expect(n.transcript.count == 8)
        #expect(n.speakers.count == 3)
        #expect(n.durationMs == 50340)
        let chains = try await b.extract(note: n.id).extraction.chains
        #expect(chains.map(\.name) == ["京都第一天", "京都第二天", "订京都站附近的酒店", "预约二年坂荞麦面店"])
        #expect(chains[0].steps.map(\.name) == ["伏见稻荷大社", "清水寺", "二年坂吃午饭"])
        #expect(chains[0].steps[1].quote == Quote(startMs: 19000, endMs: 24800))
    }
}
