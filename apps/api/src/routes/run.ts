import { eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { routes } from '@takt/contract';
import { runView, type OwnedPrerequisite, type RunStep, type TaskNode } from '@takt/core';
import type { Db } from '../db/client.ts';
import { tasks } from '../db/schema.ts';
import { HttpError, route, type ResolveOwner } from '../http.ts';
import { assertProject, loadTask, loadTree, type ProjectTree } from '../services/tree.ts';

const crumb = (t: TaskNode) => ({ id: t.id, name: t.name });

function step(s: RunStep) {
  const t = s.task;
  return {
    task: { id: t.id, name: t.name, place: t.place, lat: t.lat, lng: t.lng, prerequisites: t.prerequisites },
    path: s.ancestors.map(crumb),
  };
}

const owned = (p: OwnedPrerequisite) => ({
  taskId: p.taskId,
  taskName: p.taskName,
  prerequisite: p.prerequisite,
});

export function runState(tree: ProjectTree) {
  const v = runView(tree.root.node.children);
  return {
    projectId: tree.projectId,
    total: v.total,
    index: v.index,
    finished: v.finished,
    current: v.current ? step(v.current) : null,
    next: v.next
      ? {
          step: step(v.next.step),
          km: v.next.km,
          stage: v.next.stage
            ? {
                from: v.next.stage.from ? crumb(v.next.stage.from) : null,
                to: v.next.stage.to ? crumb(v.next.stage.to) : null,
              }
            : null,
          prerequisites: v.next.prerequisites.map(owned),
        }
      : null,
    later: v.later.map(step),
    previousTaskId: v.previous?.task.id ?? null,
  };
}

export function runRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner) {
  route(app, owner, routes.getRun, async ({ owner, params }) => {
    await assertProject(db, owner, params.projectId);
    return runState(await loadTree(db, params.projectId));
  });

  const setCompleted = async (owner: string, taskId: string, done: boolean) => {
    const { tree, task } = await loadTask(db, owner, taskId);
    if (task.parent === null || task.node.children.length > 0) {
      throw new HttpError(409, 'not_a_leaf', 'Only leaf tasks are run steps');
    }
    await db
      .update(tasks)
      .set({ completedAt: done ? (task.row.completedAt ?? new Date()) : null })
      .where(eq(tasks.id, taskId));
    task.node.completed = done;
    return runState(tree);
  };

  route(app, owner, routes.completeTask, async ({ owner, params }) =>
    setCompleted(owner, params.taskId, true),
  );
  route(app, owner, routes.reopenTask, async ({ owner, params }) =>
    setCompleted(owner, params.taskId, false),
  );

  route(app, owner, routes.resetRun, async ({ owner, params }) => {
    await assertProject(db, owner, params.projectId);
    await db.update(tasks).set({ completedAt: null }).where(eq(tasks.projectId, params.projectId));
    return runState(await loadTree(db, params.projectId));
  });
}
