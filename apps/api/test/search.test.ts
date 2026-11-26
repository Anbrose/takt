import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';
import { notes } from '../src/db/schema.ts';
import { seedTrip } from '../src/db/seed.ts';
import { createTask } from '../src/routes/levels.ts';
import { createProject } from '../src/routes/projects.ts';

let handle: DbHandle;
let app: ReturnType<typeof buildApp>;
let ids: Map<string, string>;
let rootId: string;

beforeEach(async () => {
  handle = await openDb();
  app = buildApp({
    db: handle.db,
    resolveOwner: (req) => (req.headers['x-test-owner'] as string) ?? 'local',
  });
  const seeded = await seedTrip(handle.db, 'local');
  ids = seeded.ids;
  rootId = seeded.project.rootTaskId;
});
afterEach(async () => {
  await app.close();
  await handle.close();
});

const search = async (q: string, owner?: string) => {
  const res = await app.inject({
    method: 'GET',
    url: `/search?q=${encodeURIComponent(q)}`,
    headers: owner ? { 'x-test-owner': owner } : {},
  });
  return { status: res.statusCode, body: res.json() };
};
const line = (text: string, startMs = 0) => ({ startMs, endMs: startMs + 1000, text, speaker: null });
let n = 0;
const nid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;
async function addNote(title: string, transcript: ReturnType<typeof line>[], owner = 'local', at = new Date()) {
  const id = nid();
  await handle.db.insert(notes).values({ id, ownerId: owner, title, locale: 'zh-CN', transcript, createdAt: at });
  return id;
}

describe('search', () => {
  it('findsProjectTaskAndTranscript', async () => {
    const note = await addNote('周会', [line('先聊预算'), line('下周去大阪玩', 4000)]);
    const { status, body } = await search('大阪');
    expect(status).toBe(200);
    expect(body.projects).toEqual([]);
    expect(body.tasks.map((t: { id: string }) => t.id)).toContain(ids.get('osaka'));
    expect(body.notes).toEqual([{ noteId: note, title: '周会', lineIndex: 1, startMs: 4000, text: '下周去大阪玩' }]);
    const p = await search('日本');
    expect(p.body.projects).toHaveLength(1);
    expect(p.body.projects[0].name).toContain('日本');
  });

  it('taskPathSkipsHiddenRoot', async () => {
    const { body } = await search('大阪城');
    const castle = body.tasks.find((t: { id: string }) => t.id === ids.get('castle'));
    expect(castle.path).toEqual(['日本旅行', '大阪']);
    const osaka = (await search('大阪')).body.tasks.find((t: { id: string }) => t.id === ids.get('osaka'));
    expect(osaka.path).toEqual(['日本旅行']);
    expect(osaka.parentTaskId).toBe(rootId);
  });

  it('twoLinesPerNote', async () => {
    const note = await addNote('访谈', [line('cat 1'), line('x'), line('cat 2', 5), line('cat 3', 6)]);
    const { body } = await search('cat');
    expect(body.notes).toHaveLength(2);
    expect(body.notes.map((h: { lineIndex: number }) => h.lineIndex)).toEqual([0, 2]);
    const both = await addNote('cat 日记', [line('cat a'), line('cat b'), line('cat c')]);
    const r = (await search('cat')).body.notes.filter((h: { noteId: string }) => h.noteId === both);
    expect(r.map((h: { lineIndex: number | null }) => h.lineIndex)).toEqual([null, 0, 1]);
    expect(r[0].text).toBe('cat 日记');
    expect(note).toBeTruthy();
  });

  it('escapesWildcards', async () => {
    const hit = await addNote('折扣', [line('打 50% 折')]);
    await addNote('其他', [line('普通一行')]);
    const { body } = await search('%');
    expect(body.notes.map((h: { noteId: string }) => h.noteId)).toEqual([hit]);
    expect(body.projects).toEqual([]);
    expect(body.tasks).toEqual([]);
    expect((await search('_')).body.notes).toEqual([]);
    expect((await search('\\')).body.notes).toEqual([]);
  });

  it('caseInsensitive', async () => {
    const note = await addNote('Weekly SYNC', [line('Hello World')]);
    const { body } = await search('sync');
    expect(body.notes[0].noteId).toBe(note);
    expect((await search('WORLD')).body.notes[0].text).toBe('Hello World');
  });

  it('capsAt20', async () => {
    const owner = 'bulk';
    const p = await createProject(handle.db, owner, 'zz');
    for (let i = 0; i < 25; i++) {
      await createProject(handle.db, owner, `zz${i}`);
      await createTask(handle.db, p.rootTaskId, { name: `zzt${i}`, short: 'z', place: '', address: '', prerequisites: [] } as never);
      await addNote(`zz note ${i}`, [], owner, new Date(2026, 0, 1, 0, i));
    }
    const { body } = await search('zz', owner);
    expect(body.projects).toHaveLength(20);
    expect(body.tasks).toHaveLength(20);
    expect(body.notes).toHaveLength(20);
    expect(body.notes[0].title).toBe('zz note 24');
  });

  it('ownerScoped', async () => {
    await addNote('私密', [line('大阪')], 'someone');
    const { body } = await search('大阪', 'stranger');
    expect(body).toEqual({ projects: [], tasks: [], notes: [] });
    expect((await search('大阪')).body.notes).toEqual([]);
  });

  it('blankQuery400', async () => {
    expect((await search('   ')).status).toBe(400);
    expect((await search('')).status).toBe(400);
    expect((await search('a'.repeat(101))).status).toBe(400);
  });
});
