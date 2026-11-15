import { HttpError } from '../validate';
import type { GameModule } from './types';
import { TIMELAPSE_CATALOG } from '../timelapse';

/**
 * Time-lapse: what changed between two years, seen from a satellite (timelapse.ts serves the frames).
 *
 * The teacher prepares a template (templates.ts) once: a site, two of its years A and B, and the outline of
 * what is to be found on each, drawn on that year's frame (the open pits, the city, the delta). A session
 * takes a copy of it when it is made.
 *
 * The student plays the frames, then draws the same thing on year A and on year B; the app shows the areas
 * and the change. One answer, the first counts. Score, out of 100: the mean of the two years' IoU (the area
 * both outlines cover over the area either covers) × 100.
 *
 * Outlines are lists of rings of [lat, lon], each ring a polygon without holes; the rings of a year are one
 * shape together (where they overlap, it counts once). A ring that crosses itself is filled even-odd.
 * As lib/timelapse/timelapse.dart's iou; test/fixtures/timelapse/iou.json holds GDAL's answers for both.
 */

export const LIMITS = {
  /** A template's outline, per year: a teacher traces more carefully. */
  truthRings: 20,
  truthVertices: 300,
  /** A student's outline, per year: kept small enough for a submission (8 KB). */
  answerRings: 10,
  answerVertices: 100,
};
const SITE_ID = /^[a-z0-9-]{1,40}$/;
const TEMPLATE_ID = /^[0-9a-f-]{36}$/;
/** How far outside a site's frame the teacher's outline may reach, in degrees: a pit at the edge. */
const MARGIN = 0.01;

export type Ring = [number, number][];
export type Outline = Ring[];
export type TemplateData = { site: string; version: number; years: [number, number]; truth: [Outline, Outline] };
export type TimelapseSettings = TemplateData & { template: string; name: string };

function bad(code = 'bad_timelapse'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isNum = (v: unknown, min: number, max: number): v is number => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;

/** An outline: up to [rings] rings of 3 or more [lat, lon], [vertices] in all. */
export function readOutline(raw: unknown, rings: number, vertices: number, code: string): Outline {
  if (!Array.isArray(raw) || raw.length > rings) bad(code);
  let n = 0;
  const out = raw.map((ring) => {
    if (!Array.isArray(ring) || ring.length < 3) bad(code);
    n += ring.length;
    return ring.map((p) => {
      if (!Array.isArray(p) || p.length !== 2 || !isNum(p[0], -90, 90) || !isNum(p[1], -180, 180)) bad(code);
      return [p[0], p[1]] as [number, number];
    });
  });
  if (n > vertices) bad(code);
  return out;
}

/** A template's data as saved (a draft may have no outlines yet): { site, version, years, truth }. */
export function readTemplateData(raw: unknown, code = 'bad_timelapse'): TemplateData {
  if (typeof raw !== 'object' || raw === null) bad(code);
  const d = raw as Record<string, unknown>;
  if (typeof d.site !== 'string' || !SITE_ID.test(d.site) || !isInt(d.version, 1, 9999)) bad(code);
  const years = d.years;
  if (!Array.isArray(years) || years.length !== 2 || !years.every((y) => isInt(y, 1950, 2100))) bad(code);
  const truth = d.truth;
  if (!Array.isArray(truth) || truth.length !== 2) bad(code);
  return {
    site: d.site,
    version: d.version,
    years: [years[0], years[1]],
    truth: [readOutline(truth[0], LIMITS.truthRings, LIMITS.truthVertices, code), readOutline(truth[1], LIMITS.truthRings, LIMITS.truthVertices, code)],
  };
}

/** Settings a session can be played with: two different years, in order, each with an outline. */
function checked(raw: Record<string, unknown>, code: string): TimelapseSettings {
  if (typeof raw.template !== 'string' || !TEMPLATE_ID.test(raw.template)) bad(code);
  const d = readTemplateData(raw, code);
  if (d.years[0] >= d.years[1] || d.truth.some((o) => o.length === 0)) bad(code);
  const name = typeof raw.name === 'string' ? raw.name.trim().slice(0, 80) : '';
  return { ...d, template: raw.template, name };
}

type CatalogSite = { id: string; version: number; bbox: [number, number, number, number]; years: number[] };

async function makeSettings(body: Record<string, unknown>, env: Env, owner: { admin: boolean; id: string | null }): Promise<TimelapseSettings> {
  const id = (body.timelapse as Record<string, unknown> | undefined)?.template;
  if (typeof id !== 'string' || !TEMPLATE_ID.test(id)) bad();
  const row = await env.DB.prepare("SELECT name, data FROM templates WHERE id = ? AND game = 'timelapse' AND (? = 1 OR teacher_id IS ?)")
    .bind(id, owner.admin ? 1 : 0, owner.id)
    .first<{ name: string; data: string }>();
  if (!row) bad('no_template');
  const s = checked({ ...(JSON.parse(row.data) as Record<string, unknown>), template: id, name: row.name }, 'template_unfinished');
  // The site, its version and both years must be served, and the outlines on its frame.
  const catalog = await env.AREAS.get(TIMELAPSE_CATALOG);
  const sites = catalog ? ((await catalog.json()) as { sites?: CatalogSite[] }).sites ?? [] : [];
  const site = sites.find((x) => x.id === s.site && x.version === s.version);
  if (!site || !s.years.every((y) => site.years.includes(y))) bad('no_site');
  const [w, so, e, n] = site.bbox;
  const inside = s.truth.every((o) => o.every((r) => r.every(([lat, lon]) => lat >= so - MARGIN && lat <= n + MARGIN && lon >= w - MARGIN && lon <= e + MARGIN)));
  if (!inside) bad('template_unfinished');
  return s;
}

/** The parts of the horizontal line at y inside an outline, as sorted, separate [from, to] spans. */
function spans(rings: [number, number][][], y: number): [number, number][] {
  const out: [number, number][] = [];
  for (const ring of rings) {
    const xs: number[] = [];
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const [x1, y1] = ring[j];
      const [x2, y2] = ring[i];
      // Half-open, so a line through a vertex crosses once.
      if (y1 <= y !== y2 <= y) xs.push(x1 + ((y - y1) / (y2 - y1)) * (x2 - x1));
    }
    xs.sort((a, b) => a - b);
    for (let k = 0; k + 1 < xs.length; k += 2) out.push([xs[k], xs[k + 1]]);
  }
  out.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const s of out) {
    const last = merged[merged.length - 1];
    if (last && s[0] <= last[1]) last[1] = Math.max(last[1], s[1]);
    else merged.push([s[0], s[1]]);
  }
  return merged;
}

const length = (s: [number, number][]) => s.reduce((t, [a, b]) => t + b - a, 0);

function overlap(a: [number, number][], b: [number, number][]): number {
  let t = 0;
  for (let i = 0, j = 0; i < a.length && j < b.length; ) {
    t += Math.max(0, Math.min(a[i][1], b[j][1]) - Math.max(a[i][0], b[j][0]));
    if (a[i][1] < b[j][1]) i++;
    else j++;
  }
  return t;
}

/**
 * The IoU of two outlines, 0 to 1. On a local flat projection about the truth's middle (over a site's few
 * kilometres it changes areas by far less than the drawing does), on [rows] horizontal lines across both:
 * exact along each line, the lines' lengths summed. Neither outline: 0.
 */
export function iou(truth: Outline, answer: Outline, rows = 2000): number {
  const all = [...truth, ...answer].flat();
  if (truth.length === 0 || answer.length === 0 || all.length === 0) return 0;
  const lats = truth.flat().map((p) => p[0]);
  const lons = truth.flat().map((p) => p[1]);
  const lat0 = (Math.min(...lats) + Math.max(...lats)) / 2;
  const lon0 = (Math.min(...lons) + Math.max(...lons)) / 2;
  const k = Math.cos((lat0 * Math.PI) / 180);
  const project = (o: Outline) => o.map((r) => r.map(([lat, lon]) => [(lon - lon0) * k, lat - lat0] as [number, number]));
  const t = project(truth);
  const a = project(answer);
  const ys = [...t, ...a].flat().map((p) => p[1]);
  const y0 = Math.min(...ys);
  const dy = (Math.max(...ys) - y0) / rows;
  if (!(dy > 0)) return 0;
  let both = 0;
  let either = 0;
  for (let r = 0; r < rows; r++) {
    const y = y0 + (r + 0.5) * dy;
    const st = spans(t, y);
    const sa = spans(a, y);
    const o = overlap(st, sa);
    both += o;
    either += length(st) + length(sa) - o;
  }
  return either > 0 ? both / either : 0;
}

/** The score of an answer: the mean of the two years' IoU × 100. */
export function scoreAnswer(s: TemplateData, answer: [Outline, Outline]): { ious: [number, number]; total: number } {
  const ious: [number, number] = [iou(s.truth[0], answer[0]), iou(s.truth[1], answer[1])];
  return { ious, total: Math.round(((ious[0] + ious[1]) / 2) * 100) };
}

export const timelapse: GameModule<TimelapseSettings> = {
  id: 'timelapse',
  timed: false,
  answers: 'first',
  settings: (body, env, owner) => makeSettings(body, env, owner ?? { admin: false, id: null }),
  studentView: (s) => ({ template: s.template, name: s.name, site: s.site, version: s.version, years: s.years }),
  validateAnswer(raw) {
    if (typeof raw !== 'object' || raw === null) bad('bad_answer');
    const a = raw as Record<string, unknown>;
    const outline = (v: unknown) => readOutline(v, LIMITS.answerRings, LIMITS.answerVertices, 'bad_answer');
    const out = { a: outline(a.a), b: outline(a.b) };
    if (out.a.length === 0 && out.b.length === 0) bad('bad_answer');
    return out;
  },
  score(s, answer, _place, round) {
    if (round !== 0 && round !== undefined && round !== null) throw new HttpError(400, 'bad_round');
    const a = answer as unknown as { a: Outline; b: Outline };
    return { round: 0, distance: null, score: scoreAnswer(s, [a.a, a.b]).total };
  },
  feedback: (s, row) => ({ score: row.score, truth: s.truth }),
  restoreSettings(raw) {
    if (typeof raw !== 'object' || raw === null) bad();
    return checked(raw as Record<string, unknown>, 'bad_timelapse');
  },
};
