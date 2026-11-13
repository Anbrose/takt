import { haversineKm } from './geo.ts';
import { hasGeo, type Prerequisite, type TaskNode } from './types.ts';

export interface RunStep {
  task: TaskNode;
  /** Path from the top level down to the leaf's parent (the project root excluded). */
  ancestors: TaskNode[];
}

/** Depth-first expansion to leaves, in list order. Parent tasks are not steps themselves. */
export function flattenLeaves(topLevel: readonly TaskNode[]): RunStep[] {
  const out: RunStep[] = [];
  const walk = (nodes: readonly TaskNode[], path: TaskNode[]) => {
    for (const t of nodes) {
      if (t.children.length === 0) out.push({ task: t, ancestors: path });
      else walk(t.children, [...path, t]);
    }
  };
  walk(topLevel, []);
  return out;
}

export interface OwnedPrerequisite {
  taskId: string;
  taskName: string;
  prerequisite: Prerequisite;
}

export interface StageChange {
  /** The stage being left, null when the next step goes one level deeper inside the same stage. */
  from: TaskNode | null;
  /** The stage being entered, null when the next step is shallower (back to a parent level). */
  to: TaskNode | null;
}

export interface NextStep {
  step: RunStep;
  /** Straight-line km from current to next; null if either lacks coordinates. */
  km: number | null;
  stage: StageChange | null;
  /** 出发前要办: prerequisites of every stage entered (outermost first), then the step's own. */
  prerequisites: OwnedPrerequisite[];
}

export interface RunView {
  total: number;
  /** Index of the current step; equals `total` when everything is done. */
  index: number;
  finished: boolean;
  current: RunStep | null;
  next: NextStep | null;
  /** Up to three steps after `next`. */
  later: RunStep[];
  /** The step "上一项" would reopen, if any. */
  previous: RunStep | null;
}

export const LATER_COUNT = 3;

function own(t: TaskNode): OwnedPrerequisite[] {
  return t.prerequisites.map((p) => ({ taskId: t.id, taskName: t.name, prerequisite: p }));
}

export function describeNext(cur: RunStep, nxt: RunStep): NextStep {
  let k = 0;
  while (
    k < cur.ancestors.length &&
    k < nxt.ancestors.length &&
    cur.ancestors[k]!.id === nxt.ancestors[k]!.id
  )
    k++;
  const same = k === cur.ancestors.length && k === nxt.ancestors.length;
  const entered = nxt.ancestors.slice(k);
  return {
    step: nxt,
    km: hasGeo(cur.task) && hasGeo(nxt.task) ? haversineKm(cur.task, nxt.task) : null,
    stage: same ? null : { from: cur.ancestors[k] ?? null, to: nxt.ancestors[k] ?? null },
    prerequisites: [...entered.flatMap(own), ...own(nxt.task)],
  };
}

/** Run mode state: the current step is the first leaf (in plan order) not yet completed. */
export function runView(topLevel: readonly TaskNode[]): RunView {
  const steps = flattenLeaves(topLevel);
  const found = steps.findIndex((s) => !s.task.completed);
  const index = found < 0 ? steps.length : found;
  const current = steps[index] ?? null;
  const nxt = steps[index + 1];
  return {
    total: steps.length,
    index,
    finished: current === null,
    current,
    next: current && nxt ? describeNext(current, nxt) : null,
    later: steps.slice(index + 2, index + 2 + LATER_COUNT),
    previous: index > 0 ? steps[index - 1]! : null,
  };
}
