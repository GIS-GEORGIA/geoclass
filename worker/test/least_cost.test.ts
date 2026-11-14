import { describe, expect, it } from 'vitest';
import area from '../../test/fixtures/least_cost/area.json';
import dem from '../../test/fixtures/least_cost/dem.u16?inline';
import routes from '../../test/fixtures/least_cost/routes.json';
import { cellsOf, routeCost, routeScore, routeThrough, type Heights } from '../src/games/least_cost';

// The fixture's heights, as the server reads dem.u16.gz (here inlined, uncompressed).
function heights(): Heights {
  const bytes = Uint8Array.from(atob(dem.slice(dem.indexOf(',') + 1)), (c) => c.charCodeAt(0));
  const view = new DataView(bytes.buffer);
  const z = new Float64Array(area.width * area.height);
  for (let i = 0; i < z.length; i++) {
    const v = view.getUint16(i * 2, true);
    z[i] = v === area.grid.nodata ? NaN : v * area.grid.scale;
  }
  return { width: area.width, height: area.height, cell: area.cell, z };
}

describe('least-cost scoring, as the app does it', () => {
  // The same routes and numbers as lib/terrain/least_cost.dart (test/fixtures/least_cost/routes.json).
  const h = heights();
  const w = area.width;
  const start = routes.start[0] * w + routes.start[1];
  const end = routes.end[0] * w + routes.end[1];

  it('costs the app’s best route and drawn routes the same, for both models', () => {
    for (const m of routes.models) {
      const model = m.model as { kind: 'slope'; theta: number } | { kind: 'tobler' };
      const best = cellsOf(start, m.steps, w);
      expect(best[best.length - 1]).toBe(end);
      expect(routeCost(h, model, best)).toBeCloseTo(m.best, 6);
      for (const r of m.routes) {
        const cells = routeThrough([start, ...r.via.map(([row, col]) => row * w + col), end], w);
        expect(cells.length).toBe(r.cells);
        const cost = routeCost(h, model, cells)!;
        expect(cost).toBeCloseTo(r.cost, 6);
        expect(routeScore(m.best, cost)).toBe(r.score);
      }
    }
  });

  it('refuses a route that jumps or leaves the ground it can cross', () => {
    const slope = { kind: 'slope' as const, theta: 15 };
    expect(routeCost(h, slope, [start, start + 2])).toBeNull();
    expect(routeCost(h, slope, [w + 1, 1])).toBeNull(); // the edge has no slope
    expect(routeCost(h, { kind: 'tobler' }, [w + 1, 1])).not.toBeNull();
    expect(routeScore(100, 100)).toBe(100);
    expect(routeScore(100, 99)).toBe(100);
    expect(routeScore(100, 300)).toBe(33);
  });
});
