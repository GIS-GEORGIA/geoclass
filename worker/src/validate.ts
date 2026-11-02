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
// A file directly in web/aerial, so a task can't point anywhere else.
const PHOTO_RE = /^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$/;

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
export function validateAnswer(game: string, raw: unknown): Record<string, string> {
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
  throw new HttpError(400, 'bad_game');
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
