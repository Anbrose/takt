import { buildApp } from './app.ts';
import { config } from './config.ts';
import { openDb } from './db/client.ts';
import { GcsAudioStore } from './storage/gcs-audio-store.ts';
import { MemoryAudioStore } from './storage/audio-store.ts';

const { db, close } = await openDb({ url: config.databaseUrl, dataDir: config.dataDir });
const audioStore = config.notesBucket ? new GcsAudioStore(config.notesBucket) : new MemoryAudioStore();
const app = buildApp({ db, logger: { level: 'info' }, audioStore });
if (!config.notesBucket) app.log.info('NOTES_BUCKET not set: note audio uses the in-memory store');
if (config.llmProvider === 'fake') app.log.info('LLM_PROVIDER=fake: extraction returns no chains');
app.addHook('onClose', close);
await app.listen({ port: config.port, host: config.host });
for (const sig of ['SIGINT', 'SIGTERM'] as const) process.once(sig, () => void app.close());
