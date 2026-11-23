import { fileURLToPath } from 'node:url';

export const config = {
  port: Number(process.env.PORT ?? 3000),
  host: process.env.HOST ?? '127.0.0.1',
  /** Real Postgres when set; otherwise embedded PGlite under apps/api/.data/. */
  databaseUrl: process.env.DATABASE_URL || undefined,
  /** GCS bucket for note audio; unset = in-memory store (dev, tests). */
  notesBucket: process.env.NOTES_BUCKET || undefined,
  /** `fake` returns no chains (dev, tests); `vertex` calls Gemini on Vertex AI. */
  llmProvider: (process.env.LLM_PROVIDER ?? 'fake') as 'fake' | 'vertex',
  vertexProject: process.env.VERTEX_PROJECT || undefined,
  vertexLocation: process.env.VERTEX_LOCATION ?? 'us-central1',
  llmModel: process.env.LLM_MODEL ?? 'gemini-2.5-flash',
  noteExtractLimit: Number(process.env.NOTE_EXTRACT_LIMIT ?? 10),
  llmMonthlyCalls: Number(process.env.LLM_MONTHLY_CALLS ?? 300),
  dataDir: process.env.PGLITE_DIR ?? fileURLToPath(new URL('../.data/pglite', import.meta.url)),
};
