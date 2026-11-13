import Fastify, { type FastifyServerOptions } from 'fastify';
import type { Db } from './db/client.ts';
import { installErrorHandler, type ResolveOwner } from './http.ts';
import { levelRoutes } from './routes/levels.ts';
import { projectRoutes } from './routes/projects.ts';
import { runRoutes } from './routes/run.ts';

/** Single-user until accounts land: every request acts as this owner. */
export const DEFAULT_OWNER = 'local';

export interface AppOptions {
  db: Db;
  resolveOwner?: ResolveOwner;
  logger?: FastifyServerOptions['logger'];
}

export function buildApp({ db, resolveOwner = () => DEFAULT_OWNER, logger = false }: AppOptions) {
  const app = Fastify({ logger });
  installErrorHandler(app);
  app.get('/health', async () => ({ ok: true }));
  projectRoutes(app, db, resolveOwner);
  levelRoutes(app, db, resolveOwner);
  runRoutes(app, db, resolveOwner);
  return app;
}
