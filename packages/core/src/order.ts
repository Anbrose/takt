/** Move one element; returns a new array. */
export function moveItem<T>(arr: readonly T[], from: number, to: number): T[] {
  const a = arr.slice();
  const [x] = a.splice(from, 1);
  if (x !== undefined) a.splice(to, 0, x);
  return a;
}

/** True when `next` holds exactly the same ids as `existing` (any order, no duplicates). */
export function isPermutation(existing: readonly string[], next: readonly string[]): boolean {
  if (existing.length !== next.length) return false;
  const want = new Set(existing);
  const seen = new Set<string>();
  for (const id of next) {
    if (!want.has(id) || seen.has(id)) return false;
    seen.add(id);
  }
  return true;
}

/**
 * Reorders a subset of `full` in place: the slots occupied by the subset keep their positions,
 * and are refilled with `subsetOrder`. Everything outside the subset stays put.
 * Used by 重排 (only scoped, located tasks move) and by dragging the map's leg list.
 */
export function fillSlots(full: readonly string[], subsetOrder: readonly string[]): string[] {
  const inSubset = new Set(subsetOrder);
  const next = full.slice();
  let j = 0;
  for (let i = 0; i < next.length; i++) {
    if (inSubset.has(next[i]!)) next[i] = subsetOrder[j++]!;
  }
  if (j !== subsetOrder.length) throw new Error('fillSlots: subset contains ids not in full list');
  return next;
}

/** Abbreviation for the drag-time order rail: ASCII names keep 4 chars, others 2 (CJK). */
export function railAbbr(short: string): string {
  return /^[\x00-\x7f]/.test(short) ? short.slice(0, 4) : short.slice(0, 2);
}
