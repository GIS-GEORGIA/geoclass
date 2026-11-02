export class HttpError extends Error {
  constructor(public status: number, public key: string) {
    super(key);
  }
}

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
  throw new HttpError(400, 'bad_game');
}
