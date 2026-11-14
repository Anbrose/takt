import trip from '@takt/fixtures/japan-trip.json' with { type: 'json' };
import type { Urgency } from '@takt/core';
import { createTask } from '../routes/levels.ts';
import { createProject } from '../routes/projects.ts';
import type { Db } from './client.ts';

interface FixtureTask {
  key: string;
  name: string;
  short: string;
  place: string;
  address: string;
  lat: number | null;
  lng: number | null;
  prerequisites: { action: string; urgency: string }[];
  children: FixtureTask[];
}

/** Inserts the 日本旅行 sample project. Returns the project and a fixture-key → task-id map. */
export async function seedTrip(db: Db, owner: string) {
  const project = await createProject(db, owner, trip.name);
  const ids = new Map<string, string>();
  const add = async (parentId: string, list: FixtureTask[]) => {
    for (const t of list) {
      const created = await createTask(db, parentId, {
        name: t.name,
        short: t.short,
        place: t.place,
        address: t.address,
        lat: t.lat,
        lng: t.lng,
        prerequisites: t.prerequisites.map((p) => ({ action: p.action, urgency: p.urgency as Urgency })),
      });
      ids.set(t.key, created.id);
      await add(created.id, t.children);
    }
  };
  await add(project.rootTaskId, trip.tasks as FixtureTask[]);
  return { project, ids };
}
