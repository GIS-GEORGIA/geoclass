import { HttpError, validateAnswer } from './validate';

const MAX_RESPONSES_PER_SESSION = 500;
const MAX_BODY_BYTES = 8 * 1024;
const MAX_RESTORE_BYTES = 4 * 1024 * 1024;
const D1_BATCH_SIZE = 50;
const ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

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
  created_at: number;
};

const SESSION_COLUMNS = 'id, name, game, status, rev, archived, created_at';

function sessionJson(s: SessionRow, count?: number) {
  return {
    id: s.id,
    name: s.name,
    game: s.game,
    status: s.status,
    rev: s.rev,
    archived: s.archived === 1,
    createdAt: s.created_at,
    ...(count === undefined ? {} : { responses: count }),
  };
}

type ResponseRow = {
  id: string;
  session_id: string;
  participant_id: string;
  answer: string;
  lat: number;
  lon: number;
  hidden: number;
  created_at: number;
};

function responseJson(r: ResponseRow) {
  return {
    id: r.id,
    sessionId: r.session_id,
    participantId: r.participant_id,
    answer: JSON.parse(r.answer),
    lat: r.lat,
    lon: r.lon,
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
  return json({ name: s.name, game: s.game, status: s.status });
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

  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses WHERE session_id = ? AND participant_id != ?')
    .bind(s.id, participantId)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_RESPONSES_PER_SESSION) throw new HttpError(429, 'session_full');

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
  const body = await readBody<{ name?: unknown; game?: unknown }>(request);
  const name = cleanName(body.name);
  if (body.game !== 'travel') throw new HttpError(400, 'bad_game');
  const id = crypto.randomUUID();
  const token = randomToken();
  await env.DB.prepare('INSERT INTO sessions (id, name, game, token_hash, created_at) VALUES (?, ?, ?, ?, ?)')
    .bind(id, name, body.game, await sha256(token), nowSec())
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
  await env.DB.batch([env.DB.prepare('DELETE FROM responses WHERE session_id = ?').bind(id), bumpRev(env, id)]);
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
    version: 1,
    exportedAt: nowSec(),
    sessions: sessions.results.map((s) => sessionJson(s)),
    responses: responses.results.map(responseJson),
  });
}

type BackupSession = { id?: unknown; name?: unknown; game?: unknown; archived?: unknown; createdAt?: unknown };
type BackupResponse = {
  id?: unknown;
  sessionId?: unknown;
  participantId?: unknown;
  answer?: unknown;
  lat?: unknown;
  lon?: unknown;
  hidden?: unknown;
  createdAt?: unknown;
};

async function restore(env: Env, request: Request): Promise<Response> {
  const data = await readBody<{ format?: unknown; version?: unknown; sessions?: BackupSession[]; responses?: BackupResponse[] }>(
    request,
    MAX_RESTORE_BYTES,
  );
  if (data.format !== 'geoclass-backup' || data.version !== 1 || !Array.isArray(data.sessions) || !Array.isArray(data.responses)) {
    throw new HttpError(400, 'bad_backup');
  }

  // Everything is validated first, so a bad file changes nothing.
  const sessionIds = new Set<string>();
  const statements: D1PreparedStatement[] = [];
  for (const s of data.sessions) {
    if (typeof s.id !== 'string' || !ID_RE.test(s.id) || s.game !== 'travel' || typeof s.createdAt !== 'number') {
      throw new HttpError(400, 'bad_backup');
    }
    sessionIds.add(s.id);
    statements.push(
      env.DB.prepare(
        "INSERT OR IGNORE INTO sessions (id, name, game, status, token_hash, archived, created_at) VALUES (?, ?, ?, 'closed', ?, ?, ?)",
      ).bind(s.id, cleanName(s.name), s.game, await sha256(randomToken()), s.archived === true ? 1 : 0, s.createdAt),
    );
  }
  for (const r of data.responses) {
    const valid =
      typeof r.id === 'string' &&
      ID_RE.test(r.id) &&
      typeof r.sessionId === 'string' &&
      sessionIds.has(r.sessionId) &&
      typeof r.participantId === 'string' &&
      ID_RE.test(r.participantId) &&
      typeof r.lat === 'number' &&
      Math.abs(r.lat) <= 90 &&
      typeof r.lon === 'number' &&
      Math.abs(r.lon) <= 180 &&
      typeof r.createdAt === 'number';
    if (!valid) throw new HttpError(400, 'bad_backup');
    const answer = validateAnswer('travel', r.answer);
    statements.push(
      env.DB.prepare(
        'INSERT OR IGNORE INTO responses (id, session_id, participant_id, answer, lat, lon, hidden, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ).bind(r.id, r.sessionId, r.participantId, JSON.stringify(answer), r.lat, r.lon, r.hidden === true ? 1 : 0, r.createdAt),
    );
  }

  for (const id of sessionIds) statements.push(bumpRev(env, id));
  for (let i = 0; i < statements.length; i += D1_BATCH_SIZE) {
    await env.DB.batch(statements.slice(i, i + D1_BATCH_SIZE));
  }
  return json({ ok: true, sessions: sessionIds.size, responses: data.responses.length });
}

// --- Routing ---

async function route(request: Request, env: Env, url: URL): Promise<Response> {
  const parts = url.pathname.split('/').filter(Boolean).slice(1); // drop "api"
  const { method } = request;
  const key = `${method} ${parts[0] ?? ''}`;

  if (key === 'GET health') return json({ ok: true });
  if (key === 'POST join') return join(env, request);
  if (key === 'POST submit') return submit(env, request);

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
