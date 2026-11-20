import { and, desc, eq, isNull } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { routes } from '@takt/contract';
import type { Db } from '../db/client.ts';
import { projects, tasks } from '../db/schema.ts';
import { route, type ResolveOwner } from '../http.ts';
import { assertProject } from '../services/tree.ts';

export async function createProject(db: Db, owner: string, name: string) {
  return db.transaction(async (tx) => {
    const [p] = await tx.insert(projects).values({ ownerId: owner, name }).returning();
    const [root] = await tx
      .insert(tasks)
      .values({ projectId: p!.id, parentId: null, position: 0, name, short: name })
      .returning({ id: tasks.id });
    return { id: p!.id, name: p!.name, rootTaskId: root!.id, createdAt: p!.createdAt.toISOString() };
  });
}

export function projectRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner) {
  route(app, owner, routes.listProjects, async ({ owner }) => {
    const rows = await db
      .select({ id: projects.id, name: projects.name, createdAt: projects.createdAt, rootTaskId: tasks.id })
      .from(projects)
      .innerJoin(tasks, and(eq(tasks.projectId, projects.id), isNull(tasks.parentId)))
      .where(eq(projects.ownerId, owner))
      .orderBy(desc(projects.createdAt), desc(projects.id));
    return { projects: rows.map((r) => ({ ...r, createdAt: r.createdAt.toISOString() })) };
  });

  route(app, owner, routes.createProject, async ({ owner, body }) => createProject(db, owner, body.name));

  route(app, owner, routes.getProject, async ({ owner, params }) => {
    const p = await assertProject(db, owner, params.projectId);
    return { ...p, createdAt: p.createdAt.toISOString() };
  });

  route(app, owner, routes.updateProject, async ({ owner, params, body }) => {
    const p = await assertProject(db, owner, params.projectId);
    return db.transaction(async (tx) => {
      await tx.update(projects).set({ name: body.name }).where(eq(projects.id, p.id));
      // The hidden root task mirrors the project name (it shows as the run-mode path).
      await tx
        .update(tasks)
        .set({ name: body.name, short: body.name })
        .where(and(eq(tasks.projectId, p.id), isNull(tasks.parentId)));
      return { ...p, name: body.name, createdAt: p.createdAt.toISOString() };
    });
  });

  route(app, owner, routes.deleteProject, async ({ owner, params }) => {
    const p = await assertProject(db, owner, params.projectId);
    // tasks and prerequisites go with it (ON DELETE CASCADE).
    await db.delete(projects).where(eq(projects.id, p.id));
    return { id: p.id };
  });
}
