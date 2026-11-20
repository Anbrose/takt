import { haversineKm, routeKm } from './geo.ts';
import { fillSlots } from './order.ts';
import { hasGeo, type GeoPoint } from './types.ts';

/** Up to this many points the shortest path is solved exactly (Held–Karp); beyond, a heuristic. */
export const EXACT_LIMIT = 12;
/** "多绕" is only reported when the current order is worse than best by more than this. */
export const DETOUR_THRESHOLD_KM = 0.05;

export type Cost = (from: number, to: number) => number;

function pathCost(order: readonly number[], cost: Cost): number {
  let total = 0;
  for (let i = 1; i < order.length; i++) total += cost(order[i - 1]!, order[i]!);
  return total;
}

/**
 * Shortest open path over nodes 0..n-1 that starts at node 0 (the fixed 起点) and visits all.
 * Returns node indices in visiting order. `cost` may be asymmetric (e.g. travel time).
 */
export function shortestPathOrder(n: number, cost: Cost): number[] {
  if (n <= 2) return Array.from({ length: n }, (_, i) => i);
  return n <= EXACT_LIMIT ? heldKarp(n, cost) : nearestNeighbourTwoOpt(n, cost);
}

function heldKarp(n: number, cost: Cost): number[] {
  const full = 1 << n;
  const dp = new Float64Array(full * n).fill(Infinity);
  const parent = new Int8Array(full * n).fill(-1);
  dp[1 * n + 0] = 0;
  for (let mask = 1; mask < full; mask += 2) {
    for (let j = 0; j < n; j++) {
      const cur = dp[mask * n + j]!;
      if (cur === Infinity) continue;
      for (let k = 1; k < n; k++) {
        if (mask & (1 << k)) continue;
        const nm = mask | (1 << k);
        const v = cur + cost(j, k);
        if (v < dp[nm * n + k]!) {
          dp[nm * n + k] = v;
          parent[nm * n + k] = j;
        }
      }
    }
  }
  const last = full - 1;
  let end = 1;
  for (let j = 2; j < n; j++) if (dp[last * n + j]! < dp[last * n + end]!) end = j;
  const order: number[] = [];
  let mask = last;
  let j = end;
  while (j !== -1) {
    order.push(j);
    const p = parent[mask * n + j]!;
    mask &= ~(1 << j);
    j = p;
  }
  return order.reverse();
}

function nearestNeighbourTwoOpt(n: number, cost: Cost): number[] {
  const order = [0];
  const left = new Set(Array.from({ length: n - 1 }, (_, i) => i + 1));
  while (left.size) {
    const from = order[order.length - 1]!;
    let best = -1;
    for (const k of left) if (best < 0 || cost(from, k) < cost(from, best)) best = k;
    order.push(best);
    left.delete(best);
  }
  let bestCost = pathCost(order, cost);
  let improved = true;
  while (improved) {
    improved = false;
    for (let i = 1; i < n - 1; i++) {
      for (let k = i + 1; k < n; k++) {
        const cand = order.slice(0, i).concat(order.slice(i, k + 1).reverse(), order.slice(k + 1));
        const c = pathCost(cand, cost);
        if (c < bestCost - 1e-9) {
          order.splice(0, n, ...cand);
          bestCost = c;
          improved = true;
        }
      }
    }
  }
  return order;
}

/** Shortest-path order for geo points (first point fixed), straight-line distance. */
export function bestOrder<T extends GeoPoint>(points: readonly T[]): T[] {
  const idx = shortestPathOrder(points.length, (a, b) => haversineKm(points[a]!, points[b]!));
  return idx.map((i) => points[i]!);
}

export interface PlannableTask {
  id: string;
  lat: number | null;
  lng: number | null;
}

export type Leg =
  | { taskId: string; kind: 'start' }
  | { taskId: string; kind: 'leg'; km: number }
  | { taskId: string; kind: 'unlocated' }
  | { taskId: string; kind: 'outOfScope' };

export type RouteStatus = 'needMore' | 'optimal' | 'detour';

export interface LevelRoute {
  /** Ids in scope, in list order. Empty selection means the whole level. */
  scopeIds: string[];
  /** One entry per sibling, list order: distance from the previous located, in-scope task. */
  legs: Leg[];
  /** null while fewer than 2 in-scope tasks have coordinates. */
  totalKm: number | null;
  bestKm: number | null;
  extraKm: number;
  status: RouteStatus;
  /** Full sibling order after 重排 (only located, in-scope tasks move; first one stays). null unless detour. */
  optimizedOrder: string[] | null;
}

/**
 * Route summary for one level. `siblings` must be in current list order (saved or draft).
 * 勾选只决定范围，不决定顺序: `selected` filters, never reorders.
 */
export function planRoute(siblings: readonly PlannableTask[], selected: readonly string[]): LevelRoute {
  const sel = new Set(selected);
  const scoped = sel.size === 0 ? siblings.slice() : siblings.filter((t) => sel.has(t.id));
  const inScope = new Set(scoped.map((t) => t.id));
  const geo = scoped.filter(hasGeo);

  const legs: Leg[] = [];
  let prev: GeoPoint | null = null;
  for (const t of siblings) {
    if (!inScope.has(t.id)) legs.push({ taskId: t.id, kind: 'outOfScope' });
    else if (!hasGeo(t)) legs.push({ taskId: t.id, kind: 'unlocated' });
    else {
      legs.push(
        prev ? { taskId: t.id, kind: 'leg', km: haversineKm(prev, t) } : { taskId: t.id, kind: 'start' },
      );
      prev = t;
    }
  }

  const scopeIds = scoped.map((t) => t.id);
  if (geo.length < 2) {
    return {
      scopeIds,
      legs,
      totalKm: null,
      bestKm: null,
      extraKm: 0,
      status: 'needMore',
      optimizedOrder: null,
    };
  }
  const totalKm = routeKm(geo);
  const best = bestOrder(geo);
  const bestKm = routeKm(best);
  const extraKm = Math.max(0, totalKm - bestKm);
  const detour = geo.length >= 3 && extraKm > DETOUR_THRESHOLD_KM;
  return {
    scopeIds,
    legs,
    totalKm,
    bestKm,
    extraKm,
    status: detour ? 'detour' : 'optimal',
    optimizedOrder: detour
      ? fillSlots(
          siblings.map((t) => t.id),
          best.map((t) => t.id),
        )
      : null,
  };
}
