import { and, asc, eq, inArray, isNotNull, sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { routes } from '@takt/contract';
import type { Db } from '../db/client.ts';
import { projects, tasks } from '../db/schema.ts';
import { route, type ResolveOwner } from '../http.ts';

const CAP = 20;
const LINES_PER_NOTE = 2;

/** `%`, `_` and `\` are matched literally. */
const likePattern = (q: string) => `%${q.replace(/[\\%_]/g, '\\$&')}%`;

const rowsOf = <T>(r: unknown): T[] => (Array.isArray(r) ? r : (r as { rows: T[] }).rows) as T[];

interface LineHit {
  note_id: string;
  idx: number;
  start_ms: number | null;
  text: string;
}

export function searchRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner) {
  route(app, owner, routes.search, async ({ owner, query }) => {
    const pattern = likePattern(query.q);
    const like = (col: unknown) => sql`${col} ilike ${pattern} escape '\\'`;

    const projectRows = await db
      .select({ id: projects.id, name: projects.name })
      .from(projects)
      .where(and(eq(projects.ownerId, owner), like(projects.name)))
      .orderBy(asc(projects.name), asc(projects.createdAt))
      .limit(CAP);

    const taskRows = await db
      .select({ id: tasks.id, name: tasks.name, projectId: tasks.projectId, parentId: tasks.parentId })
      .from(tasks)
      .innerJoin(projects, eq(projects.id, tasks.projectId))
      .where(and(eq(projects.ownerId, owner), isNotNull(tasks.parentId), like(tasks.name)))
      .orderBy(asc(tasks.name), asc(tasks.position), asc(tasks.id))
      .limit(CAP);

    // Paths: walk up from each hit's parent; the hidden root (parent_id null) is replaced by the project name.
    const projectIds = [...new Set(taskRows.map((t) => t.projectId))];
    const family = projectIds.length
      ? await db
          .select({ id: tasks.id, name: tasks.name, parentId: tasks.parentId, projectId: tasks.projectId })
          .from(tasks)
          .where(inArray(tasks.projectId, projectIds))
      : [];
    const byId = new Map(family.map((t) => [t.id, t]));
    const projectNames = new Map(
      projectIds.length
        ? (
            await db
              .select({ id: projects.id, name: projects.name })
              .from(projects)
              .where(inArray(projects.id, projectIds))
          ).map((p) => [p.id, p.name])
        : [],
    );
    const pathOf = (t: (typeof taskRows)[number]) => {
      const names: string[] = [];
      let cur = byId.get(t.parentId!);
      while (cur && cur.parentId !== null) {
        names.unshift(cur.name);
        cur = byId.get(cur.parentId);
      }
      return [projectNames.get(t.projectId)!, ...names];
    };

    const noteRows = rowsOf<{ id: string; title: string; title_hit: boolean }>(
      await db.execute(sql`
        select n.id, n.title, (n.title ilike ${pattern} escape '\\') as title_hit
        from notes n
        where n.owner_id = ${owner}
          and (n.title ilike ${pattern} escape '\\'
            or exists (select 1 from jsonb_array_elements(n.transcript) e where e->>'text' ilike ${pattern} escape '\\'))
        order by n.created_at desc, n.id desc
        limit ${CAP}`),
    );
    const lines = new Map<string, LineHit[]>();
    if (noteRows.length) {
      const ids = sql.join(
        noteRows.map((n) => sql`${n.id}::uuid`),
        sql`, `,
      );
      const hits = rowsOf<LineHit>(
        await db.execute(sql`
          select n.id as note_id, (t.ord - 1)::int as idx, (t.e->>'startMs')::int as start_ms, t.e->>'text' as text
          from notes n, jsonb_array_elements(n.transcript) with ordinality as t(e, ord)
          where n.owner_id = ${owner} and n.id in (${ids}) and t.e->>'text' ilike ${pattern} escape '\\'
          order by n.id, t.ord`),
      );
      for (const h of hits) {
        const list = lines.get(h.note_id) ?? [];
        if (list.length < LINES_PER_NOTE) list.push(h);
        lines.set(h.note_id, list);
      }
    }

    return {
      projects: projectRows,
      tasks: taskRows.map((t) => ({
        id: t.id,
        name: t.name,
        projectId: t.projectId,
        parentTaskId: t.parentId!,
        path: pathOf(t),
      })),
      notes: noteRows.flatMap((n) => [
        ...(n.title_hit ? [{ noteId: n.id, title: n.title, lineIndex: null, startMs: null, text: n.title }] : []),
        ...(lines.get(n.id) ?? []).map((h) => ({
          noteId: n.id,
          title: n.title,
          lineIndex: h.idx,
          startMs: h.start_ms,
          text: h.text,
        })),
      ]),
    };
  });
}
