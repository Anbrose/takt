import Fastify, { type FastifyServerOptions } from 'fastify';
import type { Db } from './db/client.ts';
import { installErrorHandler, type ResolveOwner } from './http.ts';
import { levelRoutes } from './routes/levels.ts';
import { noteRoutes } from './routes/notes.ts';
import { projectRoutes } from './routes/projects.ts';
import { runRoutes } from './routes/run.ts';
import { MemoryAudioStore, type AudioStore } from './storage/audio-store.ts';

/** Single-user until accounts land: every request acts as this owner. */
export const DEFAULT_OWNER = 'local';

export interface AppOptions {
  db: Db;
  resolveOwner?: ResolveOwner;
  logger?: FastifyServerOptions['logger'];
  audioStore?: AudioStore;
}

export function buildApp({
  db,
  resolveOwner = () => DEFAULT_OWNER,
  logger = false,
  audioStore = new MemoryAudioStore(),
}: AppOptions) {
  const app = Fastify({ logger });
  installErrorHandler(app);
  app.get('/health', async () => ({ ok: true }));
  projectRoutes(app, db, resolveOwner);
  levelRoutes(app, db, resolveOwner);
  runRoutes(app, db, resolveOwner);
  noteRoutes(app, db, resolveOwner, audioStore);
  return app;
}
