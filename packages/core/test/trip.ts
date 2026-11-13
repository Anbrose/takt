import trip from '@takt/fixtures/japan-trip.json' with { type: 'json' };
import type { TaskNode, Urgency } from '../src/index.ts';

interface FixtureTask {
  key: string;
  name: string;
  short: string;
  place: string;
  lat: number | null;
  lng: number | null;
  prerequisites: { action: string; urgency: string }[];
  children: FixtureTask[];
}

/** Fixture trip as TaskNodes. Task ids = fixture keys, prerequisite ids = `key:index` (as in cases.json). */
export function tripTree(): TaskNode[] {
  const conv = (t: FixtureTask): TaskNode => ({
    id: t.key,
    name: t.name,
    short: t.short,
    place: t.place,
    lat: t.lat,
    lng: t.lng,
    completed: false,
    prerequisites: t.prerequisites.map((p, i) => ({
      id: `${t.key}:${i}`,
      action: p.action,
      urgency: p.urgency as Urgency,
      done: false,
    })),
    children: t.children.map(conv),
  });
  return (trip.tasks as FixtureTask[]).map(conv);
}

export function leaf(id: string, extra: Partial<TaskNode> = {}): TaskNode {
  return {
    id,
    name: id,
    short: id,
    place: '',
    lat: null,
    lng: null,
    completed: false,
    prerequisites: [],
    children: [],
    ...extra,
  };
}
