import { describe, expect, it } from 'vitest';
import {
  EXACT_LIMIT,
  fillSlots,
  isPermutation,
  moveItem,
  planRoute,
  railAbbr,
  runView,
  shortestPathOrder,
  type Cost,
} from '../src/index.ts';
import { leaf, tripTree } from './trip.ts';

const osaka = () => tripTree().find((t) => t.id === 'osaka')!.children;

describe('order helpers', () => {
  it('moveItem', () => {
    expect(moveItem(['a', 'b', 'c', 'd'], 0, 2)).toEqual(['b', 'c', 'a', 'd']);
    expect(moveItem(['a', 'b', 'c', 'd'], 3, 1)).toEqual(['a', 'd', 'b', 'c']);
  });
  it('isPermutation', () => {
    expect(isPermutation(['a', 'b'], ['b', 'a'])).toBe(true);
    expect(isPermutation(['a', 'b'], ['a', 'a'])).toBe(false);
    expect(isPermutation(['a', 'b'], ['a'])).toBe(false);
    expect(isPermutation(['a', 'b'], ['a', 'c'])).toBe(false);
  });
  it('fillSlots keeps non-subset ids in place', () => {
    expect(fillSlots(['a', 'x', 'b', 'y', 'c'], ['c', 'a', 'b'])).toEqual(['c', 'x', 'a', 'y', 'b']);
    expect(() => fillSlots(['a'], ['z'])).toThrow();
  });
  it('railAbbr', () => {
    expect(railAbbr('teamLab')).toBe('team');
    expect(railAbbr('梅田空中庭园')).toBe('梅田');
  });
});

describe('planRoute', () => {
  it('whole level when nothing selected; detour and 重排 order', () => {
    const r = planRoute(osaka(), []);
    expect(r.scopeIds).toHaveLength(6);
    expect(r.status).toBe('detour');
    expect(r.extraKm).toBeGreaterThan(0.05);
    // Golden best order for the Osaka level (first item fixed).
    expect(r.optimizedOrder).toEqual(['castle', 'umeda', 'dotonbori', 'tsutenkaku', 'usj', 'kaiyukan']);
    expect(r.legs[0]).toEqual({ taskId: 'castle', kind: 'start' });
    expect(r.legs[1]!.kind).toBe('leg');
  });

  it('selection filters but never reorders; out-of-scope tasks keep their slots', () => {
    const r = planRoute(osaka(), ['tsutenkaku', 'usj', 'castle', 'kaiyukan']);
    expect(r.scopeIds).toEqual(['castle', 'usj', 'kaiyukan', 'tsutenkaku']);
    expect(r.legs.find((l) => l.taskId === 'dotonbori')!.kind).toBe('outOfScope');
    expect(r.status).toBe('detour');
    // Prototype bestOrder for this subset: castle→tsutenkaku→usj→kaiyukan, filled into slots 0,1,3,5;
    // dotonbori(2) and umeda(4) stay put.
    expect(r.optimizedOrder).toEqual(['castle', 'tsutenkaku', 'dotonbori', 'usj', 'umeda', 'kaiyukan']);
  });

  it('unlocated tasks are skipped by the route and stay in place on 重排', () => {
    const tasks = [...osaka()];
    tasks.splice(2, 0, leaf('new'));
    const r = planRoute(tasks, []);
    expect(r.legs[2]).toEqual({ taskId: 'new', kind: 'unlocated' });
    expect(r.legs[3]!.kind).toBe('leg'); // distance measured from the previous located task
    expect(r.optimizedOrder![2]).toBe('new');
  });

  it('needs two located tasks; two is never a detour', () => {
    expect(planRoute(osaka(), ['castle']).status).toBe('needMore');
    expect(planRoute(osaka(), ['castle']).totalKm).toBeNull();
    const two = planRoute(osaka(), ['castle', 'usj']);
    expect(two.status).toBe('optimal');
    expect(two.optimizedOrder).toBeNull();
  });
});

describe('shortestPathOrder', () => {
  // Deterministic pseudo-random points.
  const pts = (n: number, seed = 7) => {
    let s = seed;
    const r = () => ((s = (s * 16807) % 2147483647) / 2147483647) * 100;
    return Array.from({ length: n }, () => [r(), r()] as const);
  };
  const euclid =
    (p: readonly (readonly [number, number])[]): Cost =>
    (a, b) =>
      Math.hypot(p[a]![0] - p[b]![0], p[a]![1] - p[b]![1]);
  const len = (o: number[], c: Cost) => o.slice(1).reduce((s, v, i) => s + c(o[i]!, v), 0);
  const brute = (n: number, c: Cost) => {
    let best = Infinity;
    const walk = (done: number[], rest: number[]) => {
      if (!rest.length) best = Math.min(best, len(done, c));
      rest.forEach((v, i) => walk([...done, v], [...rest.slice(0, i), ...rest.slice(i + 1)]));
    };
    walk(
      [0],
      Array.from({ length: n - 1 }, (_, i) => i + 1),
    );
    return best;
  };

  it.each([3, 5, 8, 9])('exact solver matches brute force (n=%d)', (n) => {
    const c = euclid(pts(n, n));
    const o = shortestPathOrder(n, c);
    expect(o[0]).toBe(0);
    expect(new Set(o).size).toBe(n);
    expect(len(o, c)).toBeCloseTo(brute(n, c), 9);
  });

  it('handles asymmetric costs exactly', () => {
    const c: Cost = (a, b) => (b === a + 1 ? 1 : 10);
    expect(shortestPathOrder(6, c)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  it('heuristic above the exact limit returns a valid, improved path', () => {
    const n = EXACT_LIMIT + 13;
    const c = euclid(pts(n));
    const o = shortestPathOrder(n, c);
    expect(o[0]).toBe(0);
    expect(new Set(o).size).toBe(n);
    expect(len(o, c)).toBeLessThan(len([...Array(n).keys()], c));
  });
});

describe('runView (arbitrary depth)', () => {
  const pre = (id: string) => [{ id, action: id, urgency: 'before' as const, done: false }];
  const tree = () => [
    leaf('A', {
      prerequisites: pre('A.p'),
      children: [
        leaf('a1'),
        leaf('B', { prerequisites: pre('B.p'), children: [leaf('b1', { prerequisites: pre('b1.p') })] }),
      ],
    }),
    leaf('solo', { prerequisites: pre('solo.p') }),
    leaf('C', {
      prerequisites: pre('C.p'),
      children: [leaf('D', { prerequisites: pre('D.p'), children: [leaf('d1')] })],
    }),
  ];

  it('going deeper inside a stage lists the entered sub-stage prerequisites', () => {
    const v = runView(tree());
    expect(v.current!.task.id).toBe('a1');
    expect(v.next!.stage!.from).toBeNull();
    expect(v.next!.stage!.to!.id).toBe('B');
    expect(v.next!.prerequisites.map((p) => p.prerequisite.id)).toEqual(['B.p', 'b1.p']);
  });

  it('crossing several levels lists every entered stage, outermost first', () => {
    const t = tree();
    t[0]!.children[0]!.completed = true;
    t[0]!.children[1]!.children[0]!.completed = true;
    const v = runView(t);
    expect(v.current!.task.id).toBe('solo');
    expect(v.previous!.task.id).toBe('b1');
    expect(v.next!.stage!.from).toBeNull();
    expect(v.next!.stage!.to!.id).toBe('C');
    expect(v.next!.prerequisites.map((p) => p.prerequisite.id)).toEqual(['C.p', 'D.p']);
  });

  it('a top-level leaf after a stage: from = left stage, to = null', () => {
    const t = tree();
    t[0]!.children[0]!.completed = true;
    const v = runView(t);
    expect(v.current!.task.id).toBe('b1');
    expect(v.next!.stage!.from!.id).toBe('A');
    expect(v.next!.stage!.to).toBeNull();
    expect(v.next!.km).toBeNull();
  });

  it('current is the first incomplete leaf; finished when none', () => {
    const t = tree();
    const all = (ns: typeof t) => ns.forEach((n) => ((n.completed = true), all(n.children)));
    all(t);
    const v = runView(t);
    expect(v).toMatchObject({ finished: true, index: 4, total: 4, current: null, next: null });
    expect(v.previous!.task.id).toBe('d1');
  });
});
