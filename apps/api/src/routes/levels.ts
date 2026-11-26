import { and, asc, eq, gte, inArray, isNull, sql } from 'drizzle-orm';
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
    address: n.address,
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
export function createTask(db: Db, parentId: string, body: z.output<typeof CreateTask>) {
  return db.transaction((tx) => insertTask(tx, parentId, body));
}

/** createTask's body, for callers that already hold a transaction. */
export async function insertTask(
  tx: Db,
  parentId: string,
  body: z.output<typeof CreateTask>,
  before?: string,
) {
  // Locks the parent row, so concurrent creates/reorders on this level serialize.
  const [parent] = await tx
    .update(tasks)
    .set({ childrenVersion: sql`${tasks.childrenVersion} + 1`, completedAt: null })
    .where(eq(tasks.id, parentId))
    .returning({ projectId: tasks.projectId });
  if (!parent) throw notFound('Task');
  const at = await slotFor(tx, parentId, before);
  const [row] = await tx
    .insert(tasks)
    .values({
      projectId: parent.projectId,
      parentId,
      position: at,
      name: body.name,
      short: body.short ?? body.name,
      place: body.place ?? '',
      address: body.address ?? '',
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
    address: row!.address,
    lat: row!.lat,
    lng: row!.lng,
    completed: false,
    prerequisites: pres
      .sort((a, b) => a.position - b.position)
      .map((p) => ({ id: p.id, action: p.action, urgency: p.urgency, done: false })),
    childCount: 0,
  };
}

/**
 * Position for a new child of `parentId` (parent already locked): the end, or `before`'s slot
 * with that sibling and the later ones shifted down by one. `before` must be a current child.
 */
async function slotFor(tx: Db, parentId: string, before?: string): Promise<number> {
  const siblings = await tx
    .select({ id: tasks.id, position: tasks.position })
    .from(tasks)
    .where(eq(tasks.parentId, parentId))
    .orderBy(asc(tasks.position));
  if (before === undefined) return siblings.length;
  const idx = siblings.findIndex((s) => s.id === before);
  if (idx < 0)
    throw new HttpError(400, 'bad_before', 'beforeTaskId must be another child of the target parent');
  await tx
    .update(tasks)
    .set({ position: sql`${tasks.position} + 1` })
    .where(and(eq(tasks.parentId, parentId), gte(tasks.position, siblings[idx]!.position)));
  return siblings[idx]!.position;
}

/** Rewrites `ids` to positions 0..n-1, touching only rows whose position changes. */
async function renumber(tx: Db, parentId: string, ids: string[]) {
  const cur = new Map(
    (await tx.select({ id: tasks.id, position: tasks.position }).from(tasks).where(eq(tasks.parentId, parentId))).map(
      (r) => [r.id, r.position],
    ),
  );
  for (const [i, tid] of ids.entries()) {
    if (cur.get(tid) !== i) await tx.update(tasks).set({ position: i }).where(eq(tasks.id, tid));
  }
}

/**
 * Moves task `id` under `parentId` (before `before`, else last) in one transaction. Both levels'
 * `children_version` go up by one (once when the parent is unchanged) and positions stay 0..n-1.
 * Returns the old and new parent ids.
 */
export async function moveTask(tx: Db, owner: string, id: string, parentId: string, before?: string) {
  const projectId = await projectOfTask(tx, owner, id);
  if ((await projectOfTask(tx, owner, parentId)) !== projectId)
    throw new HttpError(400, 'cross_project', 'Tasks can only move within their own project');
  if (before !== undefined) await projectOfTask(tx, owner, before);
  // Serialize moves per project (keeps the tree acyclic), then lock the touched levels by id.
  await tx
    .select({ id: tasks.id })
    .from(tasks)
    .where(and(eq(tasks.projectId, projectId), isNull(tasks.parentId)))
    .for('update');
  const [row] = await tx
    .select({ parentId: tasks.parentId })
    .from(tasks)
    .where(eq(tasks.id, id));
  if (!row) throw notFound('Task');
  if (row.parentId === null) throw new HttpError(400, 'root_task', 'A project root cannot be moved');
  const fromId = row.parentId;
  for (let cur: string | null = parentId; cur !== null; ) {
    if (cur === id) throw new HttpError(400, 'move_into_self', 'A task cannot move into itself');
    const [up] = await tx.select({ parentId: tasks.parentId }).from(tasks).where(eq(tasks.id, cur));
    cur = up?.parentId ?? null;
  }
  const lockIds = [...new Set([fromId, parentId])].sort();
  await tx
    .update(tasks)
    .set({ childrenVersion: sql`${tasks.childrenVersion} + 1` })
    .where(inArray(tasks.id, lockIds));
  const order = async (pid: string) =>
    (
      await tx
        .select({ id: tasks.id })
        .from(tasks)
        .where(eq(tasks.parentId, pid))
        .orderBy(asc(tasks.position))
    ).map((r) => r.id);
  const target = (await order(parentId)).filter((t) => t !== id);
  if (before !== undefined && (before === id || !target.includes(before)))
    throw new HttpError(400, 'bad_before', 'beforeTaskId must be another child of the target parent');
  target.splice(before === undefined ? target.length : target.indexOf(before), 0, id);
  if (fromId === parentId) {
    await renumber(tx, parentId, target);
  } else {
    const rest = (await order(fromId)).filter((t) => t !== id);
    await tx.update(tasks).set({ parentId, position: target.indexOf(id) }).where(eq(tasks.id, id));
    await renumber(tx, fromId, rest);
    await renumber(tx, parentId, target);
  }
  return { fromId, toId: parentId };
}

/** The Level response for a task, read through `db` (pass a transaction to see its writes). */
export async function loadLevel(db: Db, owner: string, taskId: string) {
  const { tree, task } = await loadTask(db, owner, taskId);
  return level(tree, task);
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

  route(app, owner, routes.deleteTask, async ({ owner, params }) => {
    await projectOfTask(db, owner, params.taskId);
    const parentId = await db.transaction(async (tx) => {
      const [row] = await tx
        .select({ parentId: tasks.parentId })
        .from(tasks)
        .where(eq(tasks.id, params.taskId))
        .for('update');
      if (!row) throw notFound('Task');
      if (row.parentId === null)
        throw new HttpError(400, 'cannot_delete_root', 'The project root cannot be deleted');
      // Locks the parent row (like create / reorder) and invalidates saved orders of this level.
      await tx
        .update(tasks)
        .set({ childrenVersion: sql`${tasks.childrenVersion} + 1` })
        .where(eq(tasks.id, row.parentId));
      await tx.delete(tasks).where(eq(tasks.id, params.taskId)); // children + prerequisites cascade
      const rest = await tx
        .select({ id: tasks.id })
        .from(tasks)
        .where(eq(tasks.parentId, row.parentId))
        .orderBy(asc(tasks.position));
      for (const [i, r] of rest.entries()) {
        await tx.update(tasks).set({ position: i }).where(eq(tasks.id, r.id));
      }
      return row.parentId;
    });
    const { tree, task } = await loadTask(db, owner, parentId);
    return level(tree, task);
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

  route(app, owner, routes.moveTask, async ({ owner, params, body }) => {
    const { fromId, toId } = await db.transaction((tx) =>
      moveTask(tx, owner, params.taskId, body.parentTaskId, body.beforeTaskId),
    );
    return { from: await loadLevel(db, owner, fromId), to: await loadLevel(db, owner, toId) };
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
