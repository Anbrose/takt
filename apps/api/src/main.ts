import { buildApp } from './app.ts';
import { config } from './config.ts';
import { openDb } from './db/client.ts';

const { db, close } = await openDb({ url: config.databaseUrl, dataDir: config.dataDir });
const app = buildApp({ db, logger: { level: 'info' } });
app.addHook('onClose', close);
await app.listen({ port: config.port, host: config.host });
for (const sig of ['SIGINT', 'SIGTERM'] as const) process.once(sig, () => void app.close());
