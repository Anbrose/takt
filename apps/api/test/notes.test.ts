import { eq } from 'drizzle-orm';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { notes } from '../src/db/schema.ts';
import { transcriptHash } from '../src/services/notes.ts';
import { FakeExtractor, type DraftChain } from '../src/llm/extractor.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';
import { MemoryAudioStore, segmentObject } from '../src/storage/audio-store.ts';

const NOTE = '11111111-1111-4111-8111-111111111111';
const NOTE2 = '22222222-2222-4222-8222-222222222222';

let handle: DbHandle;
let app: ReturnType<typeof buildApp>;
let store: MemoryAudioStore;
let fake: FakeExtractor;
let limits = { perNote: 10, monthlyCalls: 300 };

const CHAIN: DraftChain = {
  name: '京都一日游',
  steps: [
    { name: '去伏见稻荷大社', place: '伏见稻荷大社', quote: { startMs: 0, endMs: 9_999_999 } },
    { name: '吃午饭', place: null, quote: { startMs: 5000, endMs: 4000 } },
  ],
};
const line = (text: string, startMs = 0, endMs = 2000) => ({ startMs, endMs, text, speaker: 'S1' });

beforeEach(async () => {
  handle = await openDb();
  store = new MemoryAudioStore();
  fake = new FakeExtractor([CHAIN]);
  limits = { perNote: 10, monthlyCalls: 300 };
  app = buildApp({
    db: handle.db,
    audioStore: store,
    extractor: fake,
    limits,
    resolveOwner: (req) => (req.headers['x-test-owner'] as string) ?? 'local',
  });
});
afterEach(async () => {
  await app.close();
  await handle.close();
});

async function call(method: string, url: string, payload?: unknown, owner?: string) {
  const res = await app.inject({
    method: method as 'GET',
    url,
    ...(payload === undefined ? {} : { payload: payload as object }),
    headers: owner ? { 'x-test-owner': owner } : {},
  });
  return { status: res.statusCode, body: res.json() };
}

describe('notes CRUD', () => {
  it('creates a note idempotently by client id', async () => {
    const body = { id: NOTE, locale: 'zh_CN', title: '京都讨论' };
    const a = await call('POST', '/notes', body);
    const b = await call('POST', '/notes', body);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(b.body).toEqual(a.body);
    expect((await call('GET', '/notes')).body.notes).toHaveLength(1);
  });

  it('defaults the title to the UTC creation time', async () => {
    const r = await call('POST', '/notes', { id: NOTE, locale: 'en', createdAt: '2026-03-04T05:06:07.000Z' });
    expect(r.body.title).toBe('2026-03-04 05:06');
  });

  it('refuses an id owned by someone else', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    expect((await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' }, 'other')).status).toBe(409);
    expect((await call('GET', `/notes/${NOTE}`, undefined, 'other')).status).toBe(404);
  });

  it('stores transcript, speakers, duration; lists newest first', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN', createdAt: '2026-01-01T00:00:00.000Z' });
    await call('POST', '/notes', { id: NOTE2, locale: 'zh_CN', createdAt: '2026-01-02T00:00:00.000Z' });
    const transcript = [{ startMs: 0, endMs: 1200, text: '你好', speaker: 'S1' }];
    const speakers = [{ id: 'S1', name: '我' }];
    const r = await call('PATCH', `/notes/${NOTE}`, { transcript, speakers, durationMs: 1200, title: 'T' });
    expect(r.status).toBe(200);
    const got = (await call('GET', `/notes/${NOTE}`)).body;
    expect(got).toMatchObject({ transcript, speakers, durationMs: 1200, title: 'T', hasTranscript: true });
    const list = (await call('GET', '/notes')).body.notes;
    expect(list.map((n: { id: string }) => n.id)).toEqual([NOTE2, NOTE]);
    expect(list[1].hasTranscript).toBe(true);
    expect(list[0].hasTranscript).toBe(false);
  });

  it('stores the transcript hash used to detect unchanged transcripts', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    const transcript = [line('你好')];
    await call('PATCH', `/notes/${NOTE}`, { transcript });
    const [row] = await handle.db.select().from(notes).where(eq(notes.id, NOTE));
    expect(row!.transcriptHash).toBe(transcriptHash(transcript));
  });

  it('deletes a note', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    expect((await call('DELETE', `/notes/${NOTE}`, undefined, 'other')).status).toBe(404);
    expect((await call('DELETE', `/notes/${NOTE}`)).body).toEqual({ id: NOTE });
    expect((await call('GET', `/notes/${NOTE}`)).status).toBe(404);
  });
});

describe('note audio', () => {
  const seg = (i: number) => `/notes/${NOTE}/segments/${i}`;

  it('issues an upload URL for a segment, then marks it uploaded', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    const ticket = await call('POST', `${seg(0)}/upload`);
    expect(ticket.status).toBe(200);
    expect(typeof ticket.body.uploadUrl).toBe('string');
    const early = await call('POST', `${seg(0)}/complete`, { durationMs: 300000 });
    expect(early.status).toBe(409);
    expect(early.body.error).toBe('segment_missing');
    store.put(segmentObject('local', NOTE, 0), 1000);
    const done = await call('POST', `${seg(0)}/complete`, { durationMs: 300000 });
    expect(done.status).toBe(200);
    expect(done.body.segments).toEqual([{ index: 0, durationMs: 300000, uploaded: true }]);
    expect(done.body.durationMs).toBe(300000);
  });

  it('refuses upload and complete for someone elses note', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    expect((await call('POST', `${seg(0)}/upload`, undefined, 'other')).status).toBe(404);
    expect((await call('POST', `${seg(0)}/complete`, { durationMs: 1 }, 'other')).status).toBe(404);
  });

  it('returns read URLs only for uploaded segments, in order', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    for (const i of [1, 0]) store.put(segmentObject('local', NOTE, i), 10);
    await call('POST', `${seg(1)}/complete`, { durationMs: 2000 });
    await call('POST', `${seg(0)}/complete`, { durationMs: 1000 });
    const note = (await call('GET', `/notes/${NOTE}`)).body;
    expect(note.durationMs).toBe(3000);
    const audio = await call('GET', `/notes/${NOTE}/audio`);
    expect(audio.status).toBe(200);
    expect(
      audio.body.segments.map((s: { index: number; durationMs: number }) => [s.index, s.durationMs]),
    ).toEqual([
      [0, 1000],
      [1, 2000],
    ]);
    expect(audio.body.segments[0].url).toContain('/0.m4a');
    expect(Date.parse(audio.body.segments[0].expiresAt)).toBeGreaterThan(Date.now());
  });

  it('skips segments that were never completed', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    store.put(segmentObject('local', NOTE, 0), 10);
    await call('POST', `${seg(0)}/complete`, { durationMs: 1000 });
    await call('POST', `${seg(1)}/upload`);
    expect((await call('GET', `/notes/${NOTE}/audio`)).body.segments).toHaveLength(1);
  });

  it('deleting a note removes its audio', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    const object = segmentObject('local', NOTE, 0);
    store.put(object, 10);
    await call('POST', `${seg(0)}/complete`, { durationMs: 1000 });
    await call('DELETE', `/notes/${NOTE}`);
    expect(await store.stat(object)).toBeNull();
  });
});

describe('extraction', () => {
  const extract = () => call('POST', `/notes/${NOTE}/extract`);
  const setTranscript = (...texts: string[]) =>
    call('PATCH', `/notes/${NOTE}`, { transcript: texts.map((t, i) => line(t, i * 3000, i * 3000 + 2000)) });
  beforeEach(async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
  });

  it('refuses to extract an empty transcript', async () => {
    const r = await extract();
    expect(r.status).toBe(400);
    expect(r.body.error).toBe('empty_transcript');
    expect(fake.calls).toHaveLength(0);
  });

  it('extracts chains with ids and clamped quotes, and does not repeat for the same transcript', async () => {
    await setTranscript('先去伏见稻荷大社', '然后吃午饭');
    const a = await extract();
    expect(a.status).toBe(200);
    expect(a.body.extraction.version).toBe(1);
    const chain = a.body.extraction.chains[0];
    expect(chain.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(chain.steps.map((s: { name: string }) => s.name)).toEqual(['去伏见稻荷大社', '吃午饭']);
    expect(chain.steps[0].id).toMatch(/^[0-9a-f-]{36}$/);
    expect(chain.steps[0].quote).toEqual({ startMs: 0, endMs: 5000 });
    expect(chain.steps[1].quote).toEqual({ startMs: 5000, endMs: 5000 });
    expect(fake.calls[0]).toMatchObject({ locale: 'zh_CN', lines: expect.any(Array) });
    const b = await extract();
    expect(b.body).toEqual(a.body);
    expect(fake.calls).toHaveLength(1);
  });

  it('re-extracts after the transcript changes, keeping imported steps', async () => {
    await setTranscript('第一版');
    await extract();
    const imported = {
      chainName: 'c',
      stepName: 's',
      taskId: '33333333-3333-4333-8333-333333333333',
      parentTaskId: '44444444-4444-4444-8444-444444444444',
      importedAt: '2026-11-24T00:00:00.000Z',
    };
    await handle.db
      .update(notes)
      .set({ imported: [imported] })
      .where(eq(notes.id, NOTE));
    await setTranscript('第二版');
    const r = await extract();
    expect(r.body.extraction.version).toBe(2);
    expect(r.body.imported).toEqual([imported]);
    expect(fake.calls).toHaveLength(2);
  });

  it('stops at the per-note limit', async () => {
    limits.perNote = 2;
    for (const t of ['一', '二']) {
      await setTranscript(t);
      expect((await extract()).status).toBe(200);
    }
    await setTranscript('三');
    const r = await extract();
    expect(r.status).toBe(429);
    expect(r.body.error).toBe('extract_limit');
    expect(fake.calls).toHaveLength(2);
  });

  it('stops at the monthly budget, counted per call', async () => {
    limits.monthlyCalls = 1;
    await setTranscript('一');
    expect((await extract()).status).toBe(200);
    await setTranscript('二');
    const r = await extract();
    expect(r.status).toBe(429);
    expect(r.body.error).toBe('budget_exceeded');
    expect(fake.calls).toHaveLength(1);
  });

  it('counts one call per chunk and finishes a run that crosses the budget', async () => {
    limits.monthlyCalls = 2;
    const big = 'x'.repeat(4000);
    await call('PATCH', `/notes/${NOTE}`, {
      transcript: Array.from({ length: 20 }, (_, i) => line(big, i * 3000, i * 3000 + 2000)),
    });
    const r = await extract();
    expect(r.status).toBe(200);
    expect(fake.calls.length).toBeGreaterThan(2);
    expect(r.body.extraction.chains).toHaveLength(fake.calls.length);
  });

  it('maps extractor failures to 502 without recording an extraction', async () => {
    fake = new FakeExtractor(new Error('boom'));
    await app.close();
    app = buildApp({ db: handle.db, audioStore: store, extractor: fake, limits });
    await setTranscript('一');
    const r = await extract();
    expect(r.status).toBe(502);
    expect(r.body.error).toBe('llm_failed');
    const note = (await call('GET', `/notes/${NOTE}`)).body;
    expect(note.extraction.version).toBe(0);
    const [row] = await handle.db.select().from(notes).where(eq(notes.id, NOTE));
    expect(row!.extractCount).toBe(0);
  });

  it('hides other owners notes', async () => {
    await setTranscript('一');
    expect((await call('POST', `/notes/${NOTE}/extract`, undefined, 'other')).status).toBe(404);
  });
});
