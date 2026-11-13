import { DEFAULT_OWNER } from '../app.ts';
import { config } from '../config.ts';
import { openDb } from './client.ts';
import { seedTrip } from './seed.ts';

const { db, close } = await openDb({ url: config.databaseUrl, dataDir: config.dataDir });
const { project, ids } = await seedTrip(db, DEFAULT_OWNER);
console.log(`Seeded "${project.name}" project=${project.id} root=${project.rootTaskId} tasks=${ids.size}`);
await close();
