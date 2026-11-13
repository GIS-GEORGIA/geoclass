import { HttpError } from '../validate';
import type { GameModule } from './types';

/**
 * Terrain profile: the teacher draws a line on one of the terrain areas; students see the height profile along
 * it and answer questions by reading the chart.
 *
 * The right answers are worked out by the teacher's app from the same terrain grid when the session is made
 * (lib/terrain/profile.dart, checked against GDAL) and stored here; the server scores against them and never
 * sends them before a question is answered. The first answer to each question counts.
 */

export const PROFILE_KINDS = ['max', 'min', 'length', 'steepest', 'where_max'] as const;
export type ProfileKind = (typeof PROFILE_KINDS)[number];

export type ProfileQuestion = { kind: ProfileKind; answer: number; tolerance?: number };
export type ProfileSettings = {
  area: { id: string; version: number };
  /** Vertices as [lat, lon]. */
  line: [number, number][];
  /** Metres along the ground, first vertex to last. */
  length: number;
  questions: ProfileQuestion[];
};

const MAX_VERTICES = 10;
const MAX_QUESTIONS = 10;
/** Heights: the Dead Sea shore to above Everest, so any real area fits. */
const HEIGHT = [-500, 9000];
/** Default and allowed tolerance for a height answer, in metres. */
const HEIGHT_TOLERANCE = { default: 50, min: 5, max: 1000 };
/** A line's length: up to the diagonal of the largest area, with room to spare. */
const MAX_LENGTH = 500_000;

function bad(code = 'bad_profile'): never {
  throw new HttpError(400, code);
}

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

function readSettings(raw: unknown): ProfileSettings {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  const area = r.area as Record<string, unknown> | undefined;
  if (
    typeof area !== 'object' ||
    area === null ||
    typeof area.id !== 'string' ||
    !/^[a-z0-9-]{1,40}$/.test(area.id) ||
    !Number.isInteger(area.version) ||
    (area.version as number) < 1 ||
    (area.version as number) > 9999
  ) {
    bad();
  }
  if (!Array.isArray(r.line) || r.line.length < 2 || r.line.length > MAX_VERTICES) bad();
  const line = r.line.map((p) => {
    if (!Array.isArray(p) || p.length !== 2 || !isNum(p[0]) || !isNum(p[1]) || Math.abs(p[0]) > 90 || Math.abs(p[1]) > 180) bad();
    return [p[0], p[1]] as [number, number];
  });
  if (!isNum(r.length) || r.length <= 0 || r.length > MAX_LENGTH) bad();
  const length = r.length;
  const sections = line.length - 1;
  if (!Array.isArray(r.questions) || r.questions.length < 1 || r.questions.length > MAX_QUESTIONS) bad();
  const questions = r.questions.map((q): ProfileQuestion => {
    if (typeof q !== 'object' || q === null) bad();
    const { kind, answer, tolerance } = q as Record<string, unknown>;
    if (!PROFILE_KINDS.includes(kind as ProfileKind) || !isNum(answer)) bad();
    switch (kind as ProfileKind) {
      case 'max':
      case 'min': {
        if (answer < HEIGHT[0] || answer > HEIGHT[1]) bad();
        const t = tolerance === undefined ? HEIGHT_TOLERANCE.default : tolerance;
        if (!isNum(t) || t < HEIGHT_TOLERANCE.min || t > HEIGHT_TOLERANCE.max) bad();
        return { kind: kind as ProfileKind, answer, tolerance: t };
      }
      case 'length':
        if (Math.abs(answer - length) > 1e-6 * length + 0.01) bad();
        return { kind: 'length', answer };
      case 'steepest':
        // With one section there is nothing to choose between.
        if (sections < 2 || !Number.isInteger(answer) || answer < 0 || answer >= sections) bad();
        return { kind: 'steepest', answer };
      case 'where_max':
        if (answer < 0 || answer > length) bad();
        return { kind: 'where_max', answer };
    }
  });
  return { area: { id: area!.id as string, version: area!.version as number }, line, length, questions };
}

/** Full marks up to [full], none from [zero], in a straight line between. */
export function falloff(error: number, full: number, zero: number): number {
  if (error <= full) return 100;
  if (error >= zero) return 0;
  return Math.round((100 * (zero - error)) / (zero - full));
}

/** The score of one answer to one question: heights and the top's place within tolerance, length within 10 %. */
export function scoreProfile(q: ProfileQuestion, value: number, length: number): number {
  switch (q.kind) {
    case 'max':
    case 'min': {
      const t = q.tolerance ?? HEIGHT_TOLERANCE.default;
      return falloff(Math.abs(value - q.answer), t, 3 * t);
    }
    case 'length':
      return falloff(Math.abs(value - q.answer) / q.answer, 0.1, 0.3);
    case 'steepest':
      return value === q.answer ? 100 : 0;
    case 'where_max':
      // On a short line, 100 m is a large part of it: the full-marks distance is at most a tenth of the line.
      return falloff(Math.abs(value - q.answer), Math.min(100, length / 10), Math.min(1000, length / 2));
  }
}

export const profile: GameModule<ProfileSettings> = {
  id: 'profile',
  timed: false,
  answers: 'first',
  settings: (body) => readSettings(body.profile),
  studentView: (s) => ({
    area: s.area,
    line: s.line,
    // Height questions say how close is close enough; nothing else about the answer goes out.
    questions: s.questions.map((q) => (q.tolerance === undefined ? { kind: q.kind } : { kind: q.kind, tolerance: q.tolerance })),
  }),
  validateAnswer(raw) {
    if (typeof raw !== 'object' || raw === null) bad('bad_answer');
    const { kind, value } = raw as Record<string, unknown>;
    if (!PROFILE_KINDS.includes(kind as ProfileKind) || !isNum(value) || Math.abs(value) > 1e7) bad('bad_answer');
    if (kind === 'steepest' && !Number.isInteger(value)) bad('bad_answer');
    return { kind, value };
  },
  score(s, answer, _place, round) {
    const q = typeof round === 'number' ? s.questions[round] : undefined;
    if (!q) throw new HttpError(400, 'bad_round');
    if (answer.kind !== q.kind) bad('bad_answer');
    return { round: round as number, distance: null, score: scoreProfile(q, answer.value as number, s.length) };
  },
  feedback(s, row) {
    const q = s.questions[row.round];
    return q ? { score: row.score, kind: q.kind, answer: q.answer } : {};
  },
  restoreSettings: readSettings,
};
