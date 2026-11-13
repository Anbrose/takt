import { and, asc, eq, isNull } from 'drizzle-orm';
import type { TaskNode } from '@takt/core';
import type { Db } from '../db/client.ts';
import { prerequisites, projects, tasks } from '../db/schema.ts';
import { notFound } from '../http.ts';

export type TaskRow = typeof tasks.$inferSelect;

export interface Loaded {
  row: TaskRow;
  node: TaskNode;
  parent: Loaded | null;
}

export interface ProjectTree {
  projectId: string;
  root: Loaded;
  byId: Map<string, Loaded>;
}

/** Loads a whole project tree (projects are small: a trip is tens of tasks). */
export async function loadTree(db: Db, projectId: string): Promise<ProjectTree> {
  const rows = await db
    .select()
    .from(tasks)
    .where(eq(tasks.projectId, projectId))
    .orderBy(asc(tasks.parentId), asc(tasks.position));
  const pres = await db
    .select({ p: prerequisites })
    .from(prerequisites)
    .innerJoin(tasks, eq(tasks.id, prerequisites.taskId))
    .where(eq(tasks.projectId, projectId))
    .orderBy(asc(prerequisites.taskId), asc(prerequisites.position));

  const byId = new Map<string, Loaded>();
  for (const row of rows) {
    byId.set(row.id, {
      row,
      parent: null,
      node: {
        id: row.id,
        name: row.name,
        short: row.short,
        place: row.place,
        lat: row.lat,
        lng: row.lng,
        completed: row.completedAt !== null,
        prerequisites: [],
        children: [],
      },
    });
  }
  for (const { p } of pres) {
    byId.get(p.taskId)?.node.prerequisites.push({
      id: p.id,
      action: p.action,
      urgency: p.urgency,
      done: p.doneAt !== null,
    });
  }
  let root: Loaded | null = null;
  const sorted = [...byId.values()].sort((a, b) => a.row.position - b.row.position);
  for (const l of sorted) {
    if (l.row.parentId === null) root = l;
    else {
      const parent = byId.get(l.row.parentId);
      if (!parent) continue;
      l.parent = parent;
      parent.node.children.push(l.node);
    }
  }
  if (!root) throw notFound('Project');
  return { projectId, root, byId };
}

/** Project id of a task the owner may access, or 404. */
export async function projectOfTask(db: Db, owner: string, taskId: string): Promise<string> {
  const [hit] = await db
    .select({ projectId: tasks.projectId })
    .from(tasks)
    .innerJoin(projects, eq(projects.id, tasks.projectId))
    .where(and(eq(tasks.id, taskId), eq(projects.ownerId, owner)));
  if (!hit) throw notFound('Task');
  return hit.projectId;
}

export async function assertProject(db: Db, owner: string, projectId: string) {
  const [hit] = await db
    .select({ id: projects.id, name: projects.name, createdAt: projects.createdAt, rootTaskId: tasks.id })
    .from(projects)
    .innerJoin(tasks, and(eq(tasks.projectId, projects.id), isNull(tasks.parentId)))
    .where(and(eq(projects.id, projectId), eq(projects.ownerId, owner)));
  if (!hit) throw notFound('Project');
  return hit;
}

/** Loads the tree that contains `taskId` and returns that task, checking ownership. */
export async function loadTask(db: Db, owner: string, taskId: string) {
  const tree = await loadTree(db, await projectOfTask(db, owner, taskId));
  const task = tree.byId.get(taskId);
  if (!task) throw notFound('Task');
  return { tree, task };
}

/** Root first, ending with the task itself. */
export function breadcrumb(l: Loaded) {
  const out: { id: string; name: string }[] = [];
  for (let cur: Loaded | null = l; cur; cur = cur.parent)
    out.unshift({ id: cur.node.id, name: cur.node.name });
  return out;
}
