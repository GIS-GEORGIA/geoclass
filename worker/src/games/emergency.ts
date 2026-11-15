import { distanceM, HttpError } from '../validate';
import type { GameModule } from './types';
import { photoKey } from '../templates';

/**
 * 112: telling the emergency service where you are. An exercise, never a call: nothing here reaches 112.
 *
 * The teacher prepares a template (templates.ts) once: up to 8 points, each with a scenario ("your friend
 * twisted an ankle on the trail"), the facts the scenario tells (what happened, how many people, anyone
 * hurt, a landmark), the coordinate format the operator asks for, and 2 to 4 photos of the place, one of them
 * the most useful to an operator, each with a note on what in it helps. A session takes a copy of the
 * template's points when it is made.
 *
 * The student sees the scenario and a map marked "you are here", writes the coordinates in the asked format,
 * fills in the message and picks a photo. Each point is a round; the first answer counts. Score, out of 100:
 *   distance  40 within 50 m of the point, falling with the log of the distance to 0 at 5 km;
 *   format    20 if the coordinates are written in the asked format (classifyCoords);
 *   message   5 each: what happened, how many people, anyone hurt (as in the facts), a landmark given;
 *   photo     20 for the teacher's best photo.
 * The app reads the typed coordinates (lib/coords.dart's parsers) and sends the point it read; the server
 * measures its distance and classifies the text itself.
 */

export const FORMATS = ['dd', 'dm', 'dms', 'utm'] as const;
export const KINDS = ['injury', 'lost', 'fire', 'traffic', 'flood', 'other'] as const;
export const LIMITS = { points: 8, photosMin: 2, photosMax: 4, title: 80, text: 600, landmark: 120, note: 200, people: 99 };
const PHOTO_ID = /^[0-9a-f]{16}$/;
const TEMPLATE_ID = /^[0-9a-f-]{36}$/;

export type Photo = { id: string; note: string };
export type Facts = { kind: string; people: number; injured: boolean; landmark: string };
export type Point = { lat: number; lon: number; format: string; title: string; text: string; facts: Facts; photos: Photo[]; best: number };
export type EmergencySettings = { template: string; name: string; points: Point[]; order: number[][] };

function bad(code = 'bad_emergency'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isNum = (v: unknown, min: number, max: number): v is number => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;

function str(v: unknown, max: number, code: string, required = false): string {
  if (v === undefined && !required) return '';
  if (typeof v !== 'string') bad(code);
  const s = v.trim();
  if (s.length > max || (required && !s)) bad(code);
  return s;
}

/**
 * A point of a template. [strict] for one a session can be made from: the title, scenario and a place,
 * 2 to 4 photos and a best one. A draft the teacher is still writing may lack them.
 */
export function readPoint(raw: unknown, strict: boolean, code = 'bad_emergency'): Point {
  if (typeof raw !== 'object' || raw === null) bad(code);
  const p = raw as Record<string, unknown>;
  // Within Georgia and around it: a template for the country's 112.
  if (!isNum(p.lat, 40, 44.5) || !isNum(p.lon, 39.5, 47.5)) bad(code);
  if (typeof p.format !== 'string' || !(FORMATS as readonly string[]).includes(p.format)) bad(code);
  const f = p.facts as Record<string, unknown> | null;
  if (typeof f !== 'object' || f === null) bad(code);
  if (typeof f.kind !== 'string' || !(KINDS as readonly string[]).includes(f.kind)) bad(code);
  if (!isInt(f.people, 1, LIMITS.people) || typeof f.injured !== 'boolean') bad(code);
  if (!Array.isArray(p.photos) || p.photos.length > LIMITS.photosMax) bad(code);
  const photos = p.photos.map((x) => {
    const ph = x as Record<string, unknown> | null;
    if (typeof ph !== 'object' || ph === null || typeof ph.id !== 'string' || !PHOTO_ID.test(ph.id)) bad(code);
    return { id: ph.id, note: str(ph.note, LIMITS.note, code) };
  });
  if (new Set(photos.map((x) => x.id)).size !== photos.length) bad(code);
  const best = p.best;
  if (!isInt(best, 0, Math.max(0, photos.length - 1))) bad(code);
  const point: Point = {
    lat: p.lat,
    lon: p.lon,
    format: p.format,
    title: str(p.title, LIMITS.title, code, strict),
    text: str(p.text, LIMITS.text, code, strict),
    facts: { kind: f.kind, people: f.people, injured: f.injured, landmark: str(f.landmark, LIMITS.landmark, code) },
    photos,
    best,
  };
  if (strict && photos.length < LIMITS.photosMin) bad(code);
  return point;
}

/** A template's data as the teacher saves it (a draft may be unfinished): { points: [...] }. */
export function readTemplateData(raw: unknown): { points: Point[] } {
  if (typeof raw !== 'object' || raw === null) bad();
  const points = (raw as Record<string, unknown>).points;
  if (!Array.isArray(points) || points.length > LIMITS.points) bad();
  return { points: points.map((p) => readPoint(p, false)) };
}

/** A shuffled order of n photos, so the best one isn't always where the teacher put it. */
function shuffled(n: number): number[] {
  const order = Array.from({ length: n }, (_, i) => i);
  const r = crypto.getRandomValues(new Uint32Array(n));
  for (let i = n - 1; i > 0; i--) {
    const j = r[i] % (i + 1);
    [order[i], order[j]] = [order[j], order[i]];
  }
  return order;
}

function checked(raw: Record<string, unknown>, code: string): EmergencySettings {
  if (typeof raw.template !== 'string' || !TEMPLATE_ID.test(raw.template)) bad(code);
  if (!Array.isArray(raw.points) || raw.points.length < 1 || raw.points.length > LIMITS.points) bad(code);
  const points = raw.points.map((p) => readPoint(p, true, code));
  return { template: raw.template, name: str(raw.name, 80, code), points, order: [] };
}

async function makeSettings(body: Record<string, unknown>, env: Env, owner: { admin: boolean; id: string | null }): Promise<EmergencySettings> {
  const id = (body.emergency as Record<string, unknown> | undefined)?.template;
  if (typeof id !== 'string' || !TEMPLATE_ID.test(id)) bad();
  const row = await env.DB.prepare("SELECT name, data FROM templates WHERE id = ? AND game = 'emergency' AND (? = 1 OR teacher_id IS ?)")
    .bind(id, owner.admin ? 1 : 0, owner.id)
    .first<{ name: string; data: string }>();
  if (!row) bad('no_template');
  const s = checked({ ...(JSON.parse(row.data) as Record<string, unknown>), template: id, name: row.name }, 'template_unfinished');
  // Every photo must be there: a session showing broken pictures is no use.
  const heads = await Promise.all(s.points.flatMap((p) => p.photos.map((ph) => env.AREAS.head(photoKey(id, ph.id)))));
  if (heads.some((h) => h === null)) bad('template_photos');
  return { ...s, order: s.points.map((p) => shuffled(p.photos.length)) };
}

/**
 * Which format coordinates are written in, or null: what the operator would have to ask about.
 *   dd   two decimal numbers: 41.71512, 44.82710 (a decimal comma, a degree sign and N/E allowed)
 *   dm   whole degrees and decimal minutes, twice: 41°42.907′ N, 44°49.626′ E
 *   dms  whole degrees, whole minutes and seconds, twice: 41°42′54″ N, 44°49′38″ E
 *   utm  a zone (and band) then 6-digit easting and 7-digit northing: 38T 484380 4618200
 * As lib/emergency/emergency.dart's classifyCoords; test/emergency_test.dart and worker tests share the cases.
 */
export function classifyCoords(text: string): string | null {
  const t = text
    .trim()
    .toUpperCase()
    .replace(/º/g, '°')
    .replace(/[′’']/g, "'")
    .replace(/[″”"]|''/g, '"');
  if (!t || t.length > 80) return null;
  if (/[^0-9A-Z.,;:°'"\s+\-]/.test(t)) return null;
  if (/^\d{1,2}\s*[C-X]?\s+\d{6}(\.\d+)?\s*(M?\s*E)?[\s,;]+\d{7}(\.\d+)?\s*(M?\s*N)?$/.test(t)) return 'utm';
  if (/[A-DF-MO-RT-VX-Z]/.test(t)) return null; // letters other than N, S, E, W
  const numbers = [...t.matchAll(/\d+(?:[.,]\d+)?/g)].map((m) => m[0]);
  const whole = (n: string) => !/[.,]/.test(n);
  const below60 = (n: string) => Number(n.replace(',', '.')) < 60;
  if (numbers.length === 2 && numbers.every((n) => !whole(n))) return 'dd';
  if (numbers.length === 4 && whole(numbers[0]) && whole(numbers[2]) && below60(numbers[1]) && below60(numbers[3])) return 'dm';
  if (
    numbers.length === 6 &&
    [0, 1, 3, 4].every((i) => whole(numbers[i])) &&
    [1, 2, 4, 5].every((i) => below60(numbers[i]))
  ) {
    return 'dms';
  }
  return null;
}

/** 40 within 50 m, 0 from 5 km, the log of the distance in between. */
export function distancePoints(d: number | null): number {
  if (d === null) return 0;
  if (d <= 50) return 40;
  if (d >= 5000) return 0;
  return Math.round(40 * (1 - Math.log10(d / 50) / 2));
}

export type EmergencyAnswer = {
  coords: string;
  at: [number, number] | null;
  kind: string;
  people: number;
  injured: boolean;
  landmark: string;
  photo: string;
};

/** The score of an answer to a point, with its parts: as lib/emergency/emergency.dart's scoreAnswer. */
export function scoreAnswer(p: Point, a: EmergencyAnswer): { distance: number | null; parts: Record<string, number>; total: number } {
  const distance = a.at === null ? null : distanceM(a.at[0], a.at[1], p.lat, p.lon);
  const parts = {
    distance: distancePoints(distance),
    format: classifyCoords(a.coords) === p.format ? 20 : 0,
    message:
      (a.kind === p.facts.kind ? 5 : 0) +
      (a.people === p.facts.people ? 5 : 0) +
      (a.injured === p.facts.injured ? 5 : 0) +
      (a.landmark.trim().length >= 3 ? 5 : 0),
    photo: a.photo === p.photos[p.best].id ? 20 : 0,
  };
  return { distance, parts, total: parts.distance + parts.format + parts.message + parts.photo };
}

export const emergency: GameModule<EmergencySettings> = {
  id: 'emergency',
  timed: false,
  answers: 'first',
  settings: (body, env, owner) => makeSettings(body, env, owner ?? { admin: false, id: null }),
  studentView: (s) => ({
    template: s.template,
    name: s.name,
    points: s.points.map((p, i) => ({
      lat: p.lat,
      lon: p.lon,
      format: p.format,
      title: p.title,
      text: p.text,
      photos: s.order[i].map((k) => p.photos[k].id),
    })),
  }),
  validateAnswer(raw) {
    if (typeof raw !== 'object' || raw === null) bad('bad_answer');
    const a = raw as Record<string, unknown>;
    const coords = typeof a.coords === 'string' ? a.coords.trim() : null;
    if (coords === null || coords.length > 80) bad('bad_answer');
    let at: [number, number] | null = null;
    if (a.at !== null && a.at !== undefined) {
      if (!Array.isArray(a.at) || a.at.length !== 2 || !isNum(a.at[0], -90, 90) || !isNum(a.at[1], -180, 180)) bad('bad_answer');
      at = [a.at[0], a.at[1]];
    }
    if (typeof a.kind !== 'string' || !(KINDS as readonly string[]).includes(a.kind)) bad('bad_answer');
    if (!isInt(a.people, 0, LIMITS.people) || typeof a.injured !== 'boolean') bad('bad_answer');
    if (typeof a.photo !== 'string' || !PHOTO_ID.test(a.photo)) bad('bad_answer');
    const landmark = typeof a.landmark === 'string' ? a.landmark.trim() : null;
    if (landmark === null || landmark.length > LIMITS.landmark) bad('bad_answer');
    return { coords, at, kind: a.kind, people: a.people, injured: a.injured, landmark, photo: a.photo };
  },
  score(s, answer, _place, round) {
    if (!isInt(round, 0, s.points.length - 1)) throw new HttpError(400, 'bad_round');
    const a = answer as unknown as EmergencyAnswer;
    const p = s.points[round];
    if (!p.photos.some((ph) => ph.id === a.photo)) throw new HttpError(400, 'bad_answer');
    const r = scoreAnswer(p, a);
    return { round, distance: r.distance, score: r.total };
  },
  feedback(s, row) {
    const p = s.points[row.round];
    if (!p) return { score: row.score };
    return { score: row.score, truth: [p.lat, p.lon], facts: p.facts, best: p.photos[p.best].id, notes: Object.fromEntries(p.photos.map((ph) => [ph.id, ph.note])) };
  },
  restoreSettings(raw) {
    if (typeof raw !== 'object' || raw === null) bad();
    const r = raw as Record<string, unknown>;
    const s = checked(r, 'bad_emergency');
    const order = r.order;
    const ok =
      Array.isArray(order) &&
      order.length === s.points.length &&
      order.every((o, i) => Array.isArray(o) && o.length === s.points[i].photos.length && [...o].sort().every((v, k) => v === k));
    if (!ok) bad();
    return { ...s, order: order as number[][] };
  },
};
