import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import cases from '@takt/fixtures/cases.json' with { type: 'json' };
import { buildApp } from '../src/app.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';
import { seedTrip } from '../src/db/seed.ts';

let handle: DbHandle;
let app: ReturnType<typeof buildApp>;
let ids: Map<string, string>;
let project: { id: string; rootTaskId: string };
const id = (key: string) => ids.get(key)!;

beforeEach(async () => {
  handle = await openDb();
  app = buildApp({
    db: handle.db,
    resolveOwner: (req) => (req.headers['x-test-owner'] as string) ?? 'local',
  });
  ({ ids, project } = await seedTrip(handle.db, 'local'));
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

const level = (taskId: string) => call('GET', `/tasks/${taskId}/children`);
const names = (l: { body: { children: { name: string }[] } }) => l.body.children.map((c) => c.name);

describe('projects & levels', () => {
  it('lists the seeded project with its root task', async () => {
    const r = await call('GET', '/projects');
    expect(r.status).toBe(200);
    expect(r.body.projects).toEqual([
      expect.objectContaining({ id: project.id, name: '日本旅行', rootTaskId: project.rootTaskId }),
    ]);
    expect((await call('GET', `/projects/${project.id}`)).body.name).toBe('日本旅行');
  });

  it('reads one level at a time, any depth, in order', async () => {
    const root = await level(project.rootTaskId);
    expect(names(root)).toEqual(['大阪', '东京', '北海道']);
    expect(root.body.children.map((c: { childCount: number }) => c.childCount)).toEqual([6, 5, 5]);
    expect(root.body.breadcrumb.map((c: { name: string }) => c.name)).toEqual(['日本旅行']);

    const osaka = await level(id('osaka'));
    expect(osaka.body.breadcrumb.map((c: { name: string }) => c.name)).toEqual(['日本旅行', '大阪']);
    expect(osaka.body.children[1]).toMatchObject({
      name: '日本环球影城',
      childCount: 0,
      prerequisites: [
        { action: '购买指定日期入园门票', urgency: 'before', done: false },
        { action: '抢购快速通关券', urgency: 'early', done: false },
      ],
    });
  });

  it('creates a project with an empty first level', async () => {
    const p = await call('POST', '/projects', { name: '  周末  ' });
    expect(p.status).toBe(201);
    expect(p.body.name).toBe('周末');
    expect((await level(p.body.rootTaskId)).body.children).toEqual([]);
    expect((await call('POST', '/projects', { name: '' })).status).toBe(400);
  });
});

describe('新建', () => {
  it('appends at the end of the current level, bumps the version', async () => {
    const before = await level(id('osaka'));
    const r = await call('POST', `/tasks/${id('osaka')}/children`, {
      name: '黑门市场',
      prerequisites: [{ action: '查营业时间' }, { action: '限量券', urgency: 'early' }],
    });
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      name: '黑门市场',
      short: '黑门市场',
      place: '',
      lat: null,
      lng: null,
      childCount: 0,
    });
    expect(r.body.prerequisites.map((p: { urgency: string }) => p.urgency)).toEqual(['before', 'early']);

    const after = await level(id('osaka'));
    expect(names(after).at(-1)).toBe('黑门市场');
    expect(after.body.version).toBe(before.body.version + 1);
  });

  it('works at any depth (a leaf can get children)', async () => {
    const sub = await call('POST', `/tasks/${id('usj')}/children`, { name: '哈利波特园区' });
    expect(sub.status).toBe(201);
    expect((await level(id('usj'))).body.breadcrumb.length).toBe(3);
    expect((await level(id('osaka'))).body.children[1].childCount).toBe(1);
  });

  it('keeps positions unique under concurrent creates', async () => {
    await Promise.all(
      ['a', 'b', 'c', 'd'].map((n) => call('POST', `/tasks/${id('tokyo')}/children`, { name: n })),
    );
    const l = await level(id('tokyo'));
    expect(l.body.children).toHaveLength(9);
    expect(new Set(names(l)).size).toBe(9);
  });

  it('validates input', async () => {
    const post = (b: unknown) => call('POST', `/tasks/${id('osaka')}/children`, b);
    expect((await post({ name: '   ' })).status).toBe(400);
    expect((await post({ name: 'x', lat: 34 })).body.error).toBe('validation');
    expect((await post({ name: 'x', prerequisites: [{ action: 'y', urgency: 'soon' }] })).status).toBe(400);
    expect(
      (await call('POST', `/tasks/00000000-0000-4000-8000-000000000000/children`, { name: 'x' })).status,
    ).toBe(404);
  });
});

describe('保存顺序', () => {
  it('replaces the order of one level', async () => {
    const l = await level(id('osaka'));
    const reversed = [...l.body.children].reverse().map((c: { id: string }) => c.id);
    const r = await call('PUT', `/tasks/${id('osaka')}/children/order`, {
      ids: reversed,
      version: l.body.version,
    });
    expect(r.status).toBe(200);
    expect(r.body.children.map((c: { id: string }) => c.id)).toEqual(reversed);
    expect(r.body.version).toBe(l.body.version + 1);
    expect(names(await level(id('osaka')))[0]).toBe('通天阁');
  });

  it('rejects a stale version with 409', async () => {
    const l = await level(id('osaka'));
    const ids2 = l.body.children.map((c: { id: string }) => c.id);
    await call('POST', `/tasks/${id('osaka')}/children`, { name: '新' });
    const r = await call('PUT', `/tasks/${id('osaka')}/children/order`, {
      ids: ids2,
      version: l.body.version,
    });
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('version_conflict');
  });

  it('rejects a list that is not exactly the children, and changes nothing', async () => {
    const l = await level(id('osaka'));
    const all = l.body.children.map((c: { id: string }) => c.id);
    for (const bad of [all.slice(1), [...all.slice(1), all[1]], [...all.slice(1), id('ghibli')]]) {
      const r = await call('PUT', `/tasks/${id('osaka')}/children/order`, {
        ids: bad,
        version: l.body.version,
      });
      expect(r.status).toBe(400);
      expect(r.body.error).toBe('not_a_permutation');
    }
    const again = await level(id('osaka'));
    expect(again.body.version).toBe(l.body.version);
    expect(names(again)).toEqual(names(l));
  });
});

describe('plan: route + 准备清单', () => {
  const golden = (name: string) => cases.route.find((c) => c.name === name)!;

  it('whole level: distance, detour and the 重排 order match the prototype', async () => {
    const r = await call('GET', `/tasks/${id('osaka')}/plan`);
    expect(r.status).toBe(200);
    const g = golden('osaka');
    expect(r.body.route.totalKm).toBeCloseTo(g.totalKm, 9);
    expect(r.body.route.bestKm).toBeCloseTo(g.bestKm, 9);
    expect(r.body.route.status).toBe('detour');
    expect(r.body.route.optimizedOrder).toEqual(g.bestOrder.map(id));
    expect(r.body.route.legs[0]).toEqual({ taskId: id('castle'), kind: 'start', km: null });
    expect(r.body.objective).toBe('time');
  });

  it('saving the 重排 order makes the level optimal', async () => {
    const plan = await call('GET', `/tasks/${id('osaka')}/plan`);
    const l = await level(id('osaka'));
    await call('PUT', `/tasks/${id('osaka')}/children/order`, {
      ids: plan.body.route.optimizedOrder,
      version: l.body.version,
    });
    const after = await call('GET', `/tasks/${id('osaka')}/plan`);
    expect(after.body.route.status).toBe('optimal');
    expect(after.body.route.extraKm).toBeCloseTo(0, 9);
  });

  it('scope filters but keeps list order; unknown ids are rejected', async () => {
    const scope = [id('kaiyukan'), id('castle'), id('dotonbori')].join(',');
    const r = await call('GET', `/tasks/${id('osaka')}/plan?scope=${scope}&travel=walk`);
    expect(r.body.scopeIds).toEqual([id('castle'), id('dotonbori'), id('kaiyukan')]);
    expect(r.body.travel).toBe('walk');
    expect(r.body.route.totalKm).toBeCloseTo(golden('osaka:subset').totalKm, 9);
    expect(r.body.prep.items.map((i: { taskName: string }) => i.taskName)).toEqual([
      '海游馆',
      '大阪城天守阁',
    ]);
    expect(r.body.prep.noPrepCount).toBe(1);

    expect((await call('GET', `/tasks/${id('osaka')}/plan?scope=${id('ghibli')}`)).body.error).toBe(
      'unknown_scope',
    );
    expect((await call('GET', `/tasks/${id('osaka')}/plan?objective=fast`)).status).toBe(400);
  });

  it('准备清单 order matches the prototype and shares done state with run mode', async () => {
    const l = await level(id('osaka'));
    // cases.prep uses `key:index` ids; map them to real prerequisite ids.
    const preId = new Map<string, string>();
    for (const c of l.body.children) {
      const key = [...ids.entries()].find(([, v]) => v === c.id)![0];
      c.prerequisites.forEach((p: { id: string }, i: number) => preId.set(`${key}:${i}`, p.id));
    }
    const r = await call('GET', `/tasks/${id('osaka')}/plan`);
    const want = cases.prep.find((p) => p.level === 'osaka')!.order.map((k) => preId.get(k));
    expect(r.body.prep.items.map((i: { prerequisite: { id: string } }) => i.prerequisite.id)).toEqual(want);

    const castleTicket = preId.get('castle:0')!;
    const done = await call('PATCH', `/prerequisites/${castleTicket}`, { done: true });
    expect(done.body).toMatchObject({ id: castleTicket, done: true });
    expect((await call('GET', `/tasks/${id('osaka')}/plan`)).body.prep.remaining).toBe(
      r.body.prep.remaining - 1,
    );
    const run = await call('GET', `/projects/${project.id}/run`);
    expect(run.body.current.task.prerequisites[0]).toMatchObject({ id: castleTicket, done: true });

    expect((await call('PATCH', `/prerequisites/${castleTicket}`, { done: false })).body.done).toBe(false);
  });
});

describe('进行中', () => {
  it('walks the plan depth-first and crosses stages', async () => {
    let r = await call('GET', `/projects/${project.id}/run`);
    expect(r.body).toMatchObject({ total: 16, index: 0, finished: false, previousTaskId: null });
    expect(r.body.current.task.name).toBe('大阪城天守阁');
    expect(r.body.current.path).toEqual([{ id: id('osaka'), name: '大阪' }]);
    expect(r.body.next.step.task.name).toBe('日本环球影城');
    expect(r.body.next.km).toBeCloseTo(cases.run.steps[0]!.nextKm!, 9);
    expect(r.body.later.map((s: { task: { name: string } }) => s.task.name)).toEqual([
      '道顿堀',
      '海游馆',
      '梅田蓝天大厦空中庭园',
    ]);

    for (const key of ['castle', 'usj', 'dotonbori', 'kaiyukan', 'umeda']) {
      r = await call('POST', `/tasks/${id(key)}/complete`);
      expect(r.status).toBe(200);
    }
    expect(r.body.current.task.name).toBe('通天阁');
    expect(r.body.next.stage).toEqual({
      from: { id: id('osaka'), name: '大阪' },
      to: { id: id('tokyo'), name: '东京' },
    });
    expect(
      r.body.next.prerequisites.map((p: { prerequisite: { action: string } }) => p.prerequisite.action),
    ).toEqual(['预订东京住宿', '购买大阪→东京新干线车票', '抢购指定日期时段门票']);

    r = await call('DELETE', `/tasks/${r.body.previousTaskId}/complete`);
    expect(r.body.current.task.name).toBe('梅田蓝天大厦空中庭园');

    r = await call('POST', `/projects/${project.id}/run/reset`);
    expect(r.body.index).toBe(0);
  });

  it('follows the saved order and finishes', async () => {
    const l = await level(project.rootTaskId);
    const order = l.body.children.map((c: { id: string }) => c.id).reverse();
    await call('PUT', `/tasks/${project.rootTaskId}/children/order`, { ids: order, version: l.body.version });
    let r = await call('GET', `/projects/${project.id}/run`);
    expect(r.body.current.task.name).toBe('大通公园');
    for (const s of cases.run.sequence) r = await call('POST', `/tasks/${id(s)}/complete`);
    expect(r.body).toMatchObject({ finished: true, index: 16, current: null, next: null });
  });

  it('only leaves are steps', async () => {
    const r = await call('POST', `/tasks/${id('osaka')}/complete`);
    expect(r.status).toBe(409);
    expect(r.body.error).toBe('not_a_leaf');
    expect((await call('POST', `/tasks/${project.rootTaskId}/complete`)).status).toBe(409);
  });
});

describe('ownership & errors', () => {
  it("hides other owners' data behind 404", async () => {
    expect((await call('GET', '/projects', undefined, 'someone-else')).body.projects).toEqual([]);
    expect((await call('GET', `/tasks/${id('osaka')}/children`, undefined, 'someone-else')).status).toBe(404);
    expect((await call('GET', `/projects/${project.id}/run`, undefined, 'someone-else')).status).toBe(404);
    const pre = (await level(id('osaka'))).body.children[0].prerequisites[0].id;
    expect((await call('PATCH', `/prerequisites/${pre}`, { done: true }, 'someone-else')).status).toBe(404);
  });

  it('returns ApiError shapes', async () => {
    expect((await call('GET', '/tasks/not-a-uuid/children')).body).toMatchObject({ error: 'validation' });
    expect((await call('GET', '/nope')).body).toMatchObject({ error: 'not_found' });
  });
});
