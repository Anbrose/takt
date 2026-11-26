import { eq } from 'drizzle-orm';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';
import { tasks } from '../src/db/schema.ts';
import { seedTrip } from '../src/db/seed.ts';
import { createTask } from '../src/routes/levels.ts';
import { createProject } from '../src/routes/projects.ts';

let handle: DbHandle;
let app: ReturnType<typeof buildApp>;
let ids: Map<string, string>;
let root: string;
const id = (key: string) => ids.get(key)!;

beforeEach(async () => {
  handle = await openDb();
  app = buildApp({
    db: handle.db,
    resolveOwner: (req) => (req.headers['x-test-owner'] as string) ?? 'local',
  });
  const seeded = await seedTrip(handle.db, 'local');
  ids = seeded.ids;
  root = seeded.project.rootTaskId;
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
const move = (taskId: string, body: unknown, who?: string) => call('POST', `/tasks/${taskId}/move`, body, who);
const names = (l: { children: { name: string }[] }) => l.children.map((c) => c.name);
const level = async (taskId: string) => (await call('GET', `/tasks/${taskId}/children`)).body;

describe('move task', () => {
  it('movesIntoSiblingAsLastChild', async () => {
    const r = await move(id('osaka'), { parentTaskId: id('tokyo') });
    expect(r.status).toBe(200);
    expect(names(r.body.to).at(-1)).toBe('大阪');
    expect(r.body.to.task.id).toBe(id('tokyo'));
    expect(r.body.from.task.id).toBe(root);
    expect(names(r.body.from)).toEqual(['东京', '北海道']);
    expect(names(await level(id('tokyo')))).toHaveLength(6);
  });

  it('movesUpAfterParent', async () => {
    const r = await move(id('castle'), { parentTaskId: root, beforeTaskId: id('tokyo') });
    expect(r.status).toBe(200);
    expect(names(r.body.to)).toEqual(['大阪', '大阪城天守阁', '东京', '北海道']);
    expect(names(r.body.from)).not.toContain('大阪城天守阁');
    expect(r.body.from.children).toHaveLength(5);
  });

  it('repositionsWithinSameParent', async () => {
    const r = await move(id('hokkaido'), { parentTaskId: root, beforeTaskId: id('osaka') });
    expect(r.status).toBe(200);
    expect(names(r.body.from)).toEqual(['北海道', '大阪', '东京']);
    expect(r.body.to).toEqual(r.body.from);
    const again = await move(id('hokkaido'), { parentTaskId: root });
    expect(names(again.body.to)).toEqual(['大阪', '东京', '北海道']);
  });

  it('bumpsVersionOnBothLevels', async () => {
    const f0 = (await level(id('osaka'))).version;
    const t0 = (await level(root)).version;
    const r = await move(id('castle'), { parentTaskId: root });
    expect(r.body.from.version).toBe(f0 + 1);
    expect(r.body.to.version).toBe(t0 + 1);
    const s0 = (await level(root)).version;
    const same = await move(id('osaka'), { parentTaskId: root, beforeTaskId: id('tokyo') });
    expect(same.body.from.version).toBe(s0 + 1);
  });

  it('keepsPositionsContiguous', async () => {
    await move(id('usj'), { parentTaskId: id('tokyo'), beforeTaskId: id('sensoji') });
    for (const key of ['osaka', 'tokyo']) {
      const rows = await handle.db.select().from(tasks).where(eq(tasks.parentId, id(key)));
      expect(rows.map((r) => r.position).sort((a, b) => a - b)).toEqual(rows.map((_, i) => i));
    }
  });

  it('rejectsMoveIntoDescendant', async () => {
    const before = await level(root);
    const a = await move(id('osaka'), { parentTaskId: id('castle') });
    expect(a.status).toBe(400);
    expect(a.body.error).toBe('move_into_self');
    expect((await move(id('osaka'), { parentTaskId: id('osaka') })).body.error).toBe('move_into_self');
    expect(await level(root)).toEqual(before);
    expect(names(await level(id('osaka')))).toHaveLength(6);
  });

  it('rejectsRoot', async () => {
    const r = await move(root, { parentTaskId: id('osaka') });
    expect(r.status).toBe(400);
    expect(r.body.error).toBe('root_task');
  });

  it('rejectsCrossProject', async () => {
    const other = await createProject(handle.db, 'local', '搬家');
    const t = await createTask(handle.db, other.rootTaskId, { name: '打包' });
    const r = await move(id('osaka'), { parentTaskId: t.id });
    expect(r.status).toBe(400);
    expect(r.body.error).toBe('cross_project');
  });

  it('rejectsBadBefore', async () => {
    const notChild = await move(id('osaka'), { parentTaskId: id('tokyo'), beforeTaskId: id('castle') });
    expect(notChild.status).toBe(400);
    expect(notChild.body.error).toBe('bad_before');
    const self = await move(id('osaka'), { parentTaskId: root, beforeTaskId: id('osaka') });
    expect(self.status).toBe(400);
    expect(self.body.error).toBe('bad_before');
    expect(names(await level(root))).toEqual(['大阪', '东京', '北海道']);
  });

  it('otherOwner404', async () => {
    expect((await move(id('osaka'), { parentTaskId: id('tokyo') }, 'mallory')).status).toBe(404);
    const other = await createProject(handle.db, 'mallory', 'x');
    expect((await move(id('osaka'), { parentTaskId: other.rootTaskId })).status).toBe(404);
    expect((await move(id('osaka'), { parentTaskId: id('tokyo'), beforeTaskId: crypto.randomUUID() })).status).toBe(404);
    expect(names(await level(root))).toEqual(['大阪', '东京', '北海道']);
  });
});
