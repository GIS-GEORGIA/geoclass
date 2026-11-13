import { HttpError } from '../validate';
import type { GameModule } from './types';

/**
 * Watershed: the teacher picks an outlet on a stream of a terrain area; students draw the basin that drains
 * to it, as a polygon over the relief and the streams. Score: the overlap (intersection over union) of the
 * cells inside the drawn polygon and the basin's cells, × 100, on the area's 30 m grid.
 *
 * The basin is worked out here, when the session is made, from the area's flow directions in R2
 * (flow.u8.gz, GRASS r.watershed -s, built by tool/areas/build_watershed.py): every cell whose water
 * reaches the outlet. The teacher's app does the same (lib/terrain/watershed.dart) to show it while
 * choosing. The basin stays here until the student has answered. One answer each, the first counts.
 */

type Cell = { row: number; col: number };
/** Cells in a row: [row, first column, end column), sorted by row, then column, not overlapping. */
export type Run = [number, number, number];

export type WatershedSettings = {
  area: { id: string; version: number };
  outlet: Cell;
  width: number;
  height: number;
  cells: number;
  runs: Run[];
};

/** The largest grid an area may have (lib/terrain/elevation.dart refuses bigger ones). */
const GRID_MAX = 4000;
/** A basin smaller than this is a gully, not a basin. */
export const MIN_CELLS = 100;
/** Runs a basin may have: about a 3000-row basin of a few runs a row. */
export const MAX_RUNS = 20000;
const VERTICES = { min: 3, max: 100 };

/** Where the cell in direction k sends its water: 0 NE, 1 N, 2 NW, 3 W, 4 SW, 5 S, 6 SE, 7 E. */
const OFFSETS: [number, number][] = [
  [-1, 1],
  [-1, 0],
  [-1, -1],
  [0, -1],
  [1, -1],
  [1, 0],
  [1, 1],
  [0, 1],
];

function bad(code = 'bad_watershed'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;

function readArea(raw: unknown): { id: string; version: number } {
  const area = raw as Record<string, unknown> | undefined;
  if (typeof area !== 'object' || area === null || typeof area.id !== 'string' || !/^[a-z0-9-]{1,40}$/.test(area.id) || !isInt(area.version, 1, 9999)) {
    bad();
  }
  return { id: area.id as string, version: area.version as number };
}

function readCell(raw: unknown, height: number, width: number): Cell {
  const c = raw as Record<string, unknown> | null;
  if (typeof c !== 'object' || c === null || !isInt(c.row, 0, height - 1) || !isInt(c.col, 0, width - 1)) bad();
  return { row: c.row as number, col: c.col as number };
}

/** Every cell whose water reaches (row, col), as a 0/1 mask. */
export function basinMask(flow: Uint8Array, width: number, height: number, row: number, col: number): Uint8Array {
  const mask = new Uint8Array(width * height);
  const queue = [row * width + col];
  mask[queue[0]] = 1;
  while (queue.length > 0) {
    const i = queue.pop()!;
    const r = Math.floor(i / width);
    const c = i - r * width;
    for (let k = 0; k < 8; k++) {
      const nr = r + OFFSETS[k][0];
      const nc = c + OFFSETS[k][1];
      if (nr < 0 || nr >= height || nc < 0 || nc >= width) continue;
      const j = nr * width + nc;
      // The neighbour in direction k drains here if it points back, the opposite way.
      if (mask[j] === 0 && flow[j] === (k + 4) % 8) {
        mask[j] = 1;
        queue.push(j);
      }
    }
  }
  return mask;
}

export function maskRuns(mask: Uint8Array, width: number): Run[] {
  const out: Run[] = [];
  for (let start = 0; start < mask.length; start += width) {
    const r = start / width;
    let c = 0;
    while (c < width) {
      if (mask[start + c]) {
        let e = c;
        while (e < width && mask[start + e]) e++;
        out.push([r, c, e]);
        c = e;
      } else {
        c++;
      }
    }
  }
  return out;
}

export function touchesEdge(runs: Run[], width: number, height: number): boolean {
  return runs.some(([r, c0, c1]) => r === 0 || r === height - 1 || c0 === 0 || c1 === width);
}

export const runCells = (runs: Run[]): number => runs.reduce((n, r) => n + r[2] - r[1], 0);

/** Cells in both sets of runs. */
export function runsOverlap(a: Run[], b: Run[]): number {
  let i = 0;
  let j = 0;
  let both = 0;
  while (i < a.length && j < b.length) {
    const x = a[i];
    const y = b[j];
    if (x[0] !== y[0]) {
      if (x[0] < y[0]) i++;
      else j++;
      continue;
    }
    both += Math.max(0, Math.min(x[2], y[2]) - Math.max(x[1], y[1]));
    if (x[2] < y[2]) i++;
    else j++;
  }
  return both;
}

/** Intersection over union of the drawn cells and the basin's, × 100. */
export function basinScore(drawn: Run[], basin: Run[]): number {
  const both = runsOverlap(drawn, basin);
  const either = runCells(drawn) + runCells(basin) - both;
  return either === 0 ? 0 : Math.round((100 * both) / either);
}

/** A polygon's vertices, as [row, col] on the grid: (0, 0) is the north-west corner of the first cell. */
type Point = [number, number];

/** The cells whose centres are inside the polygon (even-odd rule), as runs; as polygonRuns in watershed.dart. */
export function polygonRuns(poly: Point[], maxRow = GRID_MAX): Run[] {
  const out: Run[] = [];
  if (poly.length < 3) return out;
  let top = Infinity;
  let bottom = -Infinity;
  for (const p of poly) {
    top = Math.min(top, p[0]);
    bottom = Math.max(bottom, p[0]);
  }
  const r0 = Math.max(0, Math.ceil(top - 0.5));
  const r1 = Math.min(maxRow - 1, Math.floor(bottom - 0.5));
  for (let r = r0; r <= r1; r++) {
    const y = r + 0.5;
    const xs: number[] = [];
    for (let i = 0; i < poly.length; i++) {
      const a = poly[i];
      const b = poly[(i + 1) % poly.length];
      if ((a[0] <= y && y < b[0]) || (b[0] <= y && y < a[0])) xs.push(a[1] + ((y - a[0]) * (b[1] - a[1])) / (b[0] - a[0]));
    }
    xs.sort((p, q) => p - q);
    for (let k = 0; k + 1 < xs.length; k += 2) {
      const c0 = Math.ceil(xs[k] - 0.5);
      const c1 = Math.ceil(xs[k + 1] - 0.5);
      if (c1 > c0) out.push([r, c0, c1]);
    }
  }
  return out;
}

/** Whether no two edges cross or touch, other than neighbours at their shared corner; as in watershed.dart. */
export function isSimplePolygon(p: Point[]): boolean {
  const n = p.length;
  if (n < 3) return false;
  const cross = (o: Point, a: Point, b: Point) => (a[1] - o[1]) * (b[0] - o[0]) - (a[0] - o[0]) * (b[1] - o[1]);
  const onSegment = (a: Point, b: Point, q: Point) =>
    Math.min(a[1], b[1]) <= q[1] && q[1] <= Math.max(a[1], b[1]) && Math.min(a[0], b[0]) <= q[0] && q[0] <= Math.max(a[0], b[0]);
  const meet = (a: Point, b: Point, c: Point, d: Point) => {
    const d1 = cross(c, d, a);
    const d2 = cross(c, d, b);
    const d3 = cross(a, b, c);
    const d4 = cross(a, b, d);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
    return (d1 === 0 && onSegment(c, d, a)) || (d2 === 0 && onSegment(c, d, b)) || (d3 === 0 && onSegment(a, b, c)) || (d4 === 0 && onSegment(a, b, d));
  };
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (j === i + 1 || (i === 0 && j === n - 1)) continue;
      if (meet(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n])) return false;
    }
  }
  for (let i = 0; i < n; i++) {
    const a = p[i];
    const b = p[(i + 1) % n];
    const c = p[(i + 2) % n];
    if (cross(a, b, c) === 0 && (onSegment(a, b, c) || onSegment(b, c, a))) return false;
  }
  return true;
}

async function gunzip(body: ReadableStream): Promise<Uint8Array> {
  return new Uint8Array(await new Response(body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
}

/** The area's grid size and flow directions, from R2. A missing area or file is a 400: the teacher's app is out of date. */
async function loadFlow(env: Env, area: { id: string; version: number }): Promise<{ width: number; height: number; flow: Uint8Array }> {
  const base = `areas/${area.id}/${area.version}`;
  const [metaObject, flowObject] = await Promise.all([env.AREAS.get(`${base}/area.json`), env.AREAS.get(`${base}/flow.u8.gz`)]);
  if (!metaObject || !flowObject) bad('no_flow');
  const meta = (await metaObject.json()) as { width?: unknown; height?: unknown };
  if (!isInt(meta.width, 1, GRID_MAX) || !isInt(meta.height, 1, GRID_MAX)) bad('no_flow');
  const flow = await gunzip(flowObject.body);
  if (flow.length !== (meta.width as number) * (meta.height as number)) bad('no_flow');
  return { width: meta.width as number, height: meta.height as number, flow };
}

async function makeSettings(raw: unknown, env: Env): Promise<WatershedSettings> {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = readArea(r.area);
  const { width, height, flow } = await loadFlow(env, area);
  const outlet = readCell(r.outlet, height, width);
  const runs = maskRuns(basinMask(flow, width, height, outlet.row, outlet.col), width);
  return checked({ area, outlet, width, height, cells: runCells(runs), runs });
}

/** A basin the game can be played on: big enough, clear of the area's edge (where it would be cut off), not too complex. */
function checked(s: WatershedSettings): WatershedSettings {
  if (s.cells < MIN_CELLS) bad('basin_small');
  if (s.runs.length > MAX_RUNS) bad('basin_large');
  if (touchesEdge(s.runs, s.width, s.height)) bad('basin_edge');
  return s;
}

/** Settings from a backup: the basin as it was stored, checked to be a well-formed one holding its outlet. */
function restoreSettings(raw: unknown): WatershedSettings {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = readArea(r.area);
  if (!isInt(r.width, 1, GRID_MAX) || !isInt(r.height, 1, GRID_MAX)) bad();
  const width = r.width as number;
  const height = r.height as number;
  const outlet = readCell(r.outlet, height, width);
  if (!Array.isArray(r.runs) || r.runs.length > MAX_RUNS) bad();
  const runs: Run[] = [];
  let last: Run | undefined;
  for (const x of r.runs as unknown[]) {
    if (!Array.isArray(x) || x.length !== 3 || !isInt(x[0], 0, height - 1) || !isInt(x[1], 0, width - 1) || !isInt(x[2], x[1] + 1, width)) bad();
    const run: Run = [x[0], x[1], x[2]];
    if (last && (run[0] < last[0] || (run[0] === last[0] && run[1] <= last[2]))) bad();
    runs.push(run);
    last = run;
  }
  const holdsOutlet = runs.some(([row, c0, c1]) => row === outlet.row && c0 <= outlet.col && outlet.col < c1);
  if (!holdsOutlet || r.cells !== runCells(runs)) bad();
  return checked({ area, outlet, width, height, cells: r.cells as number, runs });
}

export const watershed: GameModule<WatershedSettings> = {
  id: 'watershed',
  timed: false,
  answers: 'first',
  settings: (body, env) => makeSettings(body.watershed, env),
  studentView: (s) => ({ area: s.area, outlet: s.outlet }),
  validateAnswer(raw, s) {
    const poly = (raw as { poly?: unknown } | null)?.poly;
    if (!Array.isArray(poly) || poly.length < VERTICES.min || poly.length > VERTICES.max) bad('bad_answer');
    const points: Point[] = poly.map((p) => {
      if (!Array.isArray(p) || p.length !== 2) bad('bad_answer');
      const [row, col] = p as unknown[];
      const ok = (v: unknown, max: number) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= max;
      if (!ok(row, s.height) || !ok(col, s.width)) bad('bad_answer');
      // Two decimals of a cell (30 cm) is all a finger can place; it keeps stored answers short.
      return [Math.round((row as number) * 100) / 100, Math.round((col as number) * 100) / 100];
    });
    if (!isSimplePolygon(points)) bad('bad_answer');
    return { poly: points };
  },
  score(s, answer, _place, round) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    return { round: 0, distance: null, score: basinScore(polygonRuns(answer.poly as Point[], s.height), s.runs) };
  },
  feedback: (s, row) => ({ score: row.score, basin: s.runs }),
  restoreSettings,
};
