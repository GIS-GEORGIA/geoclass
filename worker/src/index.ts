import { HttpError, distanceM, middle, scoreFor, validateAnswer, validateCards, validateTasks, type Task } from './validate';

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

async function requireTeacher(env: Env, request: Request): Promise<void> {
  const header = request.headers.get('Authorization') ?? '';
  const key = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!env.TEACHER_KEY_HASH || !key || (await sha256(key)) !== env.TEACHER_KEY_HASH) {
    throw new HttpError(401, 'unauthorized');
  }
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
};

const SESSION_COLUMNS = 'id, name, game, status, rev, archived, settings, created_at';
const GAMES = ['travel', 'coordinates', 'aerial', 'mapping', 'cards'];
// Games played against the teacher's clock.
const TIMED_GAMES = ['mapping', 'cards'];
// Games made of tasks that the server scores.
const TASK_GAMES = ['coordinates', 'aerial'];

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
    createdAt: r.created_at,
  };
}

function cleanName(value: unknown): string {
  const name = typeof value === 'string' ? value.trim() : '';
  if (!name || name.length > 100) throw new HttpError(400, 'bad_name');
  return name;
}

async function sessionOr404(env: Env, id: string): Promise<SessionRow> {
  const s = await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE id = ?`).bind(id).first<SessionRow>();
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
  return json({ name: s.name, game: s.game, status: s.status, settings: JSON.parse(s.settings), now: nowSec() });
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
  const existing = await env.DB.prepare('SELECT id FROM responses WHERE id = ?').bind(submissionId).first();
  if (existing) return json({ ok: true, duplicate: true });

  if (s.status !== 'open') throw new HttpError(409, `session_${s.status}`);

  const { lat, lon } = body;
  if (typeof lat !== 'number' || typeof lon !== 'number' || !(Math.abs(lat) <= 90) || !(Math.abs(lon) <= 180)) {
    throw new HttpError(400, 'bad_location');
  }
  const answer = validateAnswer(s.game, body.answer);
  if (s.game === 'mapping') return submitObject(env, s, submissionId, participantId, answer);
  if (s.game === 'cards') return submitCardTry(env, s, submissionId, participantId, answer);

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
    await env.DB.batch([
      env.DB.prepare(
        `INSERT OR IGNORE INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(submissionId, s.id, participantId, body.round, JSON.stringify(answer), lat, lon, distance, scoreFor(distance), nowSec()),
      bumpRev(env, s.id),
    ]);
    return json({ ok: true, duplicate: false }, 201);
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

/** A found pair or a wrong try in the cards game. A pair counts once per student: its number is the round. */
async function submitCardTry(
  env: Env,
  s: SessionRow,
  submissionId: string,
  participantId: string,
  answer: Record<string, unknown>,
): Promise<Response> {
  requireRunning(s);
  const { pairs } = JSON.parse(s.settings) as { pairs?: unknown[] };
  const total = pairs?.length ?? 0;
  if (answer.ok === true && (answer.pair as number) >= total) throw new HttpError(400, 'bad_round');
  if (answer.ok === false && ((answer.x as number) >= total || (answer.y as number) >= total)) throw new HttpError(400, 'bad_round');

  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ?').bind(s.id).first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');

  let round: number;
  if (answer.ok === true) {
    round = answer.pair as number;
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
  return json({ ok: true, duplicate: stored[0].meta.changes === 0 }, stored[0].meta.changes === 0 ? 200 : 201);
}

// --- Teacher endpoints ---

async function listSessions(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT ${SESSION_COLUMNS.split(', ').map((c) => `s.${c}`).join(', ')}, COUNT(r.id) AS n
     FROM sessions s LEFT JOIN responses r ON r.session_id = s.id
     GROUP BY s.id ORDER BY s.created_at DESC`,
  ).all<SessionRow & { n: number }>();
  return json({ sessions: results.map((s) => sessionJson(s, s.n)) });
}

async function createSession(env: Env, request: Request): Promise<Response> {
  const body = await readBody<{ name?: unknown; game?: unknown; tasks?: unknown; cards?: unknown }>(request);
  const name = cleanName(body.name);
  if (typeof body.game !== 'string' || !GAMES.includes(body.game)) throw new HttpError(400, 'bad_game');
  const settings = TASK_GAMES.includes(body.game)
    ? { tasks: validateTasks(body.game, body.tasks) }
    : body.game === 'cards'
      ? validateCards(body.cards)
      : {};
  const id = crypto.randomUUID();
  const token = randomToken();
  await env.DB.prepare('INSERT INTO sessions (id, name, game, token_hash, settings, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(id, name, body.game, await sha256(token), JSON.stringify(settings), nowSec())
    .run();
  return json({ session: sessionJson(await sessionOr404(env, id), 0), token }, 201);
}

async function updateSession(env: Env, request: Request, id: string): Promise<Response> {
  await sessionOr404(env, id);
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
  return json({ session: sessionJson(await sessionOr404(env, id)) });
}

/** Starts the clock of a timed game for everyone, changes the time left, or with 0 seconds stops it. */
async function setTimer(env: Env, request: Request, id: string): Promise<Response> {
  const s = await sessionOr404(env, id);
  if (!TIMED_GAMES.includes(s.game)) throw new HttpError(400, 'bad_game');
  const { seconds, center, zoom } = await readBody<{ seconds?: unknown; center?: unknown; zoom?: unknown }>(request);
  if (typeof seconds !== 'number' || !Number.isInteger(seconds) || seconds < 0 || seconds > MAX_TIMER_SEC) {
    throw new HttpError(400, 'bad_timer');
  }
  const settings = JSON.parse(s.settings) as Record<string, unknown>;
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
  return json({ session: sessionJson(await sessionOr404(env, id)) });
}

async function newToken(env: Env, id: string): Promise<Response> {
  await sessionOr404(env, id);
  const token = randomToken();
  await env.DB.prepare('UPDATE sessions SET token_hash = ? WHERE id = ?').bind(await sha256(token), id).run();
  return json({ token });
}

async function deleteSession(env: Env, id: string): Promise<Response> {
  await sessionOr404(env, id);
  await env.DB.prepare('DELETE FROM sessions WHERE id = ?').bind(id).run();
  return json({ ok: true });
}

async function listResponses(env: Env, url: URL, id: string): Promise<Response> {
  const s = await sessionOr404(env, id);
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

async function resetResponses(env: Env, id: string): Promise<Response> {
  await sessionOr404(env, id);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id = ?').bind(id),
    // Tells students' devices to forget their progress in the game.
    env.DB.prepare("UPDATE sessions SET settings = json_remove(json_set(settings, '$.resetAt', unixepoch()), '$.endsAt') WHERE id = ?").bind(id),
    bumpRev(env, id),
  ]);
  return json({ ok: true });
}

async function updateResponse(env: Env, request: Request, id: string): Promise<Response> {
  const { hidden } = await readBody<{ hidden?: unknown }>(request);
  if (typeof hidden !== 'boolean') throw new HttpError(400, 'bad_hidden');
  const r = await env.DB.prepare('SELECT session_id FROM responses WHERE id = ?').bind(id).first<{ session_id: string }>();
  if (!r) throw new HttpError(404, 'not_found');
  await env.DB.batch([
    env.DB.prepare('UPDATE responses SET hidden = ? WHERE id = ?').bind(hidden ? 1 : 0, id),
    bumpRev(env, r.session_id),
  ]);
  return json({ ok: true });
}

async function deleteResponse(env: Env, id: string): Promise<Response> {
  const r = await env.DB.prepare('SELECT session_id FROM responses WHERE id = ?').bind(id).first<{ session_id: string }>();
  if (!r) throw new HttpError(404, 'not_found');
  await env.DB.batch([env.DB.prepare('DELETE FROM responses WHERE id = ?').bind(id), bumpRev(env, r.session_id)]);
  return json({ ok: true });
}

// --- Backup. QR tokens are left out: a restored session starts closed and needs a new QR. ---

async function backup(env: Env, url: URL): Promise<Response> {
  const only = url.searchParams.get('session');
  const sessions = only
    ? await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE id = ?`).bind(only).all<SessionRow>()
    : await env.DB.prepare(`SELECT ${SESSION_COLUMNS} FROM sessions ORDER BY created_at`).all<SessionRow>();
  const responses = only
    ? await env.DB.prepare('SELECT * FROM responses WHERE session_id = ? ORDER BY created_at').bind(only).all<ResponseRow>()
    : await env.DB.prepare('SELECT * FROM responses ORDER BY created_at').all<ResponseRow>();
  return json({
    format: 'geoclass-backup',
    version: 2,
    exportedAt: nowSec(),
    sessions: sessions.results.map((s) => sessionJson(s)),
    responses: responses.results.map(responseJson),
  });
}

type BackupSession = { id?: unknown; name?: unknown; game?: unknown; archived?: unknown; settings?: { tasks?: unknown; pairs?: unknown; arrow?: unknown; rotation?: unknown }; createdAt?: unknown };
type BackupResponse = {
  id?: unknown;
  sessionId?: unknown;
  participantId?: unknown;
  round?: unknown;
  answer?: unknown;
  lat?: unknown;
  lon?: unknown;
  hidden?: unknown;
  createdAt?: unknown;
};

function restoredTasks(game: string, raw: unknown): Task[] {
  try {
    return validateTasks(game, raw);
  } catch {
    throw new HttpError(400, 'bad_backup');
  }
}

/** The settings a restored session keeps: the task list or the deck. The clock is not restored. */
function restoredSettings(game: string, tasks: Task[], raw: BackupSession['settings']): object {
  if (TASK_GAMES.includes(game)) return { tasks };
  if (game !== 'cards') return {};
  try {
    return validateCards(raw);
  } catch {
    throw new HttpError(400, 'bad_backup');
  }
}

async function restore(env: Env, request: Request): Promise<Response> {
  const data = await readBody<{ format?: unknown; version?: unknown; sessions?: BackupSession[]; responses?: BackupResponse[] }>(
    request,
    MAX_RESTORE_BYTES,
  );
  if (data.format !== 'geoclass-backup' || (data.version !== 1 && data.version !== 2) || !Array.isArray(data.sessions) || !Array.isArray(data.responses)) {
    throw new HttpError(400, 'bad_backup');
  }

  // Everything is validated first, so a bad file changes nothing.
  const games = new Map<string, { game: string; tasks: Task[] }>();
  const statements: D1PreparedStatement[] = [];
  for (const s of data.sessions) {
    if (typeof s.id !== 'string' || !ID_RE.test(s.id) || typeof s.game !== 'string' || !GAMES.includes(s.game) || typeof s.createdAt !== 'number') {
      throw new HttpError(400, 'bad_backup');
    }
    const tasks = TASK_GAMES.includes(s.game) ? restoredTasks(s.game, s.settings?.tasks) : [];
    games.set(s.id, { game: s.game, tasks });
    statements.push(
      env.DB.prepare(
        "INSERT OR IGNORE INTO sessions (id, name, game, status, token_hash, archived, settings, created_at) VALUES (?, ?, ?, 'closed', ?, ?, ?, ?)",
      ).bind(
        s.id,
        cleanName(s.name),
        s.game,
        await sha256(randomToken()),
        s.archived === true ? 1 : 0,
        JSON.stringify(restoredSettings(s.game, tasks, s.settings)),
        s.createdAt,
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
    const taskGame = TASK_GAMES.includes(session.game);
    // A mapping student has many objects and a cards student many tries, told apart by their number.
    const round = taskGame || (TIMED_GAMES.includes(session.game) && typeof r.round === 'number') ? r.round : 0;
    const task = taskGame && typeof round === 'number' ? session.tasks[round] : undefined;
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
        distance === null ? null : scoreFor(distance),
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
  // Deliberately public: the key minus its ending, which the owner keeps in their head. Unset, it's a 404.
  if (key === 'GET key-hint') {
    if (!env.TEACHER_KEY_HINT) throw new HttpError(404, 'not_found');
    return json({ hint: env.TEACHER_KEY_HINT });
  }

  await requireTeacher(env, request);

  if (key === 'GET me') return json({ ok: true });
  if (key === 'GET backup') return backup(env, url);
  if (key === 'POST restore') return restore(env, request);

  const [resource, id, child] = parts;
  if (resource === 'sessions') {
    if (!id) {
      if (method === 'GET') return listSessions(env);
      if (method === 'POST') return createSession(env, request);
    } else if (!child) {
      if (method === 'PATCH') return updateSession(env, request, id);
      if (method === 'DELETE') return deleteSession(env, id);
    } else if (child === 'token' && method === 'POST') {
      return newToken(env, id);
    } else if (child === 'timer' && method === 'POST') {
      return setTimer(env, request, id);
    } else if (child === 'responses') {
      if (method === 'GET') return listResponses(env, url, id);
      if (method === 'DELETE') return resetResponses(env, id);
    }
  }
  if (resource === 'responses' && id && !child) {
    if (method === 'PATCH') return updateResponse(env, request, id);
    if (method === 'DELETE') return deleteResponse(env, id);
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
} satisfies ExportedHandler<Env>;
