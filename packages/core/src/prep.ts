import { URGENCY_RANK, type Prerequisite } from './types.ts';

export interface PrepSource {
  id: string;
  name: string;
  prerequisites: readonly Prerequisite[];
}

export interface PrepItem {
  taskId: string;
  taskName: string;
  prerequisite: Prerequisite;
}

export interface PrepList {
  items: PrepItem[];
  /** Items not yet done. */
  remaining: number;
  /** In-scope tasks that have no prerequisites ("N 项无需准备"). */
  noPrepCount: number;
}

/**
 * 准备清单: the in-scope tasks' own prerequisites (not their descendants'), most urgent first.
 * Ties keep list order (task order, then prerequisite order) — the sort is stable.
 */
export function prepList(scoped: readonly PrepSource[]): PrepList {
  const items: PrepItem[] = [];
  for (const t of scoped) {
    for (const p of t.prerequisites) items.push({ taskId: t.id, taskName: t.name, prerequisite: p });
  }
  items.sort((a, b) => URGENCY_RANK[a.prerequisite.urgency] - URGENCY_RANK[b.prerequisite.urgency]);
  return {
    items,
    remaining: items.filter((i) => !i.prerequisite.done).length,
    noPrepCount: scoped.filter((t) => t.prerequisites.length === 0).length,
  };
}
