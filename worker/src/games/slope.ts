import { HttpError } from '../validate';
import type { GameModule } from './types';

/**
 * Slope: the teacher puts a box of n × n squares on a terrain area; students mark the squares they think
 * are steeper than the threshold, reading the relief and the contours. A square is steep when most of its
 * ground is (lib/terrain/slope_game.dart, from slope checked against gdaldem).
 *
 * The right squares are worked out by the teacher's app when the session is made and stay here until the
 * student has answered. Score: the overlap (intersection over union) of the student's squares and the
 * right ones, times 100. One answer per student, the first one counts.
 */

export const SLOPE_THRESHOLDS = [5, 15, 30];

export type SlopeSettings = {
  area: { id: string; version: number };
  /** The box on the area's grid: its top-left cell, cells per square side, and squares per box side. */
  box: { row: number; col: number; cells: number; n: number };
  threshold: number;
  /** One character per square, rows north to south: '1' steep, '0' not. */
  answer: string;
};

const N = { min: 4, max: 12 };
const CELLS = { min: 3, max: 40 };
/** The largest grid an area may have (lib/terrain/elevation.dart refuses bigger ones). */
const GRID_MAX = 4000;

function bad(code = 'bad_slope'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;

function readSettings(raw: unknown): SlopeSettings {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = r.area as Record<string, unknown> | undefined;
  if (typeof area !== 'object' || area === null || typeof area.id !== 'string' || !/^[a-z0-9-]{1,40}$/.test(area.id) || !isInt(area.version, 1, 9999)) {
    bad();
  }
  const box = r.box as Record<string, unknown> | undefined;
  if (typeof box !== 'object' || box === null || !isInt(box.n, N.min, N.max) || !isInt(box.cells, CELLS.min, CELLS.max)) bad();
  const side = (box.n as number) * (box.cells as number);
  // A cell of margin all round: the grid's edge cells have no slope.
  if (!isInt(box.row, 1, GRID_MAX - 1 - side) || !isInt(box.col, 1, GRID_MAX - 1 - side)) bad();
  if (!SLOPE_THRESHOLDS.includes(r.threshold as number)) bad();
  const squares = (box.n as number) ** 2;
  if (typeof r.answer !== 'string' || r.answer.length !== squares || !/^[01]+$/.test(r.answer) || !r.answer.includes('1')) bad();
  return {
    area: { id: area!.id as string, version: area!.version as number },
    box: { row: box.row as number, col: box.col as number, cells: box.cells as number, n: box.n as number },
    threshold: r.threshold as number,
    answer: r.answer,
  };
}

/** Intersection over union of two square markings, times 100; nothing marked against nothing right is 100. */
export function overlapScore(marks: string, answer: string): number {
  let both = 0;
  let either = 0;
  for (let i = 0; i < answer.length; i++) {
    const a = marks[i] === '1';
    const b = answer[i] === '1';
    if (a && b) both++;
    if (a || b) either++;
  }
  return either === 0 ? 100 : Math.round((100 * both) / either);
}

export const slope: GameModule<SlopeSettings> = {
  id: 'slope',
  timed: false,
  answers: 'first',
  settings: (body) => readSettings(body.slope),
  studentView: (s) => ({ area: s.area, box: s.box, threshold: s.threshold }),
  validateAnswer(raw, s) {
    const marks = (raw as { marks?: unknown } | null)?.marks;
    if (typeof marks !== 'string' || marks.length !== s.box.n ** 2 || !/^[01]+$/.test(marks)) bad('bad_answer');
    return { marks };
  },
  score(s, answer, _place, round) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    return { round: 0, distance: null, score: overlapScore(answer.marks as string, s.answer) };
  },
  feedback: (s, row) => ({ score: row.score, answer: s.answer }),
  restoreSettings: readSettings,
};
