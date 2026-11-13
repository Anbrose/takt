import { and, count, eq, inArray, sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { z } from 'zod';
import { routes, type CreateTask } from '@takt/contract';
import { isPermutation, planRoute, prepList, type TaskNode } from '@takt/core';
import type { Db } from '../db/client.ts';
import { prerequisites, projects, tasks } from '../db/schema.ts';
import { HttpError, notFound, route, type ResolveOwner } from '../http.ts';
import { breadcrumb, loadTask, projectOfTask, type Loaded, type ProjectTree } from '../services/tree.ts';

export function summary(n: TaskNode) {
  return {
    id: n.id,
    name: n.name,
    short: n.short,
    place: n.place,
    lat: n.lat,
    lng: n.lng,
    completed: n.completed,
    prerequisites: n.prerequisites,
    childCount: n.children.length,
  };
}

function level(tree: ProjectTree, l: Loaded) {
  return {
    projectId: tree.projectId,
    task: { id: l.node.id, name: l.node.name },
    breadcrumb: breadcrumb(l),
    version: l.row.childrenVersion,
    children: l.node.children.map(summary),
  };
}

/** Appends a task (with prerequisites) to the end of `parentId`'s children. */
export async function createTask(db: Db, parentId: string, body: z.output<typeof CreateTask>) {
  return db.transaction(async (tx) => {
    // Locks the parent row, so concurrent creates/reorders on this level serialize.
    const [parent] = await tx
      .update(tasks)
      .set({ childrenVersion: sql`${tasks.childrenVersion} + 1`, completedAt: null })
      .where(eq(tasks.id, parentId))
      .returning({ projectId: tasks.projectId });
    if (!parent) throw notFound('Task');
    const [{ n }] = (await tx.select({ n: count() }).from(tasks).where(eq(tasks.parentId, parentId))) as [
      { n: number },
    ];
    const [row] = await tx
      .insert(tasks)
      .values({
        projectId: parent.projectId,
        parentId,
        position: n,
        name: body.name,
        short: body.short ?? body.name,
        place: body.place ?? '',
        lat: body.lat ?? null,
        lng: body.lng ?? null,
      })
      .returning();
    const pres = body.prerequisites?.length
      ? await tx
          .insert(prerequisites)
          .values(
            body.prerequisites.map((p, i) => ({
              taskId: row!.id,
              position: i,
              action: p.action,
              urgency: p.urgency ?? 'before',
            })),
          )
          .returning()
      : [];
    return {
      id: row!.id,
      name: row!.name,
      short: row!.short,
      place: row!.place,
      lat: row!.lat,
      lng: row!.lng,
      completed: false,
      prerequisites: pres
        .sort((a, b) => a.position - b.position)
        .map((p) => ({ id: p.id, action: p.action, urgency: p.urgency, done: false })),
      childCount: 0,
    };
  });
}

function parseScope(raw: string | undefined, children: readonly TaskNode[]): string[] {
  const ids = (raw ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const known = new Set(children.map((c) => c.id));
  const unknown = ids.filter((id) => !known.has(id));
  if (unknown.length)
    throw new HttpError(400, 'unknown_scope', `Not children of this task: ${unknown.join(', ')}`);
  return ids;
}

export function levelRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner) {
  route(app, owner, routes.getLevel, async ({ owner, params }) => {
    const { tree, task } = await loadTask(db, owner, params.taskId);
    return level(tree, task);
  });

  route(app, owner, routes.createTask, async ({ owner, params, body }) => {
    await projectOfTask(db, owner, params.taskId);
    return createTask(db, params.taskId, body);
  });

  route(app, owner, routes.reorderLevel, async ({ owner, params, body }) => {
    await projectOfTask(db, owner, params.taskId);
    await db.transaction(async (tx) => {
      const [bumped] = await tx
        .update(tasks)
        .set({ childrenVersion: sql`${tasks.childrenVersion} + 1` })
        .where(and(eq(tasks.id, params.taskId), eq(tasks.childrenVersion, body.version)))
        .returning({ id: tasks.id });
      if (!bumped) throw new HttpError(409, 'version_conflict', 'This level changed since it was loaded');
      const current = await tx.select({ id: tasks.id }).from(tasks).where(eq(tasks.parentId, params.taskId));
      if (
        !isPermutation(
          current.map((c) => c.id),
          body.ids,
        )
      ) {
        throw new HttpError(400, 'not_a_permutation', 'ids must list every child of this task exactly once');
      }
      for (const [i, id] of body.ids.entries()) {
        await tx.update(tasks).set({ position: i }).where(eq(tasks.id, id));
      }
    });
    const { tree, task } = await loadTask(db, owner, params.taskId);
    return level(tree, task);
  });

  route(app, owner, routes.getLevelPlan, async ({ owner, params, query }) => {
    const { task } = await loadTask(db, owner, params.taskId);
    const children = task.node.children;
    const scope = parseScope(query.scope, children);
    const r = planRoute(children, scope);
    const inScope = new Set(r.scopeIds);
    const prep = prepList(children.filter((c) => inScope.has(c.id)));
    return {
      taskId: task.node.id,
      objective: query.objective ?? 'time',
      travel: query.travel ?? 'transit',
      scopeIds: r.scopeIds,
      route: {
        legs: r.legs.map((l) => ({ taskId: l.taskId, kind: l.kind, km: l.kind === 'leg' ? l.km : null })),
        totalKm: r.totalKm,
        bestKm: r.bestKm,
        extraKm: r.extraKm,
        status: r.status,
        optimizedOrder: r.optimizedOrder,
      },
      prep,
    };
  });

  route(app, owner, routes.updatePrerequisite, async ({ owner, params, body }) => {
    const owned = db
      .select({ id: tasks.id })
      .from(tasks)
      .innerJoin(projects, eq(projects.id, tasks.projectId))
      .where(eq(projects.ownerId, owner));
    const [p] = await db
      .update(prerequisites)
      .set({ doneAt: body.done ? sql`coalesce(${prerequisites.doneAt}, now())` : null })
      .where(and(eq(prerequisites.id, params.prerequisiteId), inArray(prerequisites.taskId, owned)))
      .returning();
    if (!p) throw notFound('Prerequisite');
    return { id: p.id, action: p.action, urgency: p.urgency, done: p.doneAt !== null };
  });
}
