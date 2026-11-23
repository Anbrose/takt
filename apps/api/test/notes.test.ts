import { eq } from 'drizzle-orm';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { notes } from '../src/db/schema.ts';
import { transcriptHash } from '../src/services/notes.ts';
import { FakeExtractor, type DraftChain } from '../src/llm/extractor.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';
import { seedTrip } from '../src/db/seed.ts';
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
      stepId: '55555555-5555-4555-8555-555555555555',
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

  it('rounds fractional quotes from the model to integers', async () => {
    fake = new FakeExtractor([
      { name: 'c', steps: [{ name: 's', place: null, quote: { startMs: 1000.5, endMs: 2000.7 } }] },
    ]);
    await app.close();
    app = buildApp({ db: handle.db, audioStore: store, extractor: fake, limits });
    await setTranscript('一', '二');
    const r = await extract();
    expect(r.status).toBe(200);
    const q = r.body.extraction.chains[0].steps[0].quote;
    expect(Number.isInteger(q.startMs) && Number.isInteger(q.endMs)).toBe(true);
    expect((await call('GET', `/notes/${NOTE}`)).status).toBe(200);
  });

  it('409s when the draft changed during extraction, 404s when the note was deleted', async () => {
    class Racing extends FakeExtractor {
      constructor(private act: () => Promise<unknown>) {
        super([CHAIN]);
      }
      override async extract(input: Parameters<FakeExtractor['extract']>[0]) {
        await this.act();
        return super.extract(input);
      }
    }
    const rebuild = async (x: FakeExtractor) => {
      await app.close();
      app = buildApp({ db: handle.db, audioStore: store, extractor: x, limits });
    };
    await setTranscript('一');
    await rebuild(
      new Racing(() => handle.db.update(notes).set({ extractionVersion: 5 }).where(eq(notes.id, NOTE))),
    );
    const r = await extract();
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('version_conflict');
    const [row] = await handle.db.select().from(notes).where(eq(notes.id, NOTE));
    expect(row!.extractCount).toBe(0);

    await rebuild(new Racing(() => handle.db.delete(notes).where(eq(notes.id, NOTE))));
    expect((await extract()).status).toBe(404);
  });

  it('hides other owners notes', async () => {
    await setTranscript('一');
    expect((await call('POST', `/notes/${NOTE}/extract`, undefined, 'other')).status).toBe(404);
  });
});

describe('draft edits and import', () => {
  const KYOTO: DraftChain = {
    name: '京都一日游',
    steps: [
      { name: '伏见稻荷', place: '伏见稻荷大社', quote: { startMs: 0, endMs: 1000 } },
      { name: '吃午饭', place: null, quote: { startMs: 1000, endMs: 2000 } },
      { name: '清水寺', place: '清水寺', quote: { startMs: 2000, endMs: 3000 } },
    ],
  };
  const SOLO: DraftChain = {
    name: '买伴手礼',
    steps: [{ name: '买抹茶', place: null, quote: { startMs: 3000, endMs: 4000 } }],
  };
  let ids: Map<string, string>;
  let root: string;
  const id = (key: string) => ids.get(key)!;
  const owner = () => ({
    resolveOwner: (req: { headers: Record<string, unknown> }) =>
      (req.headers['x-test-owner'] as string) ?? 'local',
  });
  const children = async (taskId: string, who?: string) =>
    (await call('GET', `/tasks/${taskId}/children`, undefined, who)).body;
  const extract = () => call('POST', `/notes/${NOTE}/extract`);
  const draft = async () => (await call('GET', `/notes/${NOTE}`)).body;
  const doImport = (body: unknown, who?: string) => call('POST', `/notes/${NOTE}/import`, body, who);

  beforeEach(async () => {
    await app.close();
    fake = new FakeExtractor([KYOTO, SOLO]);
    app = buildApp({ db: handle.db, audioStore: store, extractor: fake, limits, ...owner() });
    const seeded = await seedTrip(handle.db, 'local');
    ids = seeded.ids;
    root = seeded.project.rootTaskId;
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    await call('PATCH', `/notes/${NOTE}`, { transcript: [line('京都')] });
    await extract();
  });

  it('imports a whole chain as a parent task with ordered children', async () => {
    const note = await draft();
    const chain = note.extraction.chains[0];
    const before = (await children(root)).children.length;
    const r = await doImport({
      parentTaskId: root,
      picks: [{ chainId: chain.id, stepIds: chain.steps.map((s: { id: string }) => s.id) }],
    });
    expect(r.status).toBe(200);
    const added = r.body.level.children.at(-1);
    expect(r.body.level.children).toHaveLength(before + 1);
    expect(added).toMatchObject({ name: '京都一日游', childCount: 3 });
    const kids = await children(added.id);
    expect(kids.children.map((c: { name: string }) => c.name)).toEqual(['伏见稻荷', '吃午饭', '清水寺']);
    expect(kids.children[0].place).toBe('伏见稻荷大社');
    expect(kids.children[1].place).toBe('');
    expect(kids.children[1].lat).toBeNull();
    expect(r.body.note.extraction.chains.map((c: { name: string }) => c.name)).toEqual(['买伴手礼']);
    expect(r.body.note.imported).toHaveLength(3);
    expect(r.body.note.imported[0]).toMatchObject({
      chainName: '京都一日游',
      stepName: '伏见稻荷',
      stepId: chain.steps[0].id,
      parentTaskId: added.id,
      taskId: kids.children[0].id,
    });
    expect(r.body.note.extraction.version).toBe(note.extraction.version + 1);
  });

  it('imports a single step as a plain task, with a picked place', async () => {
    const chain = (await draft()).extraction.chains[1];
    const step = chain.steps[0];
    const r = await doImport({
      parentTaskId: id('osaka'),
      picks: [
        {
          chainId: chain.id,
          stepIds: [step.id],
          places: { [step.id]: { place: '辻利', address: '京都市', lat: 35.01, lng: 135.77 } },
        },
      ],
    });
    expect(r.status).toBe(200);
    expect(r.body.level.task.id).toBe(id('osaka'));
    expect(r.body.level.children.at(-1)).toMatchObject({
      name: '买抹茶',
      place: '辻利',
      address: '京都市',
      lat: 35.01,
      lng: 135.77,
      childCount: 0,
    });
    expect(r.body.note.extraction.chains.map((c: { name: string }) => c.name)).toEqual(['京都一日游']);
  });

  it('imports part of a chain, leaving the rest in the draft', async () => {
    const chain = (await draft()).extraction.chains[0];
    const [a, b, c] = chain.steps;
    const r = await doImport({ parentTaskId: root, picks: [{ chainId: chain.id, stepIds: [c.id, a.id] }] });
    expect(r.status).toBe(200);
    const added = r.body.level.children.at(-1);
    expect((await children(added.id)).children.map((x: { name: string }) => x.name)).toEqual([
      '伏见稻荷',
      '清水寺',
    ]);
    const left = r.body.note.extraction.chains[0];
    expect(left.steps.map((s: { id: string }) => s.id)).toEqual([b.id]);
    expect(r.body.note.imported).toHaveLength(2);
  });

  it('refuses stale picks and writes nothing', async () => {
    const old = (await draft()).extraction.chains[0];
    await call('PATCH', `/notes/${NOTE}`, { transcript: [line('改了')] });
    await extract();
    const before = await children(root);
    const r = await doImport({
      parentTaskId: root,
      picks: [{ chainId: old.id, stepIds: [old.steps[0].id] }],
    });
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('stale_draft');
    const after = await children(root);
    expect(after.version).toBe(before.version);
    expect(after.children).toHaveLength(before.children.length);
  });

  it('refuses a pick that is half stale without writing the good half', async () => {
    const chain = (await draft()).extraction.chains[0];
    const before = await children(root);
    const r = await doImport({
      parentTaskId: root,
      picks: [
        { chainId: chain.id, stepIds: [chain.steps[0].id] },
        { chainId: chain.id, stepIds: ['99999999-9999-4999-8999-999999999999'] },
      ],
    });
    expect(r.status).toBe(409);
    expect((await children(root)).version).toBe(before.version);
    expect((await draft()).imported).toHaveLength(0);
  });

  it('refuses a target in another owners project', async () => {
    const chain = (await draft()).extraction.chains[0];
    const pick = { chainId: chain.id, stepIds: [chain.steps[0].id] };
    const theirs = await seedTrip(handle.db, 'other');
    const before = await children(theirs.project.rootTaskId, 'other');
    const r = await doImport({ parentTaskId: theirs.project.rootTaskId, picks: [pick] });
    expect(r.status).toBe(404);
    expect((await children(theirs.project.rootTaskId, 'other')).version).toBe(before.version);
    expect((await draft()).imported).toHaveLength(0);
    expect(
      (await doImport({ parentTaskId: '99999999-9999-4999-8999-999999999999', picks: [pick] })).status,
    ).toBe(404);
  });

  it('refuses to import a step twice and writes nothing', async () => {
    const chain = (await draft()).extraction.chains[0];
    const body = { parentTaskId: root, picks: [{ chainId: chain.id, stepIds: [chain.steps[0].id] }] };
    expect((await doImport(body)).status).toBe(200);
    const before = await children(root);
    const r = await doImport(body);
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('stale_draft');
    expect((await children(root)).version).toBe(before.version);
    expect((await draft()).imported).toHaveLength(1);
  });

  it('rejects an extraction edit from an old version', async () => {
    const n = await draft();
    const r = await call('PUT', `/notes/${NOTE}/extraction`, {
      version: n.extraction.version - 1,
      chains: n.extraction.chains,
    });
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('version_conflict');
  });

  it('replaces the draft, keeping client ids and bumping the version', async () => {
    const n = await draft();
    const chains = [n.extraction.chains[0]];
    chains[0] = { ...chains[0], name: '改名', steps: chains[0].steps.slice(0, 2) };
    const r = await call('PUT', `/notes/${NOTE}/extraction`, { version: n.extraction.version, chains });
    expect(r.status).toBe(200);
    expect(r.body.extraction.version).toBe(n.extraction.version + 1);
    expect(r.body.extraction.chains).toEqual(chains);
    expect(r.body.chainCount).toBe(1);
    expect(
      (await call('PUT', `/notes/${NOTE}/extraction`, { version: n.extraction.version, chains })).status,
    ).toBe(409);
    expect((await call('PUT', `/notes/${NOTE}/extraction`, { version: 1, chains }, 'other')).status).toBe(
      404,
    );
  });

  it('rejects an edit that brings back an imported step', async () => {
    const n = await draft();
    const chain = n.extraction.chains[0];
    const step = chain.steps[0];
    const imp = await doImport({ parentTaskId: root, picks: [{ chainId: chain.id, stepIds: [step.id] }] });
    const r = await call('PUT', `/notes/${NOTE}/extraction`, {
      version: imp.body.note.extraction.version,
      chains: [{ ...chain, steps: [step] }],
    });
    expect(r.status).toBe(400);
    expect(r.body.error).toBe('already_imported');
  });

  it('keeps imported steps across a re-extract', async () => {
    const chain = (await draft()).extraction.chains[0];
    await doImport({ parentTaskId: root, picks: [{ chainId: chain.id, stepIds: [chain.steps[0].id] }] });
    await call('PATCH', `/notes/${NOTE}`, { transcript: [line('第二版')] });
    const r = await extract();
    expect(r.body.imported).toHaveLength(1);
    expect(r.body.imported[0].stepName).toBe('伏见稻荷');
    expect(r.body.extraction.chains.flatMap((c: { steps: unknown[] }) => c.steps)).toHaveLength(4);
  });
});
