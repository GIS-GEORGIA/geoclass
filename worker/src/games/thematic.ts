import { HttpError } from '../validate';
import type { GameModule } from './types';

/**
 * Thematic map: the teacher brings a table of numbers by region or municipality (read and matched to the
 * units on the teacher's device, lib/thematic/thematic.dart); students choose a field, whether to show it per
 * km², the classification method, the number of classes and a colour ramp, and get a choropleth with its
 * legend.
 *
 * Two modes. 'target': the teacher sets the choice that suits the data; it stays here until the student has
 * answered, and the score is 25 for each of the field, the normalisation, the method and the number of classes
 * that match it. 'free': no target and no score; the teacher sees every student's map.
 * One answer per student, the first one counts.
 */

export const THEMATIC_LEVELS = ['regions', 'municipalities'];
export const THEMATIC_METHODS = ['equal', 'quantile', 'jenks', 'manual'];
export const THEMATIC_NORMALISATIONS = ['none', 'area'];
export const THEMATIC_RAMPS = ['Blues', 'Greens', 'Oranges', 'Purples', 'YlGnBu', 'YlOrRd'];
const KINDS = ['count', 'rate'];
const CLASSES = { min: 3, max: 7 };
const UNITS_MAX = 80;
const FIELDS_MAX = 4;

export type ThematicChoice = {
  field: number;
  normalise: string;
  method: string;
  classes: number;
  ramp: string;
  breaks?: number[];
};

export type ThematicSettings = {
  level: string;
  title: string;
  mode: 'target' | 'free';
  units: string[];
  fields: { name: string; kind: string; values: (number | null)[] }[];
  target?: ThematicChoice;
};

function bad(code = 'bad_thematic'): never {
  throw new HttpError(400, code);
}

const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isText = (v: unknown, max: number): v is string => typeof v === 'string' && v.length <= max;

/** A choice, the teacher's target or a student's answer; [fields] the number of fields it may pick from. */
function readChoice(raw: unknown, fields: number, code: string, target: boolean): ThematicChoice {
  if (typeof raw !== 'object' || raw === null) bad(code);
  const r = raw as Record<string, unknown>;
  if (!isInt(r.field, 0, fields - 1) || !THEMATIC_NORMALISATIONS.includes(r.normalise as string)) bad(code);
  // The target is a method the computer works out by itself: not manual breaks.
  const methods = target ? THEMATIC_METHODS.filter((m) => m !== 'manual') : THEMATIC_METHODS;
  if (!methods.includes(r.method as string) || !isInt(r.classes, CLASSES.min, CLASSES.max)) bad(code);
  const ramp = r.ramp === undefined ? 'Blues' : r.ramp;
  if (!THEMATIC_RAMPS.includes(ramp as string)) bad(code);
  const out: ThematicChoice = {
    field: r.field as number,
    normalise: r.normalise as string,
    method: r.method as string,
    classes: r.classes as number,
    ramp: ramp as string,
  };
  if (r.method === 'manual') {
    const b = r.breaks;
    if (!Array.isArray(b) || b.length !== out.classes - 1 || !b.every((x) => typeof x === 'number' && Number.isFinite(x))) bad(code);
    for (let i = 1; i < b.length; i++) if (!(b[i] > b[i - 1])) bad(code);
    out.breaks = b as number[];
  }
  return out;
}

function readSettings(raw: unknown): ThematicSettings {
  if (typeof raw !== 'object' || raw === null) bad();
  const r = raw as Record<string, unknown>;
  if (!THEMATIC_LEVELS.includes(r.level as string) || !isText(r.title, 80)) bad();
  if (r.mode !== 'target' && r.mode !== 'free') bad();
  const units = r.units;
  if (!Array.isArray(units) || units.length < 2 || units.length > UNITS_MAX) bad();
  if (!units.every((u) => typeof u === 'string' && /^ge_[a-z_]{2,60}$/.test(u)) || new Set(units).size !== units.length) bad();
  const fields = r.fields;
  if (!Array.isArray(fields) || fields.length < 1 || fields.length > FIELDS_MAX) bad();
  const read = fields.map((f) => {
    if (typeof f !== 'object' || f === null) bad();
    const { name, kind, values } = f as Record<string, unknown>;
    if (!isText(name, 60) || (name as string).trim() === '' || !KINDS.includes(kind as string)) bad();
    if (!Array.isArray(values) || values.length !== units.length) bad();
    if (!values.every((v) => v === null || (typeof v === 'number' && Number.isFinite(v)))) bad();
    if (!values.some((v) => v !== null)) bad();
    return { name: name as string, kind: kind as string, values: values as (number | null)[] };
  });
  const out: ThematicSettings = { level: r.level as string, title: r.title as string, mode: r.mode, units: units as string[], fields: read };
  if (r.mode === 'target') out.target = readChoice(r.target, read.length, 'bad_thematic', true);
  else if (r.target !== undefined) bad();
  return out;
}

/** 25 for each of the field, the normalisation, the method and the number of classes that match the target. */
export function thematicScore(target: ThematicChoice, answer: ThematicChoice): number {
  return (
    (answer.field === target.field ? 25 : 0) +
    (answer.normalise === target.normalise ? 25 : 0) +
    (answer.method === target.method ? 25 : 0) +
    (answer.classes === target.classes ? 25 : 0)
  );
}

export const thematic: GameModule<ThematicSettings> = {
  id: 'thematic',
  timed: false,
  answers: 'first',
  settings: (body) => readSettings(body.thematic),
  studentView: (s) => ({ level: s.level, title: s.title, mode: s.mode, units: s.units, fields: s.fields }),
  validateAnswer: (raw, s) => readChoice(raw, s.fields.length, 'bad_answer', false),
  score(s, answer, _place, round) {
    if (round !== 0) throw new HttpError(400, 'bad_round');
    const score = s.target ? thematicScore(s.target, answer as unknown as ThematicChoice) : null;
    return { round: 0, distance: null, score };
  },
  feedback: (s, row) => (s.target ? { score: row.score, target: s.target } : {}),
  restoreSettings: readSettings,
};
