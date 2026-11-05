export class HttpError extends Error {
  constructor(public status: number, public key: string) {
    super(key);
  }
}

const TRANSPORT = ['plane', 'train', 'car', 'bus', 'ship', 'bike', 'foot'];
const COMPANY = ['alone', 'family', 'friends', 'class'];
const MODES = ['to_map', 'read'];
const FORMATS = ['dd', 'dm', 'dms', 'utm'];
const MAX_TASKS = 30;
const KINDS = ['point', 'line', 'polygon'];
const CATEGORIES = ['food', 'icecream', 'cinema', 'stadium', 'square', 'park', 'attraction', 'school', 'shop', 'museum', 'other'];
const MIN_VERTICES: Record<string, number> = { point: 1, line: 2, polygon: 3 };
const MAX_VERTICES = 100;
// A file directly in web/aerial, so a task can't point anywhere else. The cards game uses web/cards the same way.
const PHOTO_RE = /^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$/;
export const MIN_PAIRS = 2;
export const MAX_PAIRS = 12;
const ROTATIONS = ['none', 'quarter', 'any'];

function text(value: unknown, max: number, required: boolean): string {
  const s = typeof value === 'string' ? value.trim() : '';
  if ((required && !s) || s.length > max) throw new HttpError(400, 'bad_answer');
  return s;
}

function oneOf(value: unknown, allowed: string[]): string {
  if (typeof value !== 'string' || !allowed.includes(value)) throw new HttpError(400, 'bad_answer');
  return value;
}

/** Returns only the known fields, so nothing else a client sends gets stored. */
export function validateAnswer(game: string, raw: unknown): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null) throw new HttpError(400, 'bad_answer');
  const a = raw as Record<string, unknown>;
  if (game === 'travel') {
    const country = text(a.country, 2, false).toUpperCase();
    if (country && !/^[A-Z]{2}$/.test(country)) throw new HttpError(400, 'bad_answer');
    return {
      place: text(a.place, 120, true),
      country,
      reason: text(a.reason, 500, false),
      transport: oneOf(a.transport, TRANSPORT),
      company: oneOf(a.company, COMPANY),
    };
  }
  if (game === 'coordinates') {
    return { raw: text(a.raw, 60, false), format: oneOf(a.format, FORMATS), mode: oneOf(a.mode, MODES) };
  }
  // The round and the point say everything about an aerial answer.
  if (game === 'aerial') return {};
  if (game === 'mapping') {
    const kind = oneOf(a.kind, KINDS);
    if (!Array.isArray(a.coords) || a.coords.length < MIN_VERTICES[kind] || a.coords.length > MAX_VERTICES) {
      throw new HttpError(400, 'bad_answer');
    }
    if (kind === 'point' && a.coords.length !== 1) throw new HttpError(400, 'bad_answer');
    const coords = a.coords.map((c: unknown) => {
      const [lon, lat] = Array.isArray(c) ? c : [];
      if (typeof lon !== 'number' || typeof lat !== 'number' || !(Math.abs(lat) <= 90) || !(Math.abs(lon) <= 180)) {
        throw new HttpError(400, 'bad_answer');
      }
      return [Math.round(lon * 1e6) / 1e6, Math.round(lat * 1e6) / 1e6];
    });
    return { kind, category: oneOf(a.category, CATEGORIES), coords };
  }
  if (game === 'cards') {
    // Either a found pair (its number) or a wrong try (the pairs of the two cards, for the teacher's statistics).
    if (typeof a.ok !== 'boolean') throw new HttpError(400, 'bad_answer');
    const index = (v: unknown) => {
      if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v >= MAX_PAIRS) throw new HttpError(400, 'bad_answer');
      return v;
    };
    if (a.ok) return { ok: true, pair: index(a.pair) };
    return { ok: false, x: index(a.x), y: index(a.y) };
  }
  throw new HttpError(400, 'bad_game');
}

export type CardPair = { a: string; b: string; label: string; labelEn: string; ra: number; rb: number };
export type CardsSettings = { pairs: CardPair[]; arrow: boolean; rotation: string };

/** The deck of the cards game. Angles are fixed here so every student gets the same difficulty. */
export function validateCards(raw: unknown): CardsSettings {
  const c = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>;
  if (!Array.isArray(c.pairs) || c.pairs.length < MIN_PAIRS || c.pairs.length > MAX_PAIRS) throw new HttpError(400, 'bad_cards');
  const angle = (v: unknown) => {
    if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > 359) throw new HttpError(400, 'bad_cards');
    return v;
  };
  const pairs = c.pairs.map((p: Record<string, unknown>) => {
    if (typeof p?.a !== 'string' || !PHOTO_RE.test(p.a) || typeof p.b !== 'string' || !PHOTO_RE.test(p.b) || p.a === p.b) {
      throw new HttpError(400, 'bad_cards');
    }
    const label = text(p.label, 120, false);
    const labelEn = text(p.labelEn ?? '', 120, false);
    return { a: p.a, b: p.b, label, labelEn, ra: angle(p.ra ?? 0), rb: angle(p.rb ?? 0) };
  });
  return { pairs, arrow: c.arrow === true, rotation: oneOf(c.rotation ?? 'none', ROTATIONS) };
}

export type Task = { lat: number; lon: number; mode: string; format: string; label: string; labelEn?: string; photo?: string };

export function validateTasks(game: string, raw: unknown): Task[] {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_TASKS) throw new HttpError(400, 'bad_tasks');
  return raw.map((t: Record<string, unknown>) => {
    const { lat, lon } = t ?? {};
    if (typeof lat !== 'number' || typeof lon !== 'number' || !(Math.abs(lat) <= 90) || !(Math.abs(lon) <= 180)) {
      throw new HttpError(400, 'bad_tasks');
    }
    if (typeof t.label === 'string' && t.label.length > 120) throw new HttpError(400, 'bad_tasks');
    if (game === 'aerial') {
      if (typeof t.photo !== 'string' || !PHOTO_RE.test(t.photo)) throw new HttpError(400, 'bad_tasks');
      if (typeof t.labelEn === 'string' && t.labelEn.length > 120) throw new HttpError(400, 'bad_tasks');
      return {
        lat,
        lon,
        mode: 'photo',
        format: 'dd',
        label: typeof t.label === 'string' ? t.label : '',
        labelEn: typeof t.labelEn === 'string' ? t.labelEn : '',
        photo: t.photo,
      };
    }
    if (!MODES.includes(t.mode as string) || !FORMATS.includes(t.format as string)) throw new HttpError(400, 'bad_tasks');
    return { lat, lon, mode: t.mode as string, format: t.format as string, label: typeof t.label === 'string' ? t.label : '' };
  });
}

/** The middle of a drawn object's vertices, as [lon, lat]. */
export function middle(coords: number[][]): [number, number] {
  return [coords.reduce((sum, c) => sum + c[0], 0) / coords.length, coords.reduce((sum, c) => sum + c[1], 0) / coords.length];
}

/** Great-circle distance in metres. lib/coords.dart uses the same formula for instant feedback. */
export function distanceM(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371008.8 * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** 100 within 1 km, 50 at 10 km, 0 from 100 km. */
export function scoreFor(distance: number): number {
  if (distance <= 1000) return 100;
  if (distance >= 100000) return 0;
  return Math.round(100 * (1 - Math.log10(distance / 1000) / 2));
}
