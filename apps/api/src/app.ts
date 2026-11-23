import Fastify, { type FastifyServerOptions } from 'fastify';
import type { Db } from './db/client.ts';
import { installErrorHandler, type ResolveOwner } from './http.ts';
import { config } from './config.ts';
import { FakeExtractor, type ExtractLimits, type Extractor } from './llm/extractor.ts';
import { VertexExtractor } from './llm/vertex-extractor.ts';
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
  extractor?: Extractor;
  limits?: ExtractLimits;
}

export function defaultExtractor(): Extractor {
  if (config.llmProvider === 'vertex') {
    if (!config.vertexProject) throw new Error('LLM_PROVIDER=vertex requires VERTEX_PROJECT');
    return new VertexExtractor({
      project: config.vertexProject,
      location: config.vertexLocation,
      model: config.llmModel,
    });
  }
  return new FakeExtractor([]);
}

export function buildApp({
  db,
  resolveOwner = () => DEFAULT_OWNER,
  logger = false,
  audioStore = new MemoryAudioStore(),
  extractor = defaultExtractor(),
  limits = { perNote: config.noteExtractLimit, monthlyCalls: config.llmMonthlyCalls },
}: AppOptions) {
  const app = Fastify({ logger });
  installErrorHandler(app);
  app.get('/health', async () => ({ ok: true }));
  projectRoutes(app, db, resolveOwner);
  levelRoutes(app, db, resolveOwner);
  runRoutes(app, db, resolveOwner);
  noteRoutes(app, db, resolveOwner, audioStore, extractor, limits);
  return app;
}
