// Cases in @takt/fixtures/cases.json were produced by running the design prototype (logic.js).
import { describe, expect, it } from 'vitest';
import cases from '@takt/fixtures/cases.json' with { type: 'json' };
import { bestOrder, flattenLeaves, formatKm, haversineKm, prepList, routeKm, runView } from '../src/index.ts';
import { tripTree } from './trip.ts';

describe('geo (golden)', () => {
  it.each(cases.geo.map((c) => [`${c.a.id}→${c.b.id}`, c] as const))('haversine %s', (_, c) => {
    expect(haversineKm(c.a, c.b)).toBeCloseTo(c.km, 9);
  });
  it.each(cases.format.map((c) => [c.km, c.text] as const))('formatKm(%d) = %s', (km, text) => {
    expect(formatKm(km)).toBe(text);
  });
});

describe('route (golden)', () => {
  it.each(cases.route.map((c) => [c.name, c] as const))('%s', (_, c) => {
    expect(routeKm(c.points)).toBeCloseTo(c.totalKm, 9);
    const best = bestOrder(c.points);
    expect(best.map((p) => p.id)).toEqual(c.bestOrder);
    expect(routeKm(best)).toBeCloseTo(c.bestKm, 9);
  });
});

describe('prep (golden)', () => {
  const top = tripTree();
  const level = (name: string) => (name === 'root' ? top : top.find((t) => t.id === name)!.children);
  it.each(cases.prep.map((c) => [c.level, c] as const))('level %s', (_, c) => {
    const list = prepList(level(c.level));
    expect(list.items.map((i) => i.prerequisite.id)).toEqual(c.order);
    expect(list.noPrepCount).toBe(c.noPrep);
    expect(list.remaining).toBe(c.order.length);
  });
});

describe('run (golden)', () => {
  it('expands depth-first to leaves', () => {
    expect(flattenLeaves(tripTree()).map((s) => s.task.id)).toEqual(cases.run.sequence);
  });

  it.each(cases.run.steps.map((s, i) => [i, s] as const))('step %d', (i, s) => {
    const tree = tripTree();
    const done = new Set(cases.run.sequence.slice(0, i));
    const mark = (nodes: typeof tree) =>
      nodes.forEach((t) => {
        t.completed = done.has(t.id);
        mark(t.children);
      });
    mark(tree);

    const v = runView(tree);
    expect(v.index).toBe(i);
    expect(v.total).toBe(cases.run.sequence.length);
    expect(v.current?.task.id).toBe(s.current);
    if (s.next === null) {
      expect(v.next).toBeNull();
      return;
    }
    expect(v.next!.step.task.id).toBe(s.next);
    expect(v.next!.km).toBeCloseTo(s.nextKm!, 9);
    expect(v.next!.stage !== null).toBe(s.stageChange);
    if (s.stage) {
      expect(v.next!.stage!.from?.id).toBe(s.stage.from);
      expect(v.next!.stage!.to?.id).toBe(s.stage.to);
    }
    expect(v.next!.prerequisites.map((p) => p.prerequisite.id)).toEqual(s.nextPrerequisites);
    expect(v.later.map((l) => l.task.id)).toEqual(s.later);
  });
});
