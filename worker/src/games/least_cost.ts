import { HttpError } from '../validate';
import type { GameModule } from './types';

/**
 * Least-cost path: the teacher puts a start A and an end B on a terrain area and picks a cost model; students
 * draw their route from A to B by its corners. Score: the best route's cost over the student's, × 100.
 *
 * Two cost models, as lib/terrain/least_cost.dart has them (checked there against GRASS r.cost and SciPy):
 *   slope   each cell costs 1 + (slope / θ)² per metre, slope by Horn's method as gdaldem makes it; a move
 *           costs the mean of the two cells' costs times its length (30 m, diagonally 30 m × √2).
 *   tobler  a move takes length / v minutes, v = 6·exp(−3.5·|dh / length + 0.05|) km/h.
 *
 * The teacher's app finds the best route (Dijkstra over the whole grid) and sends it as steps; the server adds
 * up that route's cost from the area's heights in R2, so the best cost is that of a real route from A to B.
 * The student's route is the straight legs between its corners, cell to cell, costed the same way here.
 */

type Cell = { row: number; col: number };
type Model = { kind: 'slope'; theta: number } | { kind: 'tobler' };

export type LeastCostSettings = {
  area: { id: string; version: number };
  model: Model;
  start: Cell;
  end: Cell;
  /** The best route, one digit per move: an index into STEPS. */
  steps: string;
  /** The best route's cost: metres (slope) or minutes (tobler). */
  best: number;
  width: number;
  height: number;
};

export const THETAS = [10, 15, 20];
/** The largest grid an area may have (lib/terrain/elevation.dart refuses bigger ones). */
const GRID_MAX = 4000;
const MAX_STEPS = 6000;
const CORNERS = { max: 100 };
/** A and B at least this many cells apart, so that there is a choice of routes. */
export const MIN_APART = 10;

const STEPS: [number, number][] = [
  [-1, -1],
  [-1, 0],
  [-1, 1],
  [0, -1],
  [0, 1],
  [1, -1],
  [1, 0],
  [1, 1],
];

function bad(code = 'bad_least_cost'): never {
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

function readModel(raw: unknown): Model {
  const m = raw as Record<string, unknown> | null;
  if (typeof m !== 'object' || m === null) bad();
  if (m.kind === 'slope' && THETAS.includes(m.theta as number)) return { kind: 'slope', theta: m.theta as number };
  if (m.kind === 'tobler') return { kind: 'tobler' };
  bad();
}

function readCell(raw: unknown, height: number, width: number, code = 'bad_least_cost'): Cell {
  const c = raw as Record<string, unknown> | null;
  if (typeof c !== 'object' || c === null || !isInt(c.row, 0, height - 1) || !isInt(c.col, 0, width - 1)) bad(code);
  return { row: c.row as number, col: c.col as number };
}

/** An area's heights in metres (NaN where none), as lib/terrain/elevation.dart reads them. */
export type Heights = { width: number; height: number; cell: number; z: Float64Array };

// Area files never change once built, so a grid read once serves later answers in the same isolate.
const grids = new Map<string, Promise<Heights>>();

async function loadHeights(env: Env, area: { id: string; version: number }): Promise<Heights> {
  const key = `areas/${area.id}/${area.version}`;
  let loading = grids.get(key);
  if (!loading) {
    loading = readHeights(env, key);
    grids.set(key, loading);
    loading.catch(() => grids.delete(key));
    while (grids.size > 3) grids.delete(grids.keys().next().value!);
  }
  return loading;
}

async function readHeights(env: Env, key: string): Promise<Heights> {
  const [metaObject, demObject] = await Promise.all([env.AREAS.get(`${key}/area.json`), env.AREAS.get(`${key}/dem.u16.gz`)]);
  if (!metaObject || !demObject) bad('no_area');
  const meta = (await metaObject.json()) as { width?: unknown; height?: unknown; cell?: unknown; grid?: { scale?: unknown; nodata?: unknown } };
  if (!isInt(meta.width, 3, GRID_MAX) || !isInt(meta.height, 3, GRID_MAX) || typeof meta.cell !== 'number') bad('no_area');
  const scale = typeof meta.grid?.scale === 'number' ? meta.grid.scale : 0.1;
  const nodata = typeof meta.grid?.nodata === 'number' ? meta.grid.nodata : 65535;
  const bytes = new Uint8Array(await new Response(demObject.body.pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
  const n = (meta.width as number) * (meta.height as number);
  if (bytes.length !== n * 2) bad('no_area');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const z = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const v = view.getUint16(i * 2, true);
    z[i] = v === nodata ? NaN : v * scale;
  }
  return { width: meta.width as number, height: meta.height as number, cell: meta.cell, z };
}

/** Slope in degrees by Horn's method, as lib/terrain/slope.dart works it out and stores it (float32); NaN at the edge. */
export function slopeAt(h: Heights, i: number): number {
  const w = h.width;
  const r = Math.floor(i / w);
  const c = i - r * w;
  if (r < 1 || c < 1 || r >= h.height - 1 || c >= w - 1) return NaN;
  const z = h.z;
  const a = z[i - w - 1], b = z[i - w], cc = z[i - w + 1];
  const d = z[i - 1], e = z[i], f = z[i + 1];
  const g = z[i + w - 1], hh = z[i + w], ii = z[i + w + 1];
  if (Number.isNaN(a + b + cc + d + e + f + g + hh + ii)) return NaN;
  const inv = 1 / (8 * h.cell);
  const dx = (cc + 2 * f + ii - (a + 2 * d + g)) * inv;
  const dy = (g + 2 * hh + ii - (a + 2 * b + cc)) * inv;
  return Math.fround((Math.atan(Math.sqrt(dx * dx + dy * dy)) * 180) / Math.PI);
}

/** What moves cost on one grid under one model, as CostSurface in least_cost.dart. */
export function costSurface(h: Heights, model: Model) {
  const cellCost = (i: number) => {
    const t = slopeAt(h, i) / (model as { theta: number }).theta;
    return 1 + t * t;
  };
  const passable = (i: number) => (model.kind === 'slope' ? !Number.isNaN(slopeAt(h, i)) : !Number.isNaN(h.z[i]));
  const move = (a: number, b: number, diagonal: boolean) => {
    const d = diagonal ? h.cell * Math.SQRT2 : h.cell;
    if (model.kind === 'slope') return ((cellCost(a) + cellCost(b)) / 2) * d;
    const v = 6 * Math.exp(-3.5 * Math.abs((h.z[b] - h.z[a]) / d + 0.05));
    return d / ((v * 1000) / 60);
  };
  return { passable, move };
}

/** A route's cost, cell to cell; null when it crosses a cell that can't be crossed or jumps. */
export function routeCost(h: Heights, model: Model, cells: number[]): number | null {
  const s = costSurface(h, model);
  if (cells.length === 0 || !s.passable(cells[0])) return null;
  let sum = 0;
  for (let k = 1; k < cells.length; k++) {
    const a = cells[k - 1];
    const b = cells[k];
    if (a === b) continue;
    const dr = Math.floor(b / h.width) - Math.floor(a / h.width);
    const dc = (b % h.width) - (a % h.width);
    if (Math.abs(dr) > 1 || Math.abs(dc) > 1 || !s.passable(b)) return null;
    sum += s.move(a, b, dr !== 0 && dc !== 0);
  }
  return sum;
}

/** The cells through the corners, each leg a straight line of 8-connected cells (Bresenham), as routeThrough in least_cost.dart. */
export function routeThrough(corners: number[], width: number): number[] {
  const out: number[] = [];
  for (let k = 0; k < corners.length; k++) {
    if (k === 0) {
      out.push(corners[0]);
      continue;
    }
    let r = Math.floor(corners[k - 1] / width);
    let c = corners[k - 1] % width;
    const r1 = Math.floor(corners[k] / width);
    const c1 = corners[k] % width;
    const dr = Math.abs(r1 - r);
    const dc = Math.abs(c1 - c);
    const sr = r1 > r ? 1 : -1;
    const sc = c1 > c ? 1 : -1;
    let err = dc - dr;
    while (r !== r1 || c !== c1) {
      const e2 = 2 * err;
      if (e2 > -dr) {
        err -= dr;
        c += sc;
      }
      if (e2 < dc) {
        err += dc;
        r += sr;
      }
      out.push(r * width + c);
    }
  }
  return out;
}

export function cellsOf(start: number, steps: string, width: number): number[] {
  const out = [start];
  for (let k = 0; k < steps.length; k++) {
    const [dr, dc] = STEPS[steps.charCodeAt(k) - 48];
    out.push(out[out.length - 1] + dr * width + dc);
  }
  return out;
}

/** The best cost over the route's, × 100; 100 at most. */
export function routeScore(best: number, cost: number): number {
  if (cost <= best) return 100;
  return Math.round((100 * best) / cost);
}

async function makeSettings(raw: unknown, env: Env): Promise<LeastCostSettings> {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = readArea(r.area);
  const model = readModel(r.model);
  const h = await loadHeights(env, area);
  return checked({ area, model, start: r.start, end: r.end, steps: r.steps }, h);
}

/** Settings whose best route is a real one from A to B; its cost worked out here. */
function checked(r: Record<string, unknown>, h: Heights): LeastCostSettings {
  const model = r.model as Model;
  const start = readCell(r.start, h.height, h.width);
  const end = readCell(r.end, h.height, h.width);
  if (Math.max(Math.abs(start.row - end.row), Math.abs(start.col - end.col)) < MIN_APART) bad('too_close');
  if (typeof r.steps !== 'string' || r.steps.length === 0 || r.steps.length > MAX_STEPS || !/^[0-7]+$/.test(r.steps)) bad();
  const cells = cellsOf(start.row * h.width + start.col, r.steps, h.width);
  // The steps must stay on the grid: a step off the east or west edge would wrap to the next row.
  for (let k = 1; k < cells.length; k++) {
    const [, dc] = STEPS[r.steps.charCodeAt(k - 1) - 48];
    const col = cells[k - 1] % h.width;
    if (cells[k] < 0 || cells[k] >= h.width * h.height || col + dc < 0 || col + dc >= h.width) bad();
  }
  if (cells[cells.length - 1] !== end.row * h.width + end.col) bad();
  const best = routeCost(h, model, cells);
  if (best === null) bad('blocked');
  return { area: r.area as { id: string; version: number }, model, start, end, steps: r.steps, best, width: h.width, height: h.height };
}

export const leastCost: GameModule<LeastCostSettings> = {
  id: 'least-cost',
  timed: false,
  answers: 'first',
  settings: (body, env) => makeSettings(body.leastCost, env),
  studentView: (s) => ({ area: s.area, model: s.model, start: s.start, end: s.end }),
  validateAnswer(raw, s) {
    const via = (raw as { via?: unknown } | null)?.via;
    if (!Array.isArray(via) || via.length > CORNERS.max) bad('bad_answer');
    return {
      via: via.map((p) => {
        if (!Array.isArray(p) || p.length !== 2 || !isInt(p[0], 0, s.height - 1) || !isInt(p[1], 0, s.width - 1)) bad('bad_answer');
        return [p[0], p[1]];
      }),
    };
  },
  async score(s, answer, _place, round, env) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    const h = await loadHeights(env, s.area);
    if (h.width !== s.width || h.height !== s.height) bad('no_area');
    const corners = [s.start, ...(answer.via as number[][]).map(([row, col]) => ({ row, col })), s.end].map((c) => c.row * s.width + c.col);
    const cost = routeCost(h, s.model, routeThrough(corners, s.width));
    if (cost === null) bad('blocked');
    // The best route's cost from the heights again, not as stored: a restored backup can't change it.
    return { round: 0, distance: null, score: routeScore(checked(s, h).best, cost) };
  },
  feedback: (s, row) => ({ score: row.score, steps: s.steps, best: s.best }),
  restoreSettings(raw) {
    // The route is checked and costed again against the heights whenever an answer is scored.
    if (typeof raw !== 'object' || raw === null) bad();
    const r = raw as Record<string, unknown>;
    const area = readArea(r.area);
    const model = readModel(r.model);
    if (!isInt(r.width, 3, GRID_MAX) || !isInt(r.height, 3, GRID_MAX) || typeof r.best !== 'number' || !(r.best > 0)) bad();
    const start = readCell(r.start, r.height as number, r.width as number);
    const end = readCell(r.end, r.height as number, r.width as number);
    if (typeof r.steps !== 'string' || r.steps.length > MAX_STEPS || !/^[0-7]+$/.test(r.steps)) bad();
    return { area, model, start, end, steps: r.steps, best: r.best as number, width: r.width as number, height: r.height as number };
  },
};
