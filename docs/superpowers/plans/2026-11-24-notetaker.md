# 录音笔记（Note taker）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record long conversations on iOS 26, transcribe them on device with speaker labels, keep the audio in GCS, extract task chains with an LLM, and import picked chains into any Project level.

**Architecture:** Backend gets a `notes` resource (Postgres), an `AudioStore` (GCS resumable uploads + signed reads; in-memory for tests) and an `Extractor` (Vertex AI; fake for tests). iOS gets a new `TaktNotes` target: segmented recorder → per-segment `SpeechTranscriber` → whole-recording FluidAudio diarization → speaker alignment (pure, in `TaktCore`), all persisted locally first and pushed by a sync queue. UI follows canvas artboards approved in Task 1.

**Tech Stack:** Fastify 5 + Zod 4 contract + Drizzle/PGlite; `@google-cloud/storage`; Vertex AI SDK (chosen in Task 6); SwiftUI, AVFoundation, Speech (`SpeechAnalyzer`/`SpeechTranscriber`), FluidAudio (`OfflineDiarizerManager`).

**Spec:** `docs/superpowers/specs/2026-11-23-notetaker-design.md`

## Global Constraints

- Notes UI only on iOS 26+ (`@available(iOS 26, macOS 26, *)`); the rest of the app stays iOS 17. `TaktKit` package platforms stay `.iOS(.v17), .macOS(.v14)`.
- Every UI change is first drawn on the Design canvas `Phone` / `PhoneDark` artboards (https://claude.ai/artifact/P9mddKiiDZTGZtrFjXPLpb) and approved by the user before code; copy the approved files to `design/takt-handoff/prototype/`.
- Minimal text: show only key values (`1:12:05`, chain/step counts, language short name). No captions, no status sentences.
- Motion per `design/guidelines.md`: every transition interpolates; numbers roll or cross-fade; 减少动态效果 respected (`Motion.with`, `.motion`).
- Closed sheets/bars are removed from the view hierarchy, not moved off-screen.
- Contract first: Zod in `packages/contract`, `pnpm openapi` regenerates `packages/contract/openapi.json` and `apps/ios/TaktKit/Sources/TaktAPI/openapi.json`.
- Every query is scoped by `owner_id`.
- Audio never passes through the API; phone ↔ GCS directly. Bucket region `australia-southeast1`. Object path `notes/{ownerId}/{noteId}/{segmentIndex}.m4a`.
- Only transcript text is sent to the LLM. The LLM may run outside Sydney.
- AI output is a draft; nothing is written to a Project until the user confirms an import.
- Local audio is deleted only after the server confirms the segment upload.
- Backend must run with no GCP credentials (memory store + fake extractor) for dev and tests.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **App killed mid-recording / mid-diarization** → on relaunch the note is still listed with every finished segment; unsent work resumes (Task 11 test `resumesAfterRelaunch`).
2. **`POST /notes` retried after a timeout** (same id) → 200 with the same note, no duplicate; same id from another owner → 409 (Task 3 tests).
3. **Import after the draft changed** (re-extract, or a step already imported, or the target level deleted) → 409/404 and nothing written (Task 7 tests).
4. **Offline with the language model not yet downloaded** → recording starts and segments are kept; transcription runs once the model is installed (Task 10 test `queuesTranscriptionUntilModelReady`).
5. **Extract pressed on an empty or unchanged transcript** → 400 `empty_transcript` with no LLM call; unchanged transcript returns the stored draft without counting against limits (Task 6 tests).

---

## File Structure

Backend (`apps/api`):
- `src/db/schema.ts` — add `notes`, `noteSegments`, `llmUsage`
- `src/db/migrations/0002_notes.sql` (+ drizzle meta) — generated
- `src/storage/audio-store.ts` — `AudioStore` interface, `MemoryAudioStore`
- `src/storage/gcs-audio-store.ts` — `GcsAudioStore`
- `src/llm/extractor.ts` — `Extractor` interface, `FakeExtractor`, prompt + chunking + response schema
- `src/llm/vertex-extractor.ts` — the Vertex implementation
- `src/services/notes.ts` — row ↔ contract mapping, hashing, limits
- `src/routes/notes.ts` — all `/notes` routes
- `src/routes/levels.ts` — split `createTask` so it can run inside a caller's transaction
- `src/app.ts`, `src/config.ts`, `src/main.ts` — wire options
- `test/notes.test.ts`
- `scripts/notes-bucket.sh` (repo root `scripts/`)

Contract: `packages/contract/src/schemas.ts`, `routes.ts`.

iOS (`apps/ios/TaktKit`):
- `Sources/TaktCore/SpeakerAlign.swift` — pure alignment
- `Sources/TaktAPI/Backend.swift` — notes methods
- `Sources/TaktNotes/` (new target): `LocalNote.swift`, `NoteStore.swift`, `SegmentRecorder.swift`, `Transcription.swift`, `Diarization.swift`, `NoteSync.swift`, `NoteProcessor.swift`
- `Sources/TaktUI/InMemoryBackend.swift` — notes
- `Sources/TaktUI/NotesModel.swift`, `NotesListScreen.swift`, `RecordingView.swift`, `NoteDetailScreen.swift`, `ImportPicker.swift`
- Tests: `Tests/TaktCoreTests/SpeakerAlignTests.swift`, `Tests/TaktNotesTests/*`, `Tests/TaktUITests/NotesModelTests.swift`, `TaktAppUITests/NotesUITests.swift`
- `Takt.xcodeproj/project.pbxproj` — Info.plist keys, background audio

---

### Task 1: Canvas mockups (gate for Task 13)

Tasks 2–12 do not depend on this and may run in parallel.

**Files:** canvas artboards `Phone.dc.html`, `PhoneDark.dc.html`; copy to `design/takt-handoff/prototype/`.

- [ ] **Step 1:** Read the canvas (Artifact `read`), add these states to both artboards:
  - 笔记 entry next to the Project list (placement is a design choice; propose one).
  - Notes list: title (start time), duration, a dot/count for undrafted chains; swipe-left delete like task rows; floating + = start recording.
  - Recording: elapsed time, stop button, language chip (`中` `日` `EN` …) that opens a picker; a state for "language model downloading".
  - Note detail: transcript lines with speaker chips (tap chip → rename), 提取 button, chain drafts (rename / delete / reorder steps, delete chain), per-step tap → jumps transcript + plays audio from `quote.startMs`; imported steps shown dimmed with the target name.
  - Import: pick Project → drill into levels → 选这里; step checkboxes to import part of a chain.
- [ ] **Step 2:** Publish; ask the user to approve. **Stop here until approved.**
- [ ] **Step 3:** Copy approved files to `design/takt-handoff/prototype/`, commit `Design: notes screens on canvas`.

---

### Task 2: Contract — notes schemas and routes

**Files:** Modify `packages/contract/src/schemas.ts`, `packages/contract/src/routes.ts`; regenerate both `openapi.json`.

**Interfaces — Produces** (Zod, `.meta({ id })` = the name):

```ts
TranscriptLine  { startMs: int≥0, endMs: int≥0, text: string(max 5000), speaker: string|null }
Speaker         { id: string(1..20), name: string trim(1..40) }
Quote           { startMs: int≥0, endMs: int≥0 }
ChainStep       { id: uuid, name: string trim(1..200), place: string(max 200)|null, quote: Quote }
Chain           { id: uuid, name: string trim(1..200), steps: ChainStep[] (1..100) }
Extraction      { version: int≥0, chains: Chain[] (max 50) }
ImportedStep    { chainName, stepName, taskId: uuid, parentTaskId: uuid, importedAt: datetime }
NoteSegment     { index: int 0..999, durationMs: int≥0, uploaded: boolean }
NoteSummary     { id: uuid, title, locale, durationMs, createdAt: datetime, hasTranscript: boolean, chainCount: int, importedCount: int }
Note            NoteSummary & { transcript: TranscriptLine[], speakers: Speaker[], segments: NoteSegment[], extraction: Extraction, imported: ImportedStep[] }
NoteList        { notes: NoteSummary[] }
CreateNote      { id: uuid, title?: string trim(1..100), locale: string(2..20), createdAt?: datetime }
UpdateNote      { title?, durationMs?: int≥0, transcript?: TranscriptLine[] (max 20000), speakers?: Speaker[] (max 20) }
UpdateExtraction{ version: int≥0, chains: Chain[] (max 50) }
CompleteSegment { durationMs: int≥0 }
UploadTicket    { uploadUrl: url, expiresAt: datetime }
AudioUrls       { segments: { index, durationMs, url, expiresAt }[] }
PickedPlace     { place: string(max 200), address: string(max 300), lat: Lat, lng: Lng }
ImportPick      { chainId: uuid, stepIds: uuid[] (1..100), places?: Record<uuid, PickedPlace> }
ImportNote      { parentTaskId: uuid, picks: ImportPick[] (1..50) }
ImportResult    { level: Level, note: Note }
DeletedNote     { id: uuid }
NoteParams      { noteId: uuid }
SegmentParams   { noteId: uuid, index: z.coerce.number().int().min(0).max(999) }
```

Routes (`operationId`, method, path, body → response, status, errors):

| op | | path | body | response | status | errors |
|---|---|---|---|---|---|---|
| listNotes | GET | /notes | | NoteList | 200 | [] |
| createNote | POST | /notes | CreateNote | Note | 200 | [400, 409] |
| getNote | GET | /notes/{noteId} | | Note | 200 | [404] |
| updateNote | PATCH | /notes/{noteId} | UpdateNote | Note | 200 | [400, 404] |
| deleteNote | DELETE | /notes/{noteId} | | DeletedNote | 200 | [404] |
| uploadSegment | POST | /notes/{noteId}/segments/{index}/upload | | UploadTicket | 200 | [404] |
| completeSegment | POST | /notes/{noteId}/segments/{index}/complete | CompleteSegment | Note | 200 | [404, 409] |
| noteAudio | GET | /notes/{noteId}/audio | | AudioUrls | 200 | [404] |
| extractNote | POST | /notes/{noteId}/extract | | Note | 200 | [400, 404, 429, 502] |
| updateExtraction | PUT | /notes/{noteId}/extraction | UpdateExtraction | Note | 200 | [400, 404, 409] |
| importNote | POST | /notes/{noteId}/import | ImportNote | ImportResult | 200 | [400, 404, 409] |

- [ ] **Step 1:** Add schemas and routes as above.
- [ ] **Step 2:** Run `pnpm openapi && pnpm --filter @takt/contract test && pnpm typecheck` — expected: openapi check up to date, typecheck clean.
- [ ] **Step 3:** Commit `Contract: notes`.

---

### Task 3: Notes table and CRUD routes

**Files:** Modify `apps/api/src/db/schema.ts`, `src/app.ts`; create `src/services/notes.ts`, `src/routes/notes.ts`, migration via `pnpm --filter @takt/api db:generate` (rename to `0002_notes.sql`, keep the journal consistent); test `apps/api/test/notes.test.ts`.

**Interfaces:**
- Consumes: Task 2 routes/schemas.
- Produces:
  - Tables: `notes(id uuid pk — client-supplied, owner_id, title, locale, duration_ms int default 0, transcript jsonb default '[]', speakers jsonb default '[]', transcript_hash text null, extraction jsonb default '{"chains":[]}', extraction_version int default 0, extracted_hash text null, extract_count int default 0, imported jsonb default '[]', created_at, updated_at)`, index `(owner_id, created_at desc)`; `note_segments(note_id fk cascade, index int, duration_ms int, uploaded_at timestamptz null, pk(note_id, index))`; `llm_usage(owner_id, month text 'YYYY-MM', calls int, pk(owner_id, month))`.
  - `services/notes.ts`: `loadNote(db, owner, id): Promise<NoteRow>` (404 `not_found` when missing or other owner), `toNote(row, segments): z.input<typeof Note>`, `toSummary(row): z.input<typeof NoteSummary>`, `transcriptHash(lines): string` (sha256 of `JSON.stringify(lines)`).
  - `AppOptions` gains `audioStore?: AudioStore` and `extractor?: Extractor` (defaults wired in Tasks 4/6; until then route file takes them as params).
- Default title when absent: `createdAt` formatted `YYYY-MM-DD HH:mm` in UTC (client sends its own local title normally).

- [ ] **Step 1: Write failing tests** in `test/notes.test.ts` (same harness as `api.test.ts`: `openDb()`, `buildApp`, `x-test-owner`):

```ts
it('creates a note idempotently by client id', async () => {
  const body = { id: NOTE, locale: 'zh_CN', title: '京都讨论' };
  const a = await call('POST', '/notes', body);
  const b = await call('POST', '/notes', body);
  expect(a.status).toBe(200); expect(b.status).toBe(200);
  expect(b.body).toEqual(a.body);
  expect((await call('GET', '/notes')).body.notes).toHaveLength(1);
});
it('refuses an id owned by someone else', async () => {
  await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
  expect((await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' }, 'other')).status).toBe(409);
  expect((await call('GET', `/notes/${NOTE}`, undefined, 'other')).status).toBe(404);
});
it('stores transcript, speakers, duration; lists newest first', …)
  // PATCH transcript [{startMs:0,endMs:1200,text:'你好',speaker:'S1'}], speakers [{id:'S1',name:'我'}]
  // → GET returns them; hasTranscript true; second note created later appears first in GET /notes
it('deletes a note', …) // DELETE → {id}; GET → 404
```

- [ ] **Step 2:** `pnpm --filter @takt/api test -- notes` — expected FAIL (404 routes).
- [ ] **Step 3:** Implement schema, migration, `services/notes.ts`, routes `listNotes`, `createNote` (insert … on conflict do nothing, then load; other owner → 409 `note_id_taken`), `getNote`, `updateNote` (writing `transcript` also updates `transcript_hash`), `deleteNote` (DB delete; storage cleanup added in Task 4).
- [ ] **Step 4:** Run tests — PASS; `pnpm typecheck && pnpm lint`.
- [ ] **Step 5:** Commit `API: notes table and CRUD`.

---

### Task 4: Audio store, segment upload/complete, playback URLs

**Files:** Create `apps/api/src/storage/audio-store.ts`, `src/storage/gcs-audio-store.ts`; modify `src/routes/notes.ts`, `src/app.ts`, `src/config.ts`, `src/main.ts`, `apps/api/package.json` (`@google-cloud/storage`); test `test/notes.test.ts`.

**Interfaces — Produces:**

```ts
export interface AudioStore {
  /** Starts a GCS resumable session; the returned URL accepts PUTs with no credentials. */
  createUpload(object: string, contentType: 'audio/mp4'): Promise<{ uploadUrl: string; expiresAt: Date }>;
  /** Size in bytes, or null when the object doesn't exist (yet). */
  stat(object: string): Promise<{ size: number } | null>;
  readUrl(object: string, ttlSeconds: number): Promise<{ url: string; expiresAt: Date }>;
  deletePrefix(prefix: string): Promise<void>;
}
export class MemoryAudioStore implements AudioStore { put(object: string, size: number): void /* test helper */ }
export const segmentObject = (owner: string, noteId: string, index: number) => `notes/${owner}/${noteId}/${index}.m4a`;
```

- `GcsAudioStore(bucket: string)`: `file.createResumableUpload({ metadata: { contentType } })` → session URI, `expiresAt` = now + 7 days; `stat` via `file.getMetadata()` (404 → null); `readUrl` via `file.getSignedUrl({ version: 'v4', action: 'read', expires })`; `deletePrefix` via `bucket.deleteFiles({ prefix })`.
- Config: `NOTES_BUCKET` → `GcsAudioStore`, else `MemoryAudioStore` with a startup log line. Read URL TTL 1 hour.
- `completeSegment`: `stat` → null ⇒ 409 `segment_missing`; else upsert `note_segments` with `duration_ms`, `uploaded_at = now()`; note `duration_ms` = sum of segment durations.
- `deleteNote` also calls `deletePrefix('notes/{owner}/{id}/')` after the DB delete.

- [ ] **Step 1: Failing tests:**
  - `issues an upload URL for a segment, then marks it uploaded` — upload → `uploadUrl` string; complete before `store.put` → 409 `segment_missing`; after `store.put(segmentObject('local', NOTE, 0), 1000)` complete `{durationMs: 300000}` → `segments: [{index:0, durationMs:300000, uploaded:true}]`, `durationMs: 300000`.
  - `returns read URLs only for uploaded segments, in order`.
  - `deleting a note removes its audio` — `store.stat(...)` null after DELETE.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement (`buildApp({ audioStore })`, default `new MemoryAudioStore()`).
- [ ] **Step 4:** Run tests, typecheck, lint — PASS.
- [ ] **Step 5:** Commit `API: note audio in GCS`.

---

### Task 5: Bucket and IAM script

**Files:** Create `scripts/notes-bucket.sh`; modify `docs/decisions.md` (new section `录音笔记（第六阶段，2026-11-24）` — start it here, later tasks append).

- [ ] **Step 1:** Script (env `GCP_PROJECT` required, `REGION` default `australia-southeast1`, `BUCKET` default `${GCP_PROJECT}-takt-notes`): enable `storage.googleapis.com`, `iamcredentials.googleapis.com`, `aiplatform.googleapis.com`; create bucket with uniform access + public access prevention; grant the Cloud Run default compute SA `roles/storage.objectAdmin` on the bucket and `roles/iam.serviceAccountTokenCreator` on itself (for v4 signing); print `NOTES_BUCKET=…`. Idempotent (describe before create). If `scripts/deploy-api.sh` exists on `main` by then, add `--set-env-vars NOTES_BUCKET=…` there instead of documenting it.
- [ ] **Step 2:** `bash -n scripts/notes-bucket.sh` — no output. Do **not** run it against GCP without the user.
- [ ] **Step 3:** Commit `Infra: notes bucket script`.

---

### Task 6: Extraction (LLM) with limits

**Files:** Create `apps/api/src/llm/extractor.ts`, `src/llm/vertex-extractor.ts`; modify `src/routes/notes.ts`, `src/config.ts`, `src/app.ts`, `package.json`; tests in `test/notes.test.ts` and `test/extractor.test.ts`.

**Interfaces — Produces:**

```ts
export interface ExtractInput { locale: string; speakers: Speaker[]; lines: TranscriptLine[] }
export interface DraftChain { name: string; steps: { name: string; place: string | null; quote: { startMs: number; endMs: number } }[] }
export interface Extractor { extract(input: ExtractInput): Promise<DraftChain[]> }
export class FakeExtractor implements Extractor { calls: ExtractInput[]; constructor(result: DraftChain[] | Error) }
export function renderTranscript(lines: TranscriptLine[], speakers: Speaker[]): string // "[03:12–03:18] 小林: …" per line
export function chunkLines(lines: TranscriptLine[], maxChars = 30_000): TranscriptLine[][] // split on line boundaries
export const DraftSchema: z.ZodType<{ chains: DraftChain[] }> // structured-output schema sent to the model
```

- Prompt (system, Chinese is fine): extract only actions actually said; each chain = ordered steps toward one goal; step `name` short imperative in the transcript's language; `place` only when a concrete place is named, corrected by context (e.g. 福建造合照社 → 伏见稻荷大社); `quote` = the time range of the supporting line(s); no invented steps; empty `chains` if nothing actionable.
- Route `extractNote` order: empty transcript → 400 `empty_transcript`; `transcript_hash == extracted_hash` → return note unchanged (no call, no count); `extract_count >= NOTE_EXTRACT_LIMIT` (default 10) → 429 `extract_limit`; `llm_usage` calls this month ≥ `LLM_MONTHLY_CALLS` (default 300) → 429 `budget_exceeded`; run `extract` per chunk (each chunk counts one call), concatenate; clamp quotes to `[0, last endMs]`; assign uuids; replace draft (imported list untouched); `extraction_version += 1`, `extracted_hash = transcript_hash`, `extract_count += 1`; extractor error → 502 `llm_failed` (nothing counted except calls actually made).
- Model choice: Step 1 below.

- [ ] **Step 1: Choose the model.** Using test transcripts (the spike's 京都 dialogue text, plus one ~1-hour synthetic transcript built by repeating/varying it), compare Gemini (current Flash/Pro on Vertex) and Claude on Vertex for: chain quality, place correction, structured output, price per 1h transcript, region availability (`australia-southeast1` → else nearest). Record the choice, model id, region and price in `docs/decisions.md`. Ask the user before creating any paid resources; the comparison may run on their existing project with their OK.
- [ ] **Step 2: Failing tests** (`FakeExtractor` via `buildApp({ extractor })`):
  - `refuses to extract an empty transcript` → 400 `empty_transcript`, `fake.calls.length === 0`.
  - `extracts chains with ids and quotes, and does not repeat for the same transcript` → chains/steps have uuids, `extraction.version === 1`; second POST → same body, `fake.calls.length === 1`.
  - `re-extracts after the transcript changes, keeping imported steps` (seed `imported` via an import from Task 7 — mark this test `it.todo` until Task 7, or insert the row directly).
  - `stops at the per-note limit` (env/option limit 2) → third distinct transcript → 429 `extract_limit`.
  - `stops at the monthly budget` → 429 `budget_exceeded`.
  - `maps extractor failures to 502`.
  - `extractor.test.ts`: `chunkLines` keeps order and never splits a line; `renderTranscript` uses speaker names and falls back to the id, and omits the prefix when `speaker` is null.
- [ ] **Step 3:** Run — FAIL.
- [ ] **Step 4:** Implement `extractor.ts`, route logic, config (`LLM_PROVIDER` = `fake` | `vertex`, `VERTEX_PROJECT`, `VERTEX_LOCATION`, `LLM_MODEL`, `NOTE_EXTRACT_LIMIT`, `LLM_MONTHLY_CALLS`); default `fake` returns `[]` with a startup log line.
- [ ] **Step 5:** Implement `vertex-extractor.ts` with the SDK for the chosen model, structured output from `DraftSchema`, `temperature` 0. Add a manual script `apps/api/scripts/try-extract.ts <transcript.json>` for real calls (not in CI).
- [ ] **Step 6:** Tests, typecheck, lint — PASS. Commit `API: extract task chains from notes`.

---

### Task 7: Draft edits and import

**Files:** Modify `apps/api/src/routes/levels.ts` (export `insertTask(tx, parentId, body)` used by `createTask`), `src/routes/notes.ts`; tests `test/notes.test.ts`.

**Interfaces:**
- Consumes: `CreateTask` body shape; seeded trip (`seedTrip`) for target levels.
- Produces: `insertTask(tx: Tx, parentId: string, body: z.output<typeof CreateTask>): Promise<TaskSummaryOut>` — the current body of `createTask` minus `db.transaction`; `createTask` becomes `db.transaction(tx => insertTask(tx, …))`.

Rules:
- `updateExtraction`: `version !== extraction_version` → 409 `version_conflict`; otherwise replace chains, `version + 1`. Server keeps ids the client sends; rejects a step id that's already in `imported` → 400 `already_imported`.
- `importNote` in one transaction: load note `for update`; check parent task belongs to owner (`projectOfTask`) → 404; every picked `chainId`/`stepId` must be in the current draft → else 409 `stale_draft`; per pick, steps in draft order:
  - 1 step → `insertTask(parent, {name: step.name, place, address, lat, lng})`.
  - ≥2 steps → `insertTask(parent, {name: chain.name})`, then each step under it.
  - Place: `places[stepId]` if given, else `{place: step.place ?? ''}` unlocated.
  - Remove imported steps from the draft (drop a chain when empty), append `ImportedStep`s, `extraction_version + 1`.
  - Return `{ level: <parent level>, note }`.

- [ ] **Step 1: Failing tests:**
  - `imports a whole chain as a parent task with ordered children` → parent level gains `京都一日游` with `childCount 3`; its children names in order; note draft empty; `imported` length 3.
  - `imports a single step as a plain task, with a picked place` → task has `address`, `lat`, `lng` from `places`.
  - `imports part of a chain, leaving the rest in the draft`.
  - `refuses stale picks and writes nothing` → re-extract (new ids) then import old ids → 409 `stale_draft`; target level `version` unchanged.
  - `refuses a target in another owner's project` → 404.
  - `rejects an extraction edit from an old version` → 409 `version_conflict`.
  - Finish the Task 6 `it.todo` (re-extract keeps `imported`).
- [ ] **Step 2:** Run — FAIL. **Step 3:** Implement. **Step 4:** All API tests (`pnpm test`), typecheck, lint — PASS.
- [ ] **Step 5:** Commit `API: edit drafts and import chains`.

---

### Task 8: iOS client — backend protocol and in-memory notes

**Files:** Modify `apps/ios/TaktKit/Sources/TaktAPI/Backend.swift`, `Sources/TaktUI/InMemoryBackend.swift`; tests `Tests/TaktAPITests/LiveBackendTests.swift`, `Tests/TaktUITests/InMemoryNotesTests.swift`.

**Interfaces — Produces** (public typealiases for generated schemas, like the existing ones: `Note`, `NoteSummary`, `TranscriptLine`, `Speaker`, `Chain`, `ChainStep`, `ImportPick`, `PickedPlace`, `UploadTicket`, `AudioUrls`):

```swift
// added to protocol TaktBackend
func notes() async throws -> [NoteSummary]
func createNote(id: String, title: String?, locale: String, createdAt: Date) async throws -> Note
func note(_ id: String) async throws -> Note
func updateNote(_ id: String, title: String?, durationMs: Int?, transcript: [TranscriptLine]?, speakers: [Speaker]?) async throws -> Note
func deleteNote(_ id: String) async throws
func uploadTicket(note: String, segment: Int) async throws -> UploadTicket
func completeSegment(note: String, segment: Int, durationMs: Int) async throws -> Note
func noteAudio(_ id: String) async throws -> AudioUrls
func extract(note: String) async throws -> Note
func updateExtraction(note: String, version: Int, chains: [Chain]) async throws -> Note
func importNote(_ id: String, parent: String, picks: [ImportPick]) async throws -> (level: Level, note: Note)
```

`BackendError.code` carries `empty_transcript`, `extract_limit`, `budget_exceeded`, `llm_failed`, `stale_draft`, `version_conflict`.

`InMemoryBackend`: same rules as the server, with a deterministic fake extraction (one chain per speaker turn containing `去`/`订`/`买`, step = that line; used by `-demo` UI tests); upload tickets point to `memory://`. `-demo` seeds one note `京都讨论` with the spike's 8-line transcript and 3 speakers.

- [ ] **Step 1: Failing tests:** LiveBackend decodes a `Note` fixture (copy a real response from Task 7 tests into the test); InMemory: create is idempotent; import of a 2-step chain adds a parent with 2 children to the level; stale ids throw `stale_draft`.
- [ ] **Step 2:** `cd apps/ios/TaktKit && swift test` — FAIL. **Step 3:** Implement. **Step 4:** `swift test` PASS.
- [ ] **Step 5:** Commit `iOS: notes API client`.

---

### Task 9: Speaker alignment (TaktCore)

**Files:** Create `Sources/TaktCore/SpeakerAlign.swift`; test `Tests/TaktCoreTests/SpeakerAlignTests.swift`.

**Interfaces — Produces:**

```swift
public struct TimedText: Equatable, Sendable { public var startMs: Int; public var endMs: Int; public var text: String }
public struct SpeakerTurn: Equatable, Sendable { public var speaker: String; public var startMs: Int; public var endMs: Int }
public struct AlignedLine: Equatable, Sendable { public var startMs: Int; public var endMs: Int; public var text: String; public var speaker: String? }
public enum SpeakerAlign {
    /// Each token → speaker with the most time overlap; no overlap → nearest turn by midpoint;
    /// no turns at all → speaker nil. Consecutive tokens of one speaker merge into a line,
    /// and a line also breaks when the gap to the next token exceeds `maxGapMs` (default 1500).
    public static func align(_ tokens: [TimedText], _ turns: [SpeakerTurn], maxGapMs: Int = 1500) -> [AlignedLine]
}
```

- [ ] **Step 1: Failing tests:** `alternatingSpeakers` (the spike's 8-line timings → 8 lines, speakers S1 S3 S2 S1 S3 S2 S1 S3); `tokenInGapTakesNearestTurn`; `noTurnsGivesNilSpeaker` (lines split only by gap); `longPauseSplitsSameSpeaker`.
- [ ] **Step 2:** `swift test --filter SpeakerAlign` FAIL → **Step 3** implement → **Step 4** PASS.
- [ ] **Step 5:** Commit `Core: align transcript tokens to speakers`.

---

### Task 10: TaktNotes — local store, recorder, transcription, diarization

**Files:** Modify `apps/ios/TaktKit/Package.swift` (dependency `FluidAudio` pinned to an exact released version — check latest tag; target `TaktNotes` deps `TaktCore`, `TaktAPI`, `FluidAudio`; test target `TaktNotesTests`; `TaktUI` depends on `TaktNotes`). Create `Sources/TaktNotes/LocalNote.swift`, `NoteStore.swift`, `SegmentRecorder.swift`, `Transcription.swift`, `Diarization.swift`, `NoteProcessor.swift`. Tests `Tests/TaktNotesTests/NoteStoreTests.swift`, `NoteProcessorTests.swift`.

Try FluidAudio's SwiftPM trait `["Diarizer"]` (tools 6.2) to drop the TTS/94 MB dependency; if it still fails to link (it did in the spike), use the default product and note the size in `docs/decisions.md`.

**Interfaces — Produces:**

```swift
public struct LocalNote: Codable, Equatable, Sendable {
    public var id: UUID; public var title: String; public var locale: String; public var createdAt: Date
    public var segments: [LocalSegment]          // index, durationMs, file name, transcribed: Bool, uploaded: Bool
    public var tokens: [TimedText]               // whole-recording timeline, appended per segment
    public var lines: [AlignedLine]?             // set after diarization + alignment
    public var recording: Bool                   // true until stop() finished writing
    public var synced: SyncState                 // created, transcriptSent: Bool
}
public actor NoteStore {  // Application Support/Notes/{id}/note.json + {index}.m4a
    public init(root: URL)
    public func all() -> [LocalNote]; public func save(_ n: LocalNote) throws
    public func segmentURL(_ id: UUID, _ index: Int) -> URL
    public func deleteAudio(_ id: UUID, _ index: Int) throws; public func delete(_ id: UUID) throws
}
public protocol AudioCapture: AnyObject { func start(segmentURL: @escaping (Int) -> URL, segmentSeconds: Int, onSegment: @escaping (Int, Int) -> Void) throws; func stop() async -> (index: Int, durationMs: Int)? }
public final class SegmentRecorder: AudioCapture   // AVAudioRecorder, AAC mono 16 kHz 32 kbps (builder may tune), 300 s segments,
                                                   // AVAudioSession .record/.spokenAudio, interruption → pause/resume
public protocol Transcribing: Sendable { func transcribe(_ file: URL, locale: String, offsetMs: Int) async throws -> [TimedText]; func isReady(locale: String) async -> Bool; func prepare(locale: String) async throws }
@available(iOS 26, macOS 26, *) public struct AppleTranscriber: Transcribing   // SpeechTranscriber, attributeOptions [.audioTimeRange], per-run tokens (spike code)
public protocol Diarizing: Sendable { func turns(for files: [URL]) async throws -> [SpeakerTurn] }
public struct FluidDiarizer: Diarizing   // concatenates files into one 16 kHz mono temp file, OfflineDiarizerManager.process(url); speakerId → "1","2"… by first appearance
public enum SupportedLanguages { @available(iOS 26, macOS 26, *) public static func all() async -> [Locale] }
public actor NoteProcessor {
    public init(store: NoteStore, transcriber: Transcribing, diarizer: Diarizing)
    /// Transcribes every untranscribed segment (in order) whose model is ready; after recording stopped and all
    /// segments are transcribed, diarizes once and sets `lines`. Safe to call repeatedly (relaunch, model ready, network back).
    public func process(_ id: UUID) async
}
```

- [ ] **Step 1: Failing tests** (fakes for `Transcribing`/`Diarizing`, temp dir store):
  - `NoteStoreTests.roundTrip`, `deleteAudioKeepsNote`.
  - `NoteProcessorTests.transcribesSegmentsWithOffsets` — segment 1 tokens offset by segment 0 duration.
  - `queuesTranscriptionUntilModelReady` — `isReady` false → nothing transcribed, segments kept; flip true → transcribed.
  - `diarizesOnceAfterStop` — while `recording` true no `lines`; after stop exactly one `turns` call; `lines` == `SpeakerAlign.align(tokens, turns)`.
  - `diarizationFailureKeepsUnlabeledLines` — diarizer throws → `lines` with `speaker nil`.
  - `resumesAfterRelaunch` — new `NoteProcessor` on the same store finishes a half-processed note.
- [ ] **Step 2:** `swift test --filter TaktNotesTests` FAIL → **Step 3** implement → **Step 4** PASS.
- [ ] **Step 5:** Host check on the Mac (macOS 26+): a `#if os(macOS)` test `AppleTranscriberHostTests` (skipped unless env `TAKT_SPEECH_HOST=1`) transcribing a bundled 10 s `say`-generated zh_CN fixture → non-empty tokens with increasing times. Run it once with the env set.
- [ ] **Step 6:** Commit `iOS: record, transcribe and diarize notes on device`.

---

### Task 11: Sync queue

**Files:** Create `Sources/TaktNotes/NoteSync.swift`; test `Tests/TaktNotesTests/NoteSyncTests.swift`.

**Interfaces — Produces:**

```swift
public protocol SegmentUploading: Sendable { func upload(_ file: URL, to sessionURL: URL) async throws }  // PUT; on failure query `Content-Range: bytes */<size>` and resume
public struct GCSUploader: SegmentUploading
public actor NoteSync {
    public init(store: NoteStore, backend: any TaktBackend, uploader: SegmentUploading)
    /// In order: createNote (idempotent) → each untouched segment: ticket → upload → completeSegment → delete local file
    /// → once `lines` exist and not sent: updateNote(transcript, speakers, durationMs). Stops at the first network error; safe to re-run.
    public func sync(_ id: UUID) async
    public func syncAll() async
}
```

Speakers sent as `[{id:"1",name:"1"}, …]` (renames later go through `updateNote`).

- [ ] **Step 1: Failing tests** (InMemoryBackend + fake uploader):
  - `syncsInOrderAndDeletesLocalAudio`.
  - `offlineKeepsEverythingAndRetries` — uploader throws → local file kept, `uploaded` false; next `sync` completes.
  - `doesNotDuplicateOnRetryAfterCreate` — backend `createNote` succeeds then the next call fails; re-sync → one note on backend.
  - `sendsTranscriptOnlyAfterLines`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `iOS: sync notes and audio`.

---

### Task 12: NotesModel

**Files:** Create `Sources/TaktUI/NotesModel.swift`; test `Tests/TaktUITests/NotesModelTests.swift`.

**Interfaces — Produces:**

```swift
@MainActor @Observable public final class NotesModel {
    public init(backend: any TaktBackend, store: NoteStore, processor: NoteProcessor, sync: NoteSync, capture: AudioCapture, defaults: UserDefaults = .standard)
    public private(set) var items: [NoteItem]          // server summaries merged with local-only notes, newest first
    public var locale: String                          // persisted under "notes.locale"; default Locale.current if supported
    public private(set) var recording: (id: UUID, startedAt: Date)?
    public var notice: String?
    public func load() async
    public func startRecording() throws                // creates LocalNote, starts capture
    public func stopRecording() async                  // finalizes, then processor.process + sync.sync
    public func open(_ id: UUID) async -> NoteDetailModel
    public func delete(_ id: UUID) async               // optimistic, like LevelModel.delete
}
@MainActor @Observable public final class NoteDetailModel {
    public private(set) var note: Note?
    public func renameSpeaker(_ id: String, to name: String) async
    public func extract() async                         // maps 429 → notice "已达上限", 502 → "提取失败", 400 → nothing
    public func edit(_ chains: [Chain]) async            // PUT extraction; 409 → reload + notice "已在别处修改"
    public func importPicks(_ picks: [ImportPick], into parent: String) async -> Bool
    public func audioURL(at ms: Int) async -> (URL, TimeInterval)?   // segment URL + offset inside it
}
```

- [ ] **Step 1: Failing tests:** `localeRemembered`; `stopRecordingProcessesAndSyncs` (fakes); `localOnlyNoteListedBeforeSync`; `extractLimitShowsNotice`; `staleImportReloads`; `audioURLPicksSegmentAndOffset` (segments 300000 ms each, `ms` 310000 → segment 1, offset 10 s).
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit `iOS: notes model`.

---

### Task 13: Notes screens (per Task 1 canvas)

**Files:** Create `Sources/TaktUI/NotesListScreen.swift`, `RecordingView.swift`, `NoteDetailScreen.swift`, `ImportPicker.swift`; modify `RootView.swift` / `ProjectListScreen.swift` (entry per canvas), `AppRoot.swift` (`-demo` → in-memory notes + fake capture/transcriber/diarizer), `Takt.xcodeproj/project.pbxproj` (both configs: `INFOPLIST_KEY_NSMicrophoneUsageDescription = "录制笔记"`, `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "把录音转成文字"`, `INFOPLIST_KEY_UIBackgroundModes = audio`); UI tests `TaktAppUITests/NotesUITests.swift`.

Accessibility identifiers (tests rely on them): `notes.entry`, `notes.record` (+), `recording.stop`, `recording.locale`, `note.<title>` rows, `note.extract`, `chain.<name>`, `step.<name>`, `import.here`, `delete：<title>` like task rows.

- [ ] **Step 1:** Build the four screens exactly as approved in Task 1 (both themes, minimal text, interpolated transitions, removed-from-hierarchy sheets). Entire notes entry hidden below iOS 26 (`if #available`).
- [ ] **Step 2: UI tests** (simulator, `-demo`): `testRecordStopShowsNote` (fake capture → new row with duration); `testExtractAndImportChain` (open `京都讨论` → 提取 → import first chain into 大阪 → `row.<chain name>` exists in 大阪 with `N 项`); `testImportPartOfChain`; `testSwipeDeleteNote`; `testLocaleChipRemembersChoice`. Screenshots attached like `PlanFlowUITests`.
- [ ] **Step 3:** Run `xcodebuild test -project apps/ios/Takt.xcodeproj -scheme Takt -destination 'platform=iOS Simulator,OS=26.<x>,name=<iPhone>'` (use an iOS 26 simulator id) — all UI tests pass, old ones included. Compare screenshots with the canvas.
- [ ] **Step 4:** Commit `iOS: notes screens`.

---

### Task 14: Wrap-up

- [ ] **Step 1:** `docs/decisions.md` section `录音笔记（第六阶段，2026-11-24）`: data model, offline-first ids, audio path, model/region/price, limits and env vars, FluidAudio size, what's unverified.
- [ ] **Step 2:** Full verification: `pnpm test && pnpm typecheck && pnpm lint && pnpm openapi` (no diff), `swift test`, UI tests on iOS 26 simulator.
- [ ] **Step 3:** Real-device checklist for the user (not automatable): 1–2 h background recording (lock screen, incoming call), battery/heat, Chinese accuracy with a real conversation, `SpeechTranscriber` availability on their phone, GCS upload over cellular, playback seek from a step.
- [ ] **Step 4:** Commit `Docs: note taker decisions`, push the branch, open a PR (merge only when the user says so).
