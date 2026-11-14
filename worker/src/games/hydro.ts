import { HttpError } from '../validate';
import type { GameModule } from './types';
import {
  basinMask,
  basinScore,
  isSimplePolygon,
  loadFlow,
  makeSettings,
  maskRuns,
  restoreSettings,
  type WatershedSettings,
} from './watershed';

/**
 * Watershed, level 2: the basin worked out from the terrain, step by step. The teacher picks an area and an
 * outlet on a stream, as in level 1 (watershed.ts makes and checks the same settings). The student looks at
 * the DEM, follows drops of water down the D8 directions, sets the stream threshold on the flow accumulation,
 * and puts a pour point where the teacher's outlet is: the app delineates that point's basin. They may also
 * draw the basin by hand, to compare with the delineated one.
 *
 * Score: the overlap (intersection over union) of the pour point's basin with the outlet's, × 100, both from
 * the area's flow directions in R2. A pour point a cell off the river gives a hillside's basin, not the
 * river's: that is the lesson. One answer each, the first counts.
 */

const THRESHOLD = { min: 10, max: 100000 };
const VERTICES = { min: 3, max: 100 };
type Point = [number, number];

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;

function badAnswer(): never {
  throw new HttpError(400, 'bad_answer');
}

export const hydro: GameModule<WatershedSettings> = {
  id: 'hydro',
  timed: false,
  answers: 'first',
  settings: (body, env) => makeSettings(body.hydro, env),
  studentView: (s) => ({ area: s.area, outlet: s.outlet }),
  validateAnswer(raw, s) {
    if (typeof raw !== 'object' || raw === null) badAnswer();
    const a = raw as Record<string, unknown>;
    const pour = a.pour as Record<string, unknown> | null;
    if (typeof pour !== 'object' || pour === null || !isInt(pour.row, 0, s.height - 1) || !isInt(pour.col, 0, s.width - 1)) badAnswer();
    if (!isInt(a.threshold, THRESHOLD.min, THRESHOLD.max)) badAnswer();
    const out: Record<string, unknown> = { pour: { row: pour.row, col: pour.col }, threshold: a.threshold };
    if (a.poly !== undefined && a.poly !== null) {
      if (!Array.isArray(a.poly) || a.poly.length < VERTICES.min || a.poly.length > VERTICES.max) badAnswer();
      const points: Point[] = a.poly.map((p) => {
        if (!Array.isArray(p) || p.length !== 2) badAnswer();
        const [row, col] = p as unknown[];
        const ok = (v: unknown, max: number) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= max;
        if (!ok(row, s.height) || !ok(col, s.width)) badAnswer();
        return [Math.round((row as number) * 100) / 100, Math.round((col as number) * 100) / 100];
      });
      if (!isSimplePolygon(points)) badAnswer();
      out.poly = points;
    }
    return out;
  },
  async score(s, answer, _place, round, env) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    const { width, height, flow } = await loadFlow(env, s.area);
    if (width !== s.width || height !== s.height) throw new HttpError(400, 'no_flow');
    const pour = answer.pour as { row: number; col: number };
    const mine = maskRuns(basinMask(flow, width, height, pour.row, pour.col), width);
    return { round: 0, distance: null, score: basinScore(mine, s.runs) };
  },
  feedback: (s, row) => ({ score: row.score, basin: s.runs }),
  restoreSettings,
};
