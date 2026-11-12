import {
  HttpError,
  QUESTIONS,
  distanceM,
  middle,
  scoreEvidence,
  scoreFor,
  validateAnswer,
  validateCards,
  validatePuzzle,
  validateLayout,
  scoreLayout,
  type LayoutSettings,
  validateEvidence,
  validatePlates,
  validateTasks,
  type PlatesSettings,
  type CardsSettings,
  type EvidenceTask,
  type Task,
} from './validate';
import { KEEP_SEC, deleteOld, deleteOldAuthFailures, deleteOldTeachers } from './retention';

const MAX_RESPONSES_PER_SESSION = 2000;
const MAX_BODY_BYTES = 8 * 1024;
const MAX_RESTORE_BYTES = 4 * 1024 * 1024;
const D1_BATCH_SIZE = 50;
const ID_RE = /^[A-Za-z0-9_-]{8,64}$/;
const MAX_OBJECTS_PER_STUDENT = 200;
// An object drawn at the last second still reaches the server.
const TIME_UP_GRACE_SEC = 15;
// Drawing the same place twice doesn't count twice.
const SAME_PLACE_M = 10;
const MAX_TIMER_SEC = 3600;
// Wrong tries in the cards game are told apart from found pairs by their number.
const MISTAKE_ROUND_FROM = 100;
const MAX_MISTAKES_PER_STUDENT = 300;
// Failed teacher sign-ins allowed per address in AUTH_WINDOW_SEC; after that every teacher call from it gets 429.
const AUTH_MAX_FAILURES = 10;
const AUTH_WINDOW_SEC = 60;

const CORS = {
  'Access-Control-Allow-Origin': '*', // no cookies: every teacher call carries its own bearer key
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization,Content-Type',
};

const nowSec = () => Math.floor(Date.now() / 1000);

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...CORS },
  });
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function readBody<T>(request: Request, maxBytes = MAX_BODY_BYTES): Promise<T> {
  const text = await request.text();
  if (text.length > maxBytes) throw new HttpError(413, 'too_large');
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new HttpError(400, 'bad_json');
  }
}

/**
 * The teacher key, with a limit on wrong guesses. The limit is checked before the key, so once an address has
 * failed AUTH_MAX_FAILURES times in a window even the right key gets 429 until the window ends: a guess that
 * happens to be right can't be told apart from a wrong one. Failures are counted in D1 because the rate limit
 * binding can't be read without counting a request, and valid teacher calls (polling) must not use it up.
 */
/** Who made a teacher call: the owner (everything), or a teacher with their own key (their own sessions only). */
type Actor = { admin: true; id: null; name: null; expiresAt: null } | { admin: false; id: string; name: string; expiresAt: number };
const OWNER: Actor = { admin: true, id: null, name: null, expiresAt: null };

async function requireTeacher(env: Env, request: Request): Promise<Actor> {
  // Keyed with the key's hash, a secret, so the stored value can't be turned back into an address by trying them all.
  const ipHash = await sha256(`auth:${env.TEACHER_KEY_HASH ?? ''}:${request.headers.get('CF-Connecting-IP') ?? 'unknown'}`);
  const now = nowSec();
  const windowFrom = now - AUTH_WINDOW_SEC;
  const failed = await env.DB.prepare('SELECT count FROM auth_failures WHERE ip_hash = ? AND window_start > ?')
    .bind(ipHash, windowFrom)
    .first<{ count: number }>();
  if ((failed?.count ?? 0) >= AUTH_MAX_FAILURES) throw new HttpError(429, 'rate_limited');

  const header = request.headers.get('Authorization') ?? '';
  const key = header.startsWith('Bearer ') ? header.slice(7) : '';
  let error = 'unauthorized';
  if (key) {
    const hash = await sha256(key);
    if (env.TEACHER_KEY_HASH && hash === env.TEACHER_KEY_HASH) return OWNER;
    const t = await env.DB.prepare('SELECT id, name, expires_at, revoked_at FROM teachers WHERE key_hash = ?')
      .bind(hash)
      .first<{ id: string; name: string; expires_at: number; revoked_at: number | null }>();
    if (t && t.revoked_at === null && t.expires_at > now) return { admin: false, id: t.id, name: t.name, expiresAt: t.expires_at };
    // The key was real once: say so, so the app can tell the teacher why.
    if (t) error = 'key_expired';
  }

  await env.DB.prepare(
    `INSERT INTO auth_failures (ip_hash, window_start, count) VALUES (?, ?, 1)
     ON CONFLICT (ip_hash) DO UPDATE SET
       count = CASE WHEN window_start > ? THEN count + 1 ELSE 1 END,
       window_start = CASE WHEN window_start > ? THEN window_start ELSE excluded.window_start END`,
  )
    .bind(ipHash, now, windowFrom, windowFrom)
    .run();
  throw new HttpError(401, error);
}

function requireOwner(actor: Actor): void {
  if (!actor.admin) throw new HttpError(403, 'forbidden');
}

type SessionRow = {
  id: string;
  name: string;
  game: string;
  status: string;
  rev: number;
  archived: number;
  settings: string;
  created_at: number;
  teacher_id: string | null;
  teacher_name?: string | null;
};

const SESSION_COLUMNS = 'id, name, game, status, rev, archived, settings, created_at, teacher_id';
const GAMES = ['travel', 'coordinates', 'aerial', 'mapping', 'cards', 'evidence', 'plates', 'puzzle', 'layout'];
// Games played against the teacher's clock.
const TIMED_GAMES = ['mapping', 'cards', 'puzzle'];
// Games made of tasks that the server scores.
const TASK_GAMES = ['coordinates', 'aerial'];
// Games whose answers stay on the server unless the teacher chose the offline mode.
const PROTECTED_GAMES = ['aerial', 'evidence', 'cards'];
const ANSWER_MODES = ['online', 'offline'];

function sessionJson(s: SessionRow, count?: number) {
  return {
    id: s.id,
    name: s.name,
    game: s.game,
    status: s.status,
    rev: s.rev,
    archived: s.archived === 1,
    settings: JSON.parse(s.settings),
    createdAt: s.created_at,
    now: nowSec(), // so a device with a wrong clock still shows the right time left
    teacherId: s.teacher_id ?? null,
    ...(s.teacher_name ? { teacherName: s.teacher_name } : {}),
    ...(count === undefined ? {} : { responses: count }),
  };
}

type ResponseRow = {
  id: string;
  session_id: string;
  participant_id: string;
  round: number;
  answer: string;
  lat: number;
  lon: number;
  distance_m: number | null;
  score: number | null;
  hidden: number;
  accepted: number;
  created_at: number;
};

function responseJson(r: ResponseRow) {
  return {
    id: r.id,
    sessionId: r.session_id,
    participantId: r.participant_id,
    round: r.round,
    answer: JSON.parse(r.answer),
    lat: r.lat,
    lon: r.lon,
    distanceM: r.distance_m,
    score: r.score,
    hidden: r.hidden === 1,
    accepted: r.accepted === 1,
    createdAt: r.created_at,
  };
}

function cleanName(value: unknown): string {
  const name = typeof value === 'string' ? value.trim() : '';
  if (!name || name.length > 100) throw new HttpError(400, 'bad_name');
  return name;
}

/** A session the actor may touch: any for the owner, only their own for a teacher. Someone else's is a 404. */
async function sessionOr404(env: Env, id: string, actor: Actor): Promise<SessionRow> {
  const s = await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE id = ? AND (? = 1 OR teacher_id = ?)`)
    .bind(id, actor.admin ? 1 : 0, actor.id ?? '')
    .first<SessionRow>();
  if (!s) throw new HttpError(404, 'not_found');
  return s;
}

async function sessionByToken(env: Env, token: unknown): Promise<SessionRow> {
  if (typeof token !== 'string' || !token || token.length > 100) throw new HttpError(404, 'not_found');
  const hash = await sha256(token);
  const s = await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE token_hash = ? AND archived = 0`)
    .bind(hash)
    .first<SessionRow>();
  if (!s) throw new HttpError(404, 'not_found');
  return s;
}

const bumpRev = (env: Env, id: string) => env.DB.prepare('UPDATE sessions SET rev = rev + 1 WHERE id = ?').bind(id);

// --- Student endpoints: only a QR token, and never another student's data ---

async function join(env: Env, request: Request): Promise<Response> {
  const { token } = await readBody<{ token?: unknown }>(request);
  const s = await sessionByToken(env, token);
  const settings = JSON.parse(s.settings);
  return json({
    name: s.name,
    game: s.game,
    status: s.status,
    settings: studentSettings(s.game, settings, s.id),
    now: nowSec(),
  });
}

/**
 * What a student's device may know before answering. Teachers get the full settings.
 * Online mode keeps the right answers on the server; the result comes back from submit.
 * Sessions from before the choice existed have no mode and stay as they were: offline.
 */
export function studentSettings(game: string, settings: Record<string, unknown>, sessionId: string): Record<string, unknown> {
  if (game === 'plates') return studentPlates(settings as PlatesSettings);
  if (!PROTECTED_GAMES.includes(game) || settings.answers !== 'online') return settings;
  if (game === 'cards') {
    // Cards by their place in the session's hidden order, each with its turn. The pictures come through
    // cardImage under the same ids, because the file names give the pairs away.
    const { pairs, order, ...rest } = settings as CardsSettings & { order: number[] };
    const canonical = pairs.flatMap((p) => [p.ra, p.rb]);
    return { ...rest, session: sessionId, cards: order.map((c, id) => ({ id, r: canonical[c] })) };
  }
  const tasks = settings.tasks as Record<string, unknown>[];
  return {
    ...settings,
    tasks:
      game === 'aerial'
        ? tasks.map((t) => ({ mode: t.mode, format: t.format, photo: t.photo }))
        : // The coordinates are on the picture itself, so only the names are kept back.
          tasks.map((t) => ({ kind: t.kind, lat: t.lat, lon: t.lon, shown: t.shown, ask: t.ask, questions: t.questions, converter: t.converter, seed: t.seed })),
  };
}

/** Students get only the plate on the screen now, not the ones still to come. Past the last one it's null. */
function studentPlates(p: PlatesSettings) {
  return { plate: p.deck[p.at] ?? null, at: p.at, count: p.deck.length, revealed: p.revealed };
}

/** A random order of the deck's cards (pair * 2 + side), kept on the server. A card's id is its place in it. */
export function shuffledCards(pairs: number): number[] {
  const order = Array.from({ length: pairs * 2 }, (_, i) => i);
  const random = new Uint32Array(order.length);
  crypto.getRandomValues(random);
  for (let i = order.length - 1; i > 0; i--) {
    const j = random[i] % (i + 1);
    [order[i], order[j]] = [order[j], order[i]];
  }
  return order;
}

/**
 * The card (pair * 2 + side) a student's card id stands for. Online, the ids are places in the hidden order;
 * offline the device knows the pairs and sends that number itself.
 */
function cardOf(settings: CardsSettings & { order?: number[] }, id: number): number | undefined {
  const card = settings.answers === 'online' ? settings.order?.[id] : id;
  return card !== undefined && card < settings.pairs.length * 2 ? card : undefined;
}

/** The picture of a card in an online cards session, under its id. */
async function cardImage(env: Env, sessionId: string, cardId: string): Promise<Response> {
  const s = await env.DB.prepare('SELECT game, settings FROM sessions WHERE id = ? AND archived = 0')
    .bind(sessionId)
    .first<{ game: string; settings: string }>();
  const settings = s?.game === 'cards' ? (JSON.parse(s.settings) as CardsSettings & { order?: number[] }) : undefined;
  const card = settings?.answers === 'online' && /^\d{1,3}$/.test(cardId) ? cardOf(settings, Number(cardId)) : undefined;
  if (!settings || card === undefined) throw new HttpError(404, 'not_found');
  const pair = settings.pairs[Math.floor(card / 2)];
  const file = card % 2 === 0 ? pair.a : pair.b;
  const picture = await env.ASSETS.fetch(new Request(`https://assets.local/cards/${file}`));
  if (!picture.ok) throw new HttpError(404, 'not_found');
  return new Response(picture.body, {
    headers: {
      'Content-Type': picture.headers.get('Content-Type') ?? 'application/octet-stream',
      'Cache-Control': 'private, max-age=86400',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

async function submit(env: Env, request: Request): Promise<Response> {
  const limited = await env.SUBMIT_LIMIT?.limit({ key: request.headers.get('CF-Connecting-IP') ?? 'unknown' });
  if (limited && !limited.success) throw new HttpError(429, 'rate_limited');

  const body = await readBody<{
    token?: unknown;
    submissionId?: unknown;
    participantId?: unknown;
    answer?: unknown;
    lat?: unknown;
    lon?: unknown;
    round?: unknown;
  }>(request);
  const s = await sessionByToken(env, body.token);

  const submissionId = body.submissionId;
  const participantId = body.participantId;
  if (typeof submissionId !== 'string' || !ID_RE.test(submissionId)) throw new HttpError(400, 'bad_id');
  if (typeof participantId !== 'string' || !ID_RE.test(participantId)) throw new HttpError(400, 'bad_id');

  // Checked before the status, so a retry of a stored answer succeeds even after the session closes.
  const existing = await env.DB.prepare('SELECT session_id, round, score, distance_m, answer FROM responses WHERE id = ?')
    .bind(submissionId)
    .first<StoredAnswer & { session_id: string; answer: string }>();
  if (existing) {
    const mine = existing.session_id === s.id;
    const match = mine && s.game === 'cards' ? { match: JSON.parse(existing.answer).ok === true } : {};
    return json({ ok: true, duplicate: true, ...(mine ? answerResult(s, existing) : {}), ...match });
  }

  if (s.status !== 'open') throw new HttpError(409, `session_${s.status}`);

  const { lat, lon } = body;
  if (typeof lat !== 'number' || typeof lon !== 'number' || !(Math.abs(lat) <= 90) || !(Math.abs(lon) <= 180)) {
    throw new HttpError(400, 'bad_location');
  }
  const answer = validateAnswer(s.game, body.answer);
  if (s.game === 'mapping') return submitObject(env, s, submissionId, participantId, answer);
  if (s.game === 'cards' || s.game === 'puzzle') return submitCardTry(env, s, submissionId, participantId, answer);
  if (s.game === 'layout') return submitLayout(env, s, submissionId, participantId, answer);
  if (s.game === 'evidence') return submitEvidence(env, s, submissionId, participantId, answer, body.round, lat, lon);

  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ? AND participant_id != ?')
    .bind(s.id, participantId)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');

  if (TASK_GAMES.includes(s.game)) {
    const tasks = (JSON.parse(s.settings) as { tasks: Task[] }).tasks;
    const task = typeof body.round === 'number' ? tasks[body.round] : undefined;
    if (!task) throw new HttpError(400, 'bad_round');
    const distance = distanceM(lat, lon, task.lat, task.lon);
    // The first try counts: the correct point is shown right after it.
    const [stored] = await env.DB.batch([
      env.DB.prepare(
        `INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(submissionId, s.id, participantId, body.round, JSON.stringify(answer), lat, lon, distance, scoreFor(distance), nowSec()),
      bumpRev(env, s.id),
    ]);
    const first = await storedAnswer(env, s.id, participantId, body.round as number);
    return json({ ok: true, duplicate: stored.meta.changes === 0, ...answerResult(s, first) }, 201);
  }

  // One answer per student: sending again replaces the earlier one.
  await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id = ? AND participant_id = ?').bind(s.id, participantId),
    env.DB.prepare(
      'INSERT INTO responses (id, session_id, participant_id, answer, lat, lon, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ).bind(submissionId, s.id, participantId, JSON.stringify(answer), lat, lon, nowSec()),
    bumpRev(env, s.id),
  ]);
  return json({ ok: true, duplicate: false }, 201);
}

/** The clock must have been started, and not ended by more than the grace. */
function requireRunning(s: SessionRow): void {
  const { endsAt } = JSON.parse(s.settings) as { endsAt?: number };
  if (endsAt === undefined) throw new HttpError(409, 'not_started');
  if (nowSec() > endsAt + TIME_UP_GRACE_SEC) throw new HttpError(409, 'time_up');
}

async function submitObject(
  env: Env,
  s: SessionRow,
  submissionId: string,
  participantId: string,
  answer: Record<string, unknown>,
): Promise<Response> {
  requireRunning(s);

  const { results: mine } = await env.DB.prepare('SELECT round, answer, lat, lon FROM responses WHERE session_id = ? AND participant_id = ?')
    .bind(s.id, participantId)
    .all<{ round: number; answer: string; lat: number; lon: number }>();
  if (mine.length >= MAX_OBJECTS_PER_STUDENT) throw new HttpError(409, 'too_many_objects');
  const [lon, lat] = middle(answer.coords as number[][]);
  for (const o of mine) {
    if (JSON.parse(o.answer).category === answer.category && distanceM(lat, lon, o.lat, o.lon) < SAME_PLACE_M) {
      throw new HttpError(409, 'same_place');
    }
  }

  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ?').bind(s.id).first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');

  await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').bind(
      submissionId,
      s.id,
      participantId,
      mine.reduce((next, o) => Math.max(next, o.round + 1), 0),
      JSON.stringify(answer),
      lat,
      lon,
      nowSec(),
    ),
    bumpRev(env, s.id),
  ]);
  return json({ ok: true, duplicate: false }, 201);
}

/**
 * A found pair or a wrong try in the cards game, a placed piece or a wrong placement in the puzzle.
 * A pair or a piece counts once per student: its number is the round.
 */
async function submitCardTry(
  env: Env,
  s: SessionRow,
  submissionId: string,
  participantId: string,
  answer: Record<string, unknown>,
): Promise<Response> {
  requireRunning(s);
  if (s.game === 'cards') {
    // The server decides whether the two cards match: the device only says which two were turned.
    const settings = JSON.parse(s.settings) as CardsSettings & { order?: number[] };
    const first = cardOf(settings, answer.a as number);
    const second = cardOf(settings, answer.b as number);
    if (first === undefined || second === undefined) throw new HttpError(400, 'bad_round');
    const [x, y] = [Math.floor(first / 2), Math.floor(second / 2)];
    answer = x === y ? { ok: true, pair: x, a: answer.a, b: answer.b } : { ok: false, x, y, a: answer.a, b: answer.b };
  } else {
    const { pieces } = JSON.parse(s.settings) as { pieces?: number };
    if ((answer.piece as number) >= (pieces ?? 0)) throw new HttpError(400, 'bad_round');
  }

  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ?').bind(s.id).first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');

  let round: number;
  if (answer.ok === true) {
    round = (s.game === 'puzzle' ? answer.piece : answer.pair) as number;
  } else {
    const last = await env.DB.prepare('SELECT COUNT(*) AS n, MAX(round) AS top FROM responses WHERE session_id = ? AND participant_id = ? AND round >= ?')
      .bind(s.id, participantId, MISTAKE_ROUND_FROM)
      .first<{ n: number; top: number | null }>();
    if ((last?.n ?? 0) >= MAX_MISTAKES_PER_STUDENT) throw new HttpError(409, 'too_many_objects');
    round = (last?.top ?? MISTAKE_ROUND_FROM - 1) + 1;
  }
  const stored = await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, created_at) VALUES (?, ?, ?, ?, ?, 0, 0, ?)').bind(
      submissionId,
      s.id,
      participantId,
      round,
      JSON.stringify(answer),
      nowSec(),
    ),
    bumpRev(env, s.id),
  ]);
  // A pair found twice (a second device, a late retry) is kept once.
  const match = s.game === 'cards' ? { match: answer.ok === true } : {};
  return json({ ok: true, duplicate: stored[0].meta.changes === 0, ...match }, stored[0].meta.changes === 0 ? 200 : 201);
}

/** A student hands in the map sheet. Handing it in again replaces it: one sheet per student, scored here. */
async function submitLayout(
  env: Env,
  s: SessionRow,
  submissionId: string,
  participantId: string,
  answer: Record<string, unknown>,
): Promise<Response> {
  const { legend } = JSON.parse(s.settings) as LayoutSettings;
  if ((answer.fills as number[]).length !== legend.length) throw new HttpError(400, 'bad_answer');
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ? AND participant_id != ?')
    .bind(s.id, participantId)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');
  await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id = ? AND participant_id = ? AND id != ?').bind(s.id, participantId, submissionId),
    env.DB.prepare(
      'INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, score, created_at) VALUES (?, ?, ?, 0, ?, 0, 0, ?, ?)',
    ).bind(submissionId, s.id, participantId, JSON.stringify(answer), scoreLayout(legend, answer), nowSec()),
    bumpRev(env, s.id),
  ]);
  return json({ ok: true, duplicate: false, score: scoreLayout(legend, answer) }, 201);
}

/** One answer of the evidence game: the task's number comes as the round, the question in the answer. */
async function submitEvidence(
  env: Env,
  s: SessionRow,
  submissionId: string,
  participantId: string,
  answer: Record<string, unknown>,
  taskIndex: unknown,
  lat: number,
  lon: number,
): Promise<Response> {
  const tasks = (JSON.parse(s.settings) as { tasks: EvidenceTask[] }).tasks;
  const task = typeof taskIndex === 'number' && Number.isInteger(taskIndex) ? tasks[taskIndex] : undefined;
  if (!task || !task.questions.includes(answer.q as string)) throw new HttpError(400, 'bad_round');
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ?').bind(s.id).first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');
  const named = answer.q === 'name';
  const { distance, score } = scoreEvidence(task, answer, lat, lon);
  // The first answer counts: the right one is shown after the task.
  const round = (taskIndex as number) * QUESTIONS.length + QUESTIONS.indexOf(answer.q as string);
  const stored = await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      submissionId,
      s.id,
      participantId,
      round,
      JSON.stringify(answer),
      named ? 0 : lat,
      named ? 0 : lon,
      distance,
      score,
      nowSec(),
    ),
    bumpRev(env, s.id),
  ]);
  // The first answer's result, not this one's: trying names again must not tell which one is right.
  const first = stored[0].meta.changes === 0 ? await storedAnswer(env, s.id, participantId, round) : { round, score, distance_m: distance };
  return json({ ok: true, duplicate: stored[0].meta.changes === 0, ...answerResult(s, first) }, stored[0].meta.changes === 0 ? 200 : 201);
}

type StoredAnswer = { round: number; score: number | null; distance_m: number | null };

async function storedAnswer(env: Env, sessionId: string, participantId: string, round: number): Promise<StoredAnswer | null> {
  return env.DB.prepare('SELECT round, score, distance_m FROM responses WHERE session_id = ? AND participant_id = ? AND round = ?')
    .bind(sessionId, participantId, round)
    .first<StoredAnswer>();
}

/**
 * What a student learns after an answer is stored: its score and the right answer. Only the first answer of a task
 * counts, so this is always that one's result, sent again to a retry or a second try.
 */
function answerResult(s: SessionRow, row: StoredAnswer | null): Record<string, unknown> {
  if (!row) return {};
  const tasks = (JSON.parse(s.settings) as { tasks?: Record<string, unknown>[] }).tasks ?? [];
  if (TASK_GAMES.includes(s.game)) {
    const t = tasks[row.round];
    if (!t) return {};
    return { score: row.score, distanceM: row.distance_m, target: { lat: t.lat, lon: t.lon, label: t.label ?? '', labelEn: t.labelEn ?? '' } };
  }
  if (s.game === 'evidence') {
    const t = tasks[Math.floor(row.round / QUESTIONS.length)] as EvidenceTask | undefined;
    if (!t) return {};
    const named = QUESTIONS[row.round % QUESTIONS.length] === 'name';
    return { score: row.score, distanceM: row.distance_m, ...(named ? { right: t.names[0] ?? '' } : {}) };
  }
  return {};
}

/** A student deletes the answers of their own device in this session. The random id is known only to that device. */
async function forget(env: Env, request: Request): Promise<Response> {
  const limited = await env.SUBMIT_LIMIT?.limit({ key: request.headers.get('CF-Connecting-IP') ?? 'unknown' });
  if (limited && !limited.success) throw new HttpError(429, 'rate_limited');
  const { token, participantId } = await readBody<{ token?: unknown; participantId?: unknown }>(request);
  const s = await sessionByToken(env, token);
  if (typeof participantId !== 'string' || !ID_RE.test(participantId)) throw new HttpError(400, 'bad_id');
  const [deleted] = await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id = ? AND participant_id = ?').bind(s.id, participantId),
    bumpRev(env, s.id),
  ]);
  return json({ deleted: deleted.meta.changes ?? 0 });
}

// --- Teacher endpoints ---

async function listSessions(env: Env, actor: Actor): Promise<Response> {
  const { results } = await env.DB.prepare(
    // Only the owner's list names who made a session; a teacher's own list doesn't need it.
    `SELECT ${SESSION_COLUMNS.split(', ').map((c) => `s.${c}`).join(', ')}, ${actor.admin ? 't.name' : 'NULL'} AS teacher_name, COUNT(r.id) AS n
     FROM sessions s LEFT JOIN responses r ON r.session_id = s.id LEFT JOIN teachers t ON t.id = s.teacher_id
     WHERE ? = 1 OR s.teacher_id = ?
     GROUP BY s.id ORDER BY s.created_at DESC`,
  )
    .bind(actor.admin ? 1 : 0, actor.id ?? '')
    .all<SessionRow & { n: number }>();
  return json({ sessions: results.map((s) => sessionJson(s, s.n)) });
}

async function createSession(env: Env, request: Request, actor: Actor): Promise<Response> {
  const body = await readBody<{
    name?: unknown;
    game?: unknown;
    tasks?: unknown;
    cards?: unknown;
    plates?: unknown;
    puzzle?: unknown;
    layout?: unknown;
    answers?: unknown;
  }>(
    request,
  );
  const name = cleanName(body.name);
  if (typeof body.game !== 'string' || !GAMES.includes(body.game)) throw new HttpError(400, 'bad_game');
  const settings = TASK_GAMES.includes(body.game)
    ? { tasks: validateTasks(body.game, body.tasks) }
    : body.game === 'cards'
      ? validateCards(body.cards)
      : body.game === 'evidence'
        ? { tasks: validateEvidence(body.tasks) }
        : body.game === 'plates'
          ? validatePlates(body.plates)
          : body.game === 'puzzle'
            ? validatePuzzle(body.puzzle)
            : body.game === 'layout'
              ? validateLayout(body.layout)
              : {};
  if (PROTECTED_GAMES.includes(body.game)) {
    // New sessions keep the answers on the server unless the teacher asks for offline play.
    if (body.answers !== undefined && !ANSWER_MODES.includes(body.answers as string)) throw new HttpError(400, 'bad_answers');
    (settings as Record<string, unknown>).answers = body.answers ?? 'online';
    if (body.game === 'cards' && (settings as Record<string, unknown>).answers === 'online') {
      (settings as Record<string, unknown>).order = shuffledCards((settings as CardsSettings).pairs.length);
    }
  }
  const id = crypto.randomUUID();
  const token = randomToken();
  await env.DB.prepare('INSERT INTO sessions (id, name, game, token_hash, settings, created_at, teacher_id) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .bind(id, name, body.game, await sha256(token), JSON.stringify(settings), nowSec(), actor.id)
    .run();
  return json({ session: sessionJson(await sessionOr404(env, id, actor), 0), token }, 201);
}

async function updateSession(env: Env, request: Request, id: string, actor: Actor): Promise<Response> {
  await sessionOr404(env, id, actor);
  const body = await readBody<{ name?: unknown; status?: unknown; archived?: unknown }>(request);
  const statements: D1PreparedStatement[] = [];
  if (body.name !== undefined) {
    statements.push(env.DB.prepare('UPDATE sessions SET name = ? WHERE id = ?').bind(cleanName(body.name), id));
  }
  if (body.status !== undefined) {
    if (body.status !== 'open' && body.status !== 'paused' && body.status !== 'closed') {
      throw new HttpError(400, 'bad_status');
    }
    statements.push(env.DB.prepare('UPDATE sessions SET status = ? WHERE id = ?').bind(body.status, id));
  }
  if (body.archived !== undefined) {
    if (typeof body.archived !== 'boolean') throw new HttpError(400, 'bad_archived');
    statements.push(env.DB.prepare('UPDATE sessions SET archived = ? WHERE id = ?').bind(body.archived ? 1 : 0, id));
  }
  if (statements.length === 0) throw new HttpError(400, 'nothing_to_update');
  await env.DB.batch([...statements, bumpRev(env, id)]);
  return json({ session: sessionJson(await sessionOr404(env, id, actor)) });
}

/** Starts the clock of a timed game for everyone, changes the time left, or with 0 seconds stops it. */
async function setTimer(env: Env, request: Request, id: string, actor: Actor): Promise<Response> {
  const s = await sessionOr404(env, id, actor);
  if (!TIMED_GAMES.includes(s.game)) throw new HttpError(400, 'bad_game');
  const { seconds, center, zoom } = await readBody<{ seconds?: unknown; center?: unknown; zoom?: unknown }>(request);
  if (typeof seconds !== 'number' || !Number.isInteger(seconds) || seconds < 0 || seconds > MAX_TIMER_SEC) {
    throw new HttpError(400, 'bad_timer');
  }
  const settings = JSON.parse(s.settings) as Record<string, unknown>;
  // When the round began, for the puzzle's finishing times: more minutes keep it, a new start sets it again.
  const running = typeof settings.endsAt === 'number' && settings.endsAt > nowSec();
  if (seconds > 0 && !running) settings.startedAt = nowSec();
  settings.endsAt = nowSec() + seconds;
  // Where students' maps open: what the teacher's map shows.
  if (Array.isArray(center)) {
    const [lat, lon] = center;
    if (typeof lat !== 'number' || typeof lon !== 'number' || !(Math.abs(lat) <= 90) || !(Math.abs(lon) <= 180)) {
      throw new HttpError(400, 'bad_timer');
    }
    settings.center = [lat, lon];
    settings.zoom = typeof zoom === 'number' && zoom >= 2 && zoom <= 20 ? zoom : 13;
  }
  await env.DB.batch([
    env.DB.prepare('UPDATE sessions SET settings = ? WHERE id = ?').bind(JSON.stringify(settings), id),
    bumpRev(env, id),
  ]);
  return json({ session: sessionJson(await sessionOr404(env, id, actor)) });
}

/** The plates game: the teacher moves everyone to a plate (the deck's length is the end) and shows or hides its answer. */
async function setPlate(env: Env, request: Request, id: string, actor: Actor): Promise<Response> {
  const s = await sessionOr404(env, id, actor);
  if (s.game !== 'plates') throw new HttpError(400, 'bad_game');
  const { at, revealed } = await readBody<{ at?: unknown; revealed?: unknown }>(request);
  const settings = JSON.parse(s.settings) as PlatesSettings;
  if (typeof at !== 'number' || !Number.isInteger(at) || at < 0 || at > settings.deck.length || typeof revealed !== 'boolean') {
    throw new HttpError(400, 'bad_plate');
  }
  settings.at = at;
  settings.revealed = revealed && at < settings.deck.length;
  await env.DB.batch([
    env.DB.prepare('UPDATE sessions SET settings = ? WHERE id = ?').bind(JSON.stringify(settings), id),
    bumpRev(env, id),
  ]);
  return json({ session: sessionJson(await sessionOr404(env, id, actor)) });
}

async function newToken(env: Env, id: string, actor: Actor): Promise<Response> {
  await sessionOr404(env, id, actor);
  const token = randomToken();
  await env.DB.prepare('UPDATE sessions SET token_hash = ? WHERE id = ?').bind(await sha256(token), id).run();
  return json({ token });
}

async function deleteSession(env: Env, id: string, actor: Actor): Promise<Response> {
  await sessionOr404(env, id, actor);
  await env.DB.prepare('DELETE FROM sessions WHERE id = ?').bind(id).run();
  return json({ ok: true });
}

async function listResponses(env: Env, url: URL, id: string, actor: Actor): Promise<Response> {
  const s = await sessionOr404(env, id, actor);
  // Polling: a single row read while nothing has changed.
  const known = url.searchParams.get('rev');
  if (known !== null && Number(known) === s.rev) {
    return json({ changed: false, session: sessionJson(s) });
  }
  const { results } = await env.DB.prepare('SELECT * FROM responses WHERE session_id = ? ORDER BY created_at, id')
    .bind(id)
    .all<ResponseRow>();
  return json({ changed: true, session: sessionJson(s), responses: results.map(responseJson) });
}

async function resetResponses(env: Env, id: string, actor: Actor): Promise<Response> {
  await sessionOr404(env, id, actor);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id = ?').bind(id),
    // Tells students' devices to forget their progress in the game.
    env.DB.prepare("UPDATE sessions SET settings = json_remove(json_set(settings, '$.resetAt', unixepoch()), '$.endsAt', '$.startedAt') WHERE id = ?").bind(id),
    bumpRev(env, id),
  ]);
  return json({ ok: true });
}

/** Hides an answer, or in the evidence game counts it as right despite a small slip (and back). */
async function updateResponse(env: Env, request: Request, id: string, actor: Actor): Promise<Response> {
  const { hidden, accepted } = await readBody<{ hidden?: unknown; accepted?: unknown }>(request);
  if (hidden !== undefined && typeof hidden !== 'boolean') throw new HttpError(400, 'bad_hidden');
  if (accepted !== undefined && typeof accepted !== 'boolean') throw new HttpError(400, 'bad_accepted');
  if (hidden === undefined && accepted === undefined) throw new HttpError(400, 'nothing_to_update');
  const r = await env.DB.prepare(
    'SELECT r.session_id, s.game FROM responses r JOIN sessions s ON s.id = r.session_id WHERE r.id = ? AND (? = 1 OR s.teacher_id = ?)',
  )
    .bind(id, actor.admin ? 1 : 0, actor.id ?? '')
    .first<{ session_id: string; game: string }>();
  if (!r) throw new HttpError(404, 'not_found');
  if (accepted !== undefined && r.game !== 'evidence') throw new HttpError(400, 'bad_game');
  const statements: D1PreparedStatement[] = [];
  if (hidden !== undefined) statements.push(env.DB.prepare('UPDATE responses SET hidden = ? WHERE id = ?').bind(hidden ? 1 : 0, id));
  if (accepted !== undefined) statements.push(env.DB.prepare('UPDATE responses SET accepted = ? WHERE id = ?').bind(accepted ? 1 : 0, id));
  await env.DB.batch([...statements, bumpRev(env, r.session_id)]);
  return json({ ok: true });
}

async function deleteResponse(env: Env, id: string, actor: Actor): Promise<Response> {
  const r = await env.DB.prepare(
    'SELECT r.session_id FROM responses r JOIN sessions s ON s.id = r.session_id WHERE r.id = ? AND (? = 1 OR s.teacher_id = ?)',
  )
    .bind(id, actor.admin ? 1 : 0, actor.id ?? '')
    .first<{ session_id: string }>();
  if (!r) throw new HttpError(404, 'not_found');
  await env.DB.batch([env.DB.prepare('DELETE FROM responses WHERE id = ?').bind(id), bumpRev(env, r.session_id)]);
  return json({ ok: true });
}

// --- Backup. QR tokens are left out: a restored session starts closed and needs a new QR. ---

async function backup(env: Env, url: URL, actor: Actor): Promise<Response> {
  const only = url.searchParams.get('session');
  // The owner backs up everything, a teacher only their own sessions.
  const mine = 'WHERE (? = 1 OR teacher_id = ?) AND (? IS NULL OR id = ?)';
  const scope = [actor.admin ? 1 : 0, actor.id ?? '', only, only];
  const sessions = await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions ${mine} ORDER BY created_at`)
    .bind(...scope)
    .all<SessionRow>();
  if (only && sessions.results.length === 0) throw new HttpError(404, 'not_found');
  const responses = await env.DB.prepare(`SELECT * FROM responses WHERE session_id IN (SELECT id FROM sessions ${mine}) ORDER BY created_at`)
    .bind(...scope)
    .all<ResponseRow>();
  return json({
    format: 'geoclass-backup',
    version: 2,
    exportedAt: nowSec(),
    sessions: sessions.results.map((s) => sessionJson(s)),
    responses: responses.results.map(responseJson),
  });
}

type BackupSession = { id?: unknown; name?: unknown; game?: unknown; archived?: unknown; teacherId?: unknown; settings?: { tasks?: unknown; pairs?: unknown; arrow?: unknown; rotation?: unknown; answers?: unknown }; createdAt?: unknown };
type BackupResponse = {
  id?: unknown;
  sessionId?: unknown;
  participantId?: unknown;
  round?: unknown;
  answer?: unknown;
  lat?: unknown;
  lon?: unknown;
  hidden?: unknown;
  accepted?: unknown;
  createdAt?: unknown;
};

function restoredTasks(game: string, raw: unknown): (Task | EvidenceTask)[] {
  try {
    return game === 'evidence' ? validateEvidence(raw) : validateTasks(game, raw);
  } catch {
    throw new HttpError(400, 'bad_backup');
  }
}

/** The settings a restored session keeps: the task list or the deck. The clock is not restored, and plates start again. */
function restoredSettings(game: string, tasks: (Task | EvidenceTask)[], raw: BackupSession['settings']): object {
  if (TASK_GAMES.includes(game) || game === 'evidence') {
    // The answer mode comes back as it was; a backup from before it existed has none, which means offline.
    const answers = raw?.answers;
    return PROTECTED_GAMES.includes(game) && ANSWER_MODES.includes(answers as string) ? { tasks, answers } : { tasks };
  }
  if (game !== 'cards' && game !== 'plates' && game !== 'puzzle' && game !== 'layout') return {};
  try {
    if (game === 'layout') return validateLayout(raw);
    if (game === 'cards') {
      // Online decks keep their hidden order; a backup from before the mode existed plays offline, as it did.
      const deck = validateCards(raw);
      if (raw?.answers !== 'online' && raw?.answers !== 'offline') return deck;
      if (raw.answers === 'offline') return { ...deck, answers: 'offline' };
      const order = (raw as { order?: unknown }).order;
      const valid = Array.isArray(order) && order.length === deck.pairs.length * 2 && [...order].sort((a, b) => a - b).every((v, i) => v === i);
      return { ...deck, answers: 'online', order: valid ? order : shuffledCards(deck.pairs.length) };
    }
    return game === 'plates' ? validatePlates(raw) : game === 'puzzle' ? validatePuzzle(raw) : validateCards(raw);
  } catch {
    throw new HttpError(400, 'bad_backup');
  }
}

async function restore(env: Env, request: Request, actor: Actor): Promise<Response> {
  const data = await readBody<{ format?: unknown; version?: unknown; sessions?: BackupSession[]; responses?: BackupResponse[] }>(
    request,
    MAX_RESTORE_BYTES,
  );
  if (data.format !== 'geoclass-backup' || (data.version !== 1 && data.version !== 2) || !Array.isArray(data.sessions) || !Array.isArray(data.responses)) {
    throw new HttpError(400, 'bad_backup');
  }

  // Everything is validated first, so a bad file changes nothing.
  // A teacher may restore only into sessions that are new or already theirs: an id of someone else's session
  // would otherwise let the file's answers into it.
  const ids = data.sessions.map((s) => s.id).filter((v): v is string => typeof v === 'string');
  for (let i = 0; i < ids.length; i += D1_BATCH_SIZE) {
    const part = ids.slice(i, i + D1_BATCH_SIZE);
    const { results: taken } = await env.DB.prepare(
      `SELECT id FROM sessions WHERE id IN (${part.map(() => '?').join(', ')}) AND NOT (? = 1 OR teacher_id IS ?)`,
    )
      .bind(...part, actor.admin ? 1 : 0, actor.id)
      .all<{ id: string }>();
    if (taken.length > 0) throw new HttpError(403, 'not_yours');
  }
  // The owner's file keeps who made each session, if that teacher still exists here.
  const known = actor.admin
    ? new Set((await env.DB.prepare('SELECT id FROM teachers').all<{ id: string }>()).results.map((r) => r.id))
    : new Set<string>();
  const games = new Map<string, { game: string; tasks: (Task | EvidenceTask)[]; legend?: number[] }>();
  const statements: D1PreparedStatement[] = [];
  for (const s of data.sessions) {
    if (typeof s.id !== 'string' || !ID_RE.test(s.id) || typeof s.game !== 'string' || !GAMES.includes(s.game) || typeof s.createdAt !== 'number') {
      throw new HttpError(400, 'bad_backup');
    }
    const tasks = TASK_GAMES.includes(s.game) || s.game === 'evidence' ? restoredTasks(s.game, s.settings?.tasks) : [];
    const settings = restoredSettings(s.game, tasks, s.settings);
    games.set(s.id, { game: s.game, tasks, legend: (settings as Partial<LayoutSettings>).legend });
    statements.push(
      env.DB.prepare(
        "INSERT OR IGNORE INTO sessions (id, name, game, status, token_hash, archived, settings, created_at, teacher_id) VALUES (?, ?, ?, 'closed', ?, ?, ?, ?, ?)",
      ).bind(
        s.id,
        cleanName(s.name),
        s.game,
        await sha256(randomToken()),
        s.archived === true ? 1 : 0,
        JSON.stringify(settings),
        s.createdAt,
        actor.admin ? (typeof s.teacherId === 'string' && known.has(s.teacherId) ? s.teacherId : null) : actor.id,
      ),
    );
  }
  for (const r of data.responses) {
    const session = typeof r.sessionId === 'string' ? games.get(r.sessionId) : undefined;
    const valid =
      typeof r.id === 'string' &&
      ID_RE.test(r.id) &&
      session !== undefined &&
      typeof r.participantId === 'string' &&
      ID_RE.test(r.participantId) &&
      typeof r.lat === 'number' &&
      Math.abs(r.lat) <= 90 &&
      typeof r.lon === 'number' &&
      Math.abs(r.lon) <= 180 &&
      typeof r.createdAt === 'number';
    if (!valid) throw new HttpError(400, 'bad_backup');
    const answer = validateAnswer(session.game, r.answer);
    if (session.game === 'evidence') {
      // The round says the task and the question; it has to match the answer.
      const round = r.round;
      const task = typeof round === 'number' && Number.isInteger(round) ? (session.tasks[Math.floor(round / QUESTIONS.length)] as EvidenceTask | undefined) : undefined;
      if (!task || QUESTIONS[(round as number) % QUESTIONS.length] !== answer.q || !task.questions.includes(answer.q as string)) {
        throw new HttpError(400, 'bad_backup');
      }
      const { distance, score } = scoreEvidence(task, answer, r.lat as number, r.lon as number);
      statements.push(
        env.DB.prepare(
          `INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          r.id as string,
          r.sessionId as string,
          r.participantId as string,
          round as number,
          JSON.stringify(answer),
          r.lat as number,
          r.lon as number,
          distance,
          score,
          r.hidden === true ? 1 : 0,
          r.accepted === true ? 1 : 0,
          r.createdAt as number,
        ),
      );
      continue;
    }
    const taskGame = TASK_GAMES.includes(session.game);
    // A mapping student has many objects and a cards student many tries, told apart by their number.
    const round = taskGame || (TIMED_GAMES.includes(session.game) && typeof r.round === 'number') ? r.round : 0;
    const task = taskGame && typeof round === 'number' ? (session.tasks[round] as Task | undefined) : undefined;
    if (taskGame && !task) throw new HttpError(400, 'bad_backup');
    // Scores are worked out again, so an edited file can't change them.
    const distance = task ? distanceM(r.lat as number, r.lon as number, task.lat, task.lon) : null;
    statements.push(
      env.DB.prepare(
        `INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        r.id as string,
        r.sessionId as string,
        r.participantId as string,
        round as number,
        JSON.stringify(answer),
        r.lat as number,
        r.lon as number,
        distance,
        distance !== null ? scoreFor(distance) : session.legend ? scoreLayout(session.legend, answer) : null,
        r.hidden === true ? 1 : 0,
        r.createdAt as number,
      ),
    );
  }

  for (const id of games.keys()) statements.push(bumpRev(env, id));
  for (let i = 0; i < statements.length; i += D1_BATCH_SIZE) {
    await env.DB.batch(statements.slice(i, i + D1_BATCH_SIZE));
  }
  return json({ ok: true, sessions: games.size, responses: data.responses.length });
}

// --- Teacher accounts (owner only) ---

const VALID_UNITS = ['day', 'month', 'year'];
const MAX_VALID_DAYS = 5 * 366;

/** The end of a validity the owner picks: a number of days, months or years from now, at most about five years. */
function validUntil(amount: unknown, unit: unknown, now = nowSec()): number {
  if (typeof amount !== 'number' || !Number.isInteger(amount) || amount < 1 || typeof unit !== 'string' || !VALID_UNITS.includes(unit)) {
    throw new HttpError(400, 'bad_validity');
  }
  const end = new Date(now * 1000);
  if (unit === 'day') end.setUTCDate(end.getUTCDate() + amount);
  if (unit === 'month') end.setUTCMonth(end.getUTCMonth() + amount);
  if (unit === 'year') end.setUTCFullYear(end.getUTCFullYear() + amount);
  const at = Math.floor(end.getTime() / 1000);
  if (at - now > MAX_VALID_DAYS * 86400) throw new HttpError(400, 'bad_validity');
  return at;
}

type TeacherRow = { id: string; name: string; created_at: number; expires_at: number; revoked_at: number | null; n?: number };

function teacherJson(t: TeacherRow) {
  return {
    id: t.id,
    name: t.name,
    createdAt: t.created_at,
    expiresAt: t.expires_at,
    revokedAt: t.revoked_at,
    active: t.revoked_at === null && t.expires_at > nowSec(),
    ...(t.n === undefined ? {} : { sessions: t.n }),
  };
}

async function listTeachers(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT t.id, t.name, t.created_at, t.expires_at, t.revoked_at, COUNT(s.id) AS n
     FROM teachers t LEFT JOIN sessions s ON s.teacher_id = t.id GROUP BY t.id ORDER BY t.created_at DESC`,
  ).all<TeacherRow>();
  return json({ teachers: results.map(teacherJson) });
}

/** A new teacher and their key. The key is shown this once; only its hash is kept. */
async function createTeacher(env: Env, request: Request): Promise<Response> {
  const body = await readBody<{ name?: unknown; amount?: unknown; unit?: unknown }>(request);
  const name = cleanName(body.name);
  const expiresAt = validUntil(body.amount, body.unit);
  const id = crypto.randomUUID();
  const key = randomToken();
  await env.DB.prepare('INSERT INTO teachers (id, name, key_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)')
    .bind(id, name, await sha256(key), nowSec(), expiresAt)
    .run();
  const t = await env.DB.prepare('SELECT id, name, created_at, expires_at, revoked_at FROM teachers WHERE id = ?').bind(id).first<TeacherRow>();
  return json({ teacher: teacherJson(t!), key }, 201);
}

/** Revoke a teacher's key or give it back, rename, or set a new validity counted from now. */
async function updateTeacher(env: Env, request: Request, id: string): Promise<Response> {
  const t = await env.DB.prepare('SELECT id FROM teachers WHERE id = ?').bind(id).first();
  if (!t) throw new HttpError(404, 'not_found');
  const body = await readBody<{ name?: unknown; revoked?: unknown; amount?: unknown; unit?: unknown }>(request);
  const statements: D1PreparedStatement[] = [];
  if (body.name !== undefined) statements.push(env.DB.prepare('UPDATE teachers SET name = ? WHERE id = ?').bind(cleanName(body.name), id));
  if (body.revoked !== undefined) {
    if (typeof body.revoked !== 'boolean') throw new HttpError(400, 'bad_revoked');
    statements.push(env.DB.prepare('UPDATE teachers SET revoked_at = ? WHERE id = ?').bind(body.revoked ? nowSec() : null, id));
  }
  if (body.amount !== undefined || body.unit !== undefined) {
    statements.push(env.DB.prepare('UPDATE teachers SET expires_at = ? WHERE id = ?').bind(validUntil(body.amount, body.unit), id));
  }
  if (statements.length === 0) throw new HttpError(400, 'nothing_to_update');
  await env.DB.batch(statements);
  const row = await env.DB.prepare('SELECT id, name, created_at, expires_at, revoked_at FROM teachers WHERE id = ?').bind(id).first<TeacherRow>();
  return json({ teacher: teacherJson(row!) });
}

// --- Routing ---

async function route(request: Request, env: Env, url: URL): Promise<Response> {
  // A static file that doesn't exist ends up here too.
  if (!url.pathname.startsWith('/api/')) throw new HttpError(404, 'not_found');
  const parts = url.pathname.split('/').filter(Boolean).slice(1); // drop "api"
  const { method } = request;
  const key = `${method} ${parts[0] ?? ''}`;

  if (key === 'GET health') return json({ ok: true });
  if (key === 'POST join') return join(env, request);
  if (key === 'POST submit') return submit(env, request);
  if (key === 'POST forget') return forget(env, request);
  if (key === 'GET card-image' && parts.length === 3) return cardImage(env, parts[1], parts[2]);

  const actor = await requireTeacher(env, request);

  if (key === 'GET me') {
    return json({ ok: true, role: actor.admin ? 'owner' : 'teacher', name: actor.name, expiresAt: actor.expiresAt });
  }
  if (key === 'GET backup') return backup(env, url, actor);
  if (key === 'POST restore') return restore(env, request, actor);

  const [resource, id, child] = parts;
  if (resource === 'teachers' && !child) {
    requireOwner(actor);
    if (!id && method === 'GET') return listTeachers(env);
    if (!id && method === 'POST') return createTeacher(env, request);
    if (id && method === 'PATCH') return updateTeacher(env, request, id);
  }
  if (resource === 'sessions') {
    if (!id) {
      if (method === 'GET') return listSessions(env, actor);
      if (method === 'POST') return createSession(env, request, actor);
    } else if (!child) {
      if (method === 'PATCH') return updateSession(env, request, id, actor);
      if (method === 'DELETE') return deleteSession(env, id, actor);
    } else if (child === 'token' && method === 'POST') {
      return newToken(env, id, actor);
    } else if (child === 'timer' && method === 'POST') {
      return setTimer(env, request, id, actor);
    } else if (child === 'plate' && method === 'POST') {
      return setPlate(env, request, id, actor);
    } else if (child === 'responses') {
      if (method === 'GET') return listResponses(env, url, id, actor);
      if (method === 'DELETE') return resetResponses(env, id, actor);
    }
  }
  if (resource === 'responses' && id && !child) {
    if (method === 'PATCH') return updateResponse(env, request, id, actor);
    if (method === 'DELETE') return deleteResponse(env, id, actor);
  }
  throw new HttpError(404, 'not_found');
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    try {
      return await route(request, env, new URL(request.url));
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.key }, e.status);
      console.error(e);
      return json({ error: 'internal' }, 500);
    }
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const n = await deleteOld(env);
    await deleteOldAuthFailures(env);
    await deleteOldTeachers(env);
    if (n > 0) console.log(`deleted ${n} sessions older than ${KEEP_SEC / 86400} days`);
  },
} satisfies ExportedHandler<Env>;
