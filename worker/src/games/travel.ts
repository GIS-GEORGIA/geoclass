import { HttpError } from '../validate';
import type { GameModule } from './types';

const TRANSPORT = ['plane', 'train', 'car', 'bus', 'ship', 'bike', 'foot'];
const COMPANY = ['alone', 'family', 'friends', 'class'];

function text(value: unknown, max: number, required: boolean): string {
  const s = typeof value === 'string' ? value.trim() : '';
  if ((required && !s) || s.length > max) throw new HttpError(400, 'bad_answer');
  return s;
}

function oneOf(value: unknown, allowed: string[]): string {
  if (typeof value !== 'string' || !allowed.includes(value)) throw new HttpError(400, 'bad_answer');
  return value;
}

/** Travel: each student pins a place they'd like to go and says why, how and with whom. Nothing is scored. */
export const travel: GameModule<Record<string, never>> = {
  id: 'travel',
  timed: false,
  answers: 'replace',
  settings: () => ({}),
  studentView: (settings) => settings,
  validateAnswer(raw) {
    if (typeof raw !== 'object' || raw === null) throw new HttpError(400, 'bad_answer');
    const a = raw as Record<string, unknown>;
    const country = text(a.country, 2, false).toUpperCase();
    if (country && !/^[A-Z]{2}$/.test(country)) throw new HttpError(400, 'bad_answer');
    return {
      place: text(a.place, 120, true),
      country,
      reason: text(a.reason, 500, false),
      transport: oneOf(a.transport, TRANSPORT),
      company: oneOf(a.company, COMPANY),
    };
  },
  score: () => ({ round: 0, distance: null, score: null }),
  feedback: () => ({}),
  restoreSettings: () => ({}),
};
