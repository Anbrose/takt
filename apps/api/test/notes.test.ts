import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.ts';
import { openDb, type DbHandle } from '../src/db/client.ts';

const NOTE = '11111111-1111-4111-8111-111111111111';
const NOTE2 = '22222222-2222-4222-8222-222222222222';

let handle: DbHandle;
let app: ReturnType<typeof buildApp>;

beforeEach(async () => {
  handle = await openDb();
  app = buildApp({
    db: handle.db,
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

  it('deletes a note', async () => {
    await call('POST', '/notes', { id: NOTE, locale: 'zh_CN' });
    expect((await call('DELETE', `/notes/${NOTE}`, undefined, 'other')).status).toBe(404);
    expect((await call('DELETE', `/notes/${NOTE}`)).body).toEqual({ id: NOTE });
    expect((await call('GET', `/notes/${NOTE}`)).status).toBe(404);
  });
});
