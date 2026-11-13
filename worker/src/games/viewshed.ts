import { HttpError } from '../validate';
import { overlapScore } from './slope';
import type { GameModule } from './types';

/**
 * Viewshed: the teacher puts an observer (a lookout, a tower) on a terrain area; students judge what it sees,
 * reading the relief and the contours. Two kinds:
 *   targets  3 to 8 points; for each, the student says seen or not. Score: the share answered right, × 100.
 *   squares  a box of n × n squares, as in the slope game; the student marks the seen ones. A square is seen
 *            when most of its ground is. Score: the overlap (intersection over union) × 100.
 * What is seen is worked out by the teacher's app (lib/terrain/viewshed.dart, gdal_viewshed's algorithm,
 * checked against GDAL) and stays here until the student has answered. One answer each, the first counts.
 */

export const VIEW_HEIGHTS = [1.7, 10, 30];

type Cell = { row: number; col: number };

export type ViewshedSettings = {
  area: { id: string; version: number };
  observer: Cell;
  /** The observer's eye above the ground, in metres. */
  height: number;
  kind: 'targets' | 'squares';
  targets?: Cell[];
  box?: { row: number; col: number; cells: number; n: number };
  /** One character per target, or per square (rows north to south): '1' seen, '0' not. */
  answer: string;
};

const TARGETS = { min: 3, max: 8 };
const N = { min: 4, max: 12 };
const CELLS = { min: 3, max: 40 };
/** The largest grid an area may have (lib/terrain/elevation.dart refuses bigger ones). */
const GRID_MAX = 4000;

function bad(code = 'bad_viewshed'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;

function readCell(raw: unknown): Cell {
  const c = raw as Record<string, unknown> | null;
  if (typeof c !== 'object' || c === null || !isInt(c.row, 0, GRID_MAX - 1) || !isInt(c.col, 0, GRID_MAX - 1)) bad();
  return { row: c.row as number, col: c.col as number };
}

function readSettings(raw: unknown): ViewshedSettings {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = r.area as Record<string, unknown> | undefined;
  if (typeof area !== 'object' || area === null || typeof area.id !== 'string' || !/^[a-z0-9-]{1,40}$/.test(area.id) || !isInt(area.version, 1, 9999)) {
    bad();
  }
  const observer = readCell(r.observer);
  if (!VIEW_HEIGHTS.includes(r.height as number)) bad();
  const out: ViewshedSettings = {
    area: { id: area!.id as string, version: area!.version as number },
    observer,
    height: r.height as number,
    kind: r.kind as 'targets' | 'squares',
    answer: '',
  };
  let length: number;
  if (r.kind === 'targets') {
    if (!Array.isArray(r.targets) || r.targets.length < TARGETS.min || r.targets.length > TARGETS.max) bad();
    const targets = r.targets.map(readCell);
    const keys = new Set([observer, ...targets].map((c) => `${c.row}/${c.col}`));
    if (keys.size !== targets.length + 1) bad(); // two on one cell, or one on the observer
    out.targets = targets;
    length = targets.length;
  } else if (r.kind === 'squares') {
    const box = r.box as Record<string, unknown> | undefined;
    if (typeof box !== 'object' || box === null || !isInt(box.n, N.min, N.max) || !isInt(box.cells, CELLS.min, CELLS.max)) bad();
    const side = (box.n as number) * (box.cells as number);
    if (!isInt(box.row, 0, GRID_MAX - side) || !isInt(box.col, 0, GRID_MAX - side)) bad();
    out.box = { row: box.row as number, col: box.col as number, cells: box.cells as number, n: box.n as number };
    length = (box.n as number) ** 2;
  } else {
    bad();
  }
  if (typeof r.answer !== 'string' || r.answer.length !== length || !/^[01]+$/.test(r.answer)) bad();
  // Nothing seen in the box would make every empty answer right.
  if (r.kind === 'squares' && !r.answer.includes('1')) bad();
  out.answer = r.answer;
  return out;
}

/** The share of targets judged right, × 100. */
export function targetScore(seen: string, answer: string): number {
  let right = 0;
  for (let i = 0; i < answer.length; i++) if (seen[i] === answer[i]) right++;
  return Math.round((100 * right) / answer.length);
}

const length = (s: ViewshedSettings) => (s.kind === 'targets' ? s.targets!.length : s.box!.n ** 2);

export const viewshed: GameModule<ViewshedSettings> = {
  id: 'viewshed',
  timed: false,
  answers: 'first',
  settings: (body) => readSettings(body.viewshed),
  studentView: (s) => ({
    area: s.area,
    observer: s.observer,
    height: s.height,
    kind: s.kind,
    ...(s.kind === 'targets' ? { targets: s.targets } : { box: s.box }),
  }),
  validateAnswer(raw, s) {
    const seen = (raw as { seen?: unknown } | null)?.seen;
    if (typeof seen !== 'string' || seen.length !== length(s) || !/^[01]+$/.test(seen)) bad('bad_answer');
    return { seen };
  },
  score(s, answer, _place, round) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    const seen = answer.seen as string;
    return { round: 0, distance: null, score: s.kind === 'targets' ? targetScore(seen, s.answer) : overlapScore(seen, s.answer) };
  },
  feedback: (s, row) => ({ score: row.score, answer: s.answer }),
  restoreSettings: readSettings,
};
