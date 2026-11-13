import { describe, expect, it } from 'vitest';
import expected from '../../test/fixtures/watershed/expected.json';
import scores from '../../test/fixtures/watershed/scores.json';
import { basinScore, isSimplePolygon, polygonRuns, runCells, runsOverlap, type Run } from '../src/games/watershed';

describe('watershed scoring, as the app does it', () => {
  // The same polygons and numbers as test/watershed_test.dart.
  it('counts the same cells and gives the same scores as lib/terrain/watershed.dart', () => {
    for (const c of scores.cases) {
      const poly = c.poly as [number, number][];
      expect(isSimplePolygon(poly), c.note).toBe(c.simple);
      if (!c.simple) continue;
      const basin = (typeof c.basin === 'number' ? expected.basins[c.basin].runs : c.basin) as Run[];
      const runs = polygonRuns(poly, 120);
      expect(runCells(runs), c.note).toBe(c.cells);
      expect(runsOverlap(runs, basin), c.note).toBe(c.overlap);
      expect(basinScore(runs, basin), c.note).toBe(c.score);
    }
  });
});
