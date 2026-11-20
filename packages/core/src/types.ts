/** 尽早订（限量）/ 行前订 / 现场办 */
export const URGENCIES = ['early', 'before', 'onsite'] as const;
export type Urgency = (typeof URGENCIES)[number];

/** Lower rank = more urgent. Used for prep-list ordering. */
export const URGENCY_RANK: Record<Urgency, number> = { early: 1, before: 2, onsite: 3 };

export interface GeoPoint {
  lat: number;
  lng: number;
}

export interface Prerequisite {
  id: string;
  action: string;
  urgency: Urgency;
  done: boolean;
}

/**
 * Every level of the tree is the same kind of task. `children` order is execution order.
 * A task with no children is a leaf, i.e. a step in run mode.
 */
export interface TaskNode {
  id: string;
  name: string;
  short: string;
  place: string;
  /** Full postal address of the place (from the place search); '' when unknown. */
  address: string;
  lat: number | null;
  lng: number | null;
  completed: boolean;
  prerequisites: Prerequisite[];
  children: TaskNode[];
}

export function hasGeo<T extends { lat: number | null; lng: number | null }>(t: T): t is T & GeoPoint {
  return typeof t.lat === 'number' && typeof t.lng === 'number';
}
