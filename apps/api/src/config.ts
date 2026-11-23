import { fileURLToPath } from 'node:url';

export const config = {
  port: Number(process.env.PORT ?? 3000),
  host: process.env.HOST ?? '127.0.0.1',
  /** Real Postgres when set; otherwise embedded PGlite under apps/api/.data/. */
  databaseUrl: process.env.DATABASE_URL || undefined,
  /** GCS bucket for note audio; unset = in-memory store (dev, tests). */
  notesBucket: process.env.NOTES_BUCKET || undefined,
  dataDir: process.env.PGLITE_DIR ?? fileURLToPath(new URL('../.data/pglite', import.meta.url)),
};
