import { env, exports } from 'cloudflare:workers';
import { registerGame } from '../src/games/registry';
import { routeCost, routeThrough, type Heights } from '../src/games/least_cost';
import type { GameModule } from '../src/games/types';
import { HttpError } from '../src/validate';
import { beforeEach, describe, expect, it } from 'vitest';

const KEY = 'test-teacher-key';
const auth = { Authorization: `Bearer ${KEY}` };
const answer = { place: 'Paris', country: 'FR', reason: 'Louvre', transport: 'plane', company: 'friends' };

function call(method: string, path: string, body?: unknown, headers: Record<string, string> = auth) {
  return exports.default.fetch(`https://geoclass.test/api/${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const student = (path: string, body: unknown) => call('POST', path, body, {});

let n = 0;
const id = (prefix: string) => `${prefix}-0000-${++n}`;

async function newSession() {
  const res = await call('POST', 'sessions', { name: 'VII a', game: 'travel' });
  expect(res.status).toBe(201);
  return (await res.json()) as { session: { id: string; rev: number }; token: string };
}

function send(token: string, over: Record<string, unknown> = {}) {
  return student('submit', {
    token,
    submissionId: id('sub'),
    participantId: id('par'),
    answer,
    lat: 48.85,
    lon: 2.35,
    ...over,
  });
}

async function responses(sessionId: string) {
  const res = await call('GET', `sessions/${sessionId}/responses`);
  return (await res.json()) as {
    session: { rev: number; status: string };
    responses: { id: string; hidden: boolean; answer: { place: string } }[];
  };
}

beforeEach(async () => {
  await env.DB.exec('DELETE FROM sessions');
  await env.DB.exec('DELETE FROM auth_failures');
  await env.DB.exec('DELETE FROM teachers');
});

describe('teacher access', () => {
  it('rejects a missing or wrong key', async () => {
    expect((await call('GET', 'sessions', undefined, {})).status).toBe(401);
    expect((await call('GET', 'sessions', undefined, { Authorization: 'Bearer nope' })).status).toBe(401);
    expect((await call('GET', 'backup', undefined, {})).status).toBe(401);
  });

  it('has no key hint any more: nothing about the key is given out', async () => {
    const open = await call('GET', 'key-hint', undefined, {});
    expect(open.status).toBe(401);
    expect(await open.text()).not.toContain('hint');
    const signedIn = await call('GET', 'key-hint');
    expect(signedIn.status).toBe(404);
    expect(await signedIn.text()).not.toContain('test-teacher');
  });

  it('API replies tell the browser not to guess their type', async () => {
    const res = await call('GET', 'me');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect((await call('GET', 'me', undefined, {})).headers.get('X-Content-Type-Options')).toBe('nosniff');
  });

  it('accepts the right key', async () => {
    expect((await call('GET', 'me')).status).toBe(200);
  });

  it('after 10 failed sign-ins from an address, answers 429 to it, even for the right key', async () => {
    const from = (ip: string, key?: string) =>
      call('GET', 'me', undefined, { 'CF-Connecting-IP': ip, ...(key ? { Authorization: `Bearer ${key}` } : {}) });
    for (let i = 0; i < 10; i++) expect((await from('203.0.113.7', `wrong-${i}`)).status).toBe(401);
    const blocked = await from('203.0.113.7', 'wrong-10');
    expect(blocked.status).toBe(429);
    expect(await blocked.json()).toEqual({ error: 'rate_limited' });
    expect((await from('203.0.113.7')).status).toBe(429);
    // A right guess looks the same as a wrong one while blocked.
    expect((await from('203.0.113.7', KEY)).status).toBe(429);
    // Other addresses are not affected.
    expect((await from('198.51.100.2', KEY)).status).toBe(200);
    expect((await from('198.51.100.2', 'wrong')).status).toBe(401);
  });

  it('lets an address in again when the minute is over, and counts afresh', async () => {
    const from = (key: string) => call('GET', 'me', undefined, { 'CF-Connecting-IP': '203.0.113.8', Authorization: `Bearer ${key}` });
    for (let i = 0; i < 10; i++) await from(`wrong-${i}`);
    expect((await from(KEY)).status).toBe(429);
    await env.DB.exec('UPDATE auth_failures SET window_start = window_start - 61');
    expect((await from(KEY)).status).toBe(200);
    expect((await from('wrong')).status).toBe(401);
    const row = await env.DB.prepare('SELECT count FROM auth_failures').first<{ count: number }>();
    expect(row?.count).toBe(1);
  });

  it('does not count right-key calls, so teacher polling never hits the limit', async () => {
    const headers = { ...auth, 'CF-Connecting-IP': '203.0.113.9' };
    for (let i = 0; i < 30; i++) expect((await call('GET', 'me', undefined, headers)).status).toBe(200);
    const { n } = (await env.DB.prepare('SELECT COUNT(*) AS n FROM auth_failures').first<{ n: number }>())!;
    expect(n).toBe(0);
  });

  it('keeps teacher work going after a few typos', async () => {
    const ip = { 'CF-Connecting-IP': '203.0.113.10' };
    for (let i = 0; i < 9; i++) expect((await call('GET', 'sessions', undefined, { ...ip, Authorization: 'Bearer typo' })).status).toBe(401);
    const created = await call('POST', 'sessions', { name: 'VII b', game: 'travel' }, { ...auth, ...ip });
    expect(created.status).toBe(201);
    const { session } = (await created.json()) as { session: { id: string } };
    expect((await call('GET', 'sessions', undefined, { ...auth, ...ip })).status).toBe(200);
    expect((await call('PATCH', `sessions/${session.id}`, { status: 'paused' }, { ...auth, ...ip })).status).toBe(200);
    expect((await call('DELETE', `sessions/${session.id}`, undefined, { ...auth, ...ip })).status).toBe(200);
  });

  it('keeps only a hash of the address, and deletes it after a day', async () => {
    await call('GET', 'me', undefined, { 'CF-Connecting-IP': '203.0.113.11' });
    const row = await env.DB.prepare('SELECT ip_hash, window_start FROM auth_failures').first<{ ip_hash: string; window_start: number }>();
    expect(row?.ip_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row?.ip_hash).not.toContain('203.0.113.11');
    const { deleteOldAuthFailures, AUTH_KEEP_SEC } = await import('../src/retention');
    expect(await deleteOldAuthFailures(env)).toBe(0);
    expect(await deleteOldAuthFailures(env, row!.window_start + AUTH_KEEP_SEC + 1)).toBe(1);
  });

  it('a QR token does not open teacher endpoints', async () => {
    const { token } = await newSession();
    expect((await call('GET', 'sessions', undefined, { Authorization: `Bearer ${token}` })).status).toBe(401);
  });
});

describe('sessions', () => {
  it('stores only the token hash', async () => {
    const { session, token } = await newSession();
    const row = await env.DB.prepare('SELECT token_hash FROM sessions WHERE id = ?').bind(session.id).first<{ token_hash: string }>();
    expect(row!.token_hash).not.toContain(token);
    expect(row!.token_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('rejects an unknown game and an empty name', async () => {
    expect((await call('POST', 'sessions', { name: 'x', game: 'chess' })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: ' ', game: 'travel' })).status).toBe(400);
  });

  it('a new QR token invalidates the old one', async () => {
    const { session, token } = await newSession();
    const res = await call('POST', `sessions/${session.id}/token`);
    const { token: fresh } = (await res.json()) as { token: string };
    expect((await student('join', { token })).status).toBe(404);
    expect((await student('join', { token: fresh })).status).toBe(200);
  });

  it('deleting a session removes its responses', async () => {
    const { session, token } = await newSession();
    await send(token);
    expect((await call('DELETE', `sessions/${session.id}`)).status).toBe(200);
    const left = await env.DB.prepare('SELECT COUNT(*) AS n FROM responses').first<{ n: number }>();
    expect(left!.n).toBe(0);
  });
});

describe('student submit', () => {
  it('join shows no other data', async () => {
    const { token } = await newSession();
    await send(token);
    const data = (await (await student('join', { token })).json()) as Record<string, unknown>;
    expect(Object.keys(data).sort()).toEqual(['game', 'name', 'now', 'settings', 'status']);
  });

  it('accepts an answer and shows it to the teacher', async () => {
    const { session, token } = await newSession();
    expect((await send(token)).status).toBe(201);
    const { responses: rows } = await responses(session.id);
    expect(rows).toHaveLength(1);
    expect(rows[0].answer.place).toBe('Paris');
  });

  it('rejects a wrong token', async () => {
    expect((await send('wrong-token')).status).toBe(404);
  });

  it('refuses answers while paused or closed', async () => {
    const { session, token } = await newSession();
    await call('PATCH', `sessions/${session.id}`, { status: 'paused' });
    expect((await send(token)).status).toBe(409);
    await call('PATCH', `sessions/${session.id}`, { status: 'closed' });
    const res = await send(token);
    expect(res.status).toBe(409);
    expect(((await res.json()) as { error: string }).error).toBe('session_closed');
  });

  it('a repeated submission id stores one row, even after closing', async () => {
    const { session, token } = await newSession();
    const fixed = { submissionId: 'same-submission-1', participantId: 'same-participant-1' };
    expect((await send(token, fixed)).status).toBe(201);
    expect((await send(token, fixed)).status).toBe(200);
    await call('PATCH', `sessions/${session.id}`, { status: 'closed' });
    expect((await send(token, fixed)).status).toBe(200);
    expect((await responses(session.id)).responses).toHaveLength(1);
  });

  it('a new answer from the same student replaces the old one', async () => {
    const { session, token } = await newSession();
    const participantId = 'same-participant-2';
    await send(token, { participantId });
    await send(token, { participantId, answer: { ...answer, place: 'Rome' } });
    const { responses: rows } = await responses(session.id);
    expect(rows).toHaveLength(1);
    expect(rows[0].answer.place).toBe('Rome');
  });

  it('rejects bad data', async () => {
    const { token } = await newSession();
    expect((await send(token, { lat: 91 })).status).toBe(400);
    expect((await send(token, { lon: '2' })).status).toBe(400);
    expect((await send(token, { submissionId: 'x' })).status).toBe(400);
    expect((await send(token, { answer: { ...answer, transport: 'rocket' } })).status).toBe(400);
    expect((await send(token, { answer: { ...answer, place: '' } })).status).toBe(400);
    expect((await send(token, { answer: { ...answer, reason: 'x'.repeat(501) } })).status).toBe(400);
  });

  it('stores only known answer fields', async () => {
    const { session, token } = await newSession();
    await send(token, { answer: { ...answer, phone: '555' } });
    const { responses: rows } = await responses(session.id);
    expect(rows[0].answer).not.toHaveProperty('phone');
  });

  it('survives text that looks like SQL', async () => {
    const { session, token } = await newSession();
    const place = "x'); DROP TABLE responses;--";
    expect((await send(token, { answer: { ...answer, place } })).status).toBe(201);
    expect((await responses(session.id)).responses[0].answer.place).toBe(place);
  });
});

describe('polling', () => {
  it('skips the list while nothing changed, and sees every kind of change', async () => {
    const { session, token } = await newSession();
    const get = async (rev: number) =>
      (await (await call('GET', `sessions/${session.id}/responses?rev=${rev}`)).json()) as {
        changed: boolean;
        session: { rev: number };
        responses?: { id: string }[];
      };

    let rev = (await get(-1)).session.rev;
    expect((await get(rev)).changed).toBe(false);

    await send(token);
    let now = await get(rev);
    expect(now.changed).toBe(true);
    rev = now.session.rev;

    await call('PATCH', `responses/${now.responses![0].id}`, { hidden: true });
    now = await get(rev);
    expect(now.changed).toBe(true);
    rev = now.session.rev;

    await call('DELETE', `sessions/${session.id}/responses`);
    now = await get(rev);
    expect(now.changed).toBe(true);
    expect(now.responses).toHaveLength(0);
  });
});

describe('moderation and reset', () => {
  it('hides and deletes one answer', async () => {
    const { session, token } = await newSession();
    await send(token);
    const [row] = (await responses(session.id)).responses;
    await call('PATCH', `responses/${row.id}`, { hidden: true });
    expect((await responses(session.id)).responses[0].hidden).toBe(true);
    await call('DELETE', `responses/${row.id}`);
    expect((await responses(session.id)).responses).toHaveLength(0);
  });

  it('reset clears only that session', async () => {
    const a = await newSession();
    const b = await newSession();
    await send(a.token);
    await send(b.token);
    await call('DELETE', `sessions/${a.session.id}/responses`);
    expect((await responses(a.session.id)).responses).toHaveLength(0);
    expect((await responses(b.session.id)).responses).toHaveLength(1);
  });

  it('reset tells students to start again and keeps the tasks', async () => {
    const res = await call('POST', 'sessions', {
      name: 'Coords',
      game: 'coordinates',
      tasks: [{ lat: 41.7, lon: 44.8, mode: 'to_map', format: 'dd', label: '' }],
    });
    const { session, token } = (await res.json()) as { session: { id: string }; token: string };
    await call('DELETE', `sessions/${session.id}/responses`);
    const joined = (await (await student('join', { token })).json()) as { settings: { resetAt: number; tasks: unknown[] } };
    expect(joined.settings.resetAt).toBeGreaterThan(0);
    expect(joined.settings.tasks).toHaveLength(1);
  });
});

describe('backup and restore', () => {
  async function exported() {
    return (await (await call('GET', 'backup')).json()) as {
      sessions: { id: string; status: string }[];
      responses: unknown[];
    };
  }

  it('contains no QR token data', async () => {
    const { token } = await newSession();
    await send(token);
    const text = JSON.stringify(await exported());
    expect(text).not.toContain(token);
    expect(text).not.toContain('token');
  });

  it('restores after a wipe, closed, without duplicates when repeated', async () => {
    const { session, token } = await newSession();
    await send(token);
    const file = await exported();
    await call('DELETE', `sessions/${session.id}`);

    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await call('POST', 'restore', file)).status).toBe(200);

    const after = await exported();
    expect(after.sessions).toHaveLength(1);
    expect(after.sessions[0].status).toBe('closed');
    expect(after.responses).toHaveLength(1);
    expect((await student('join', { token })).status).toBe(404);
  });

  it('a bad file changes nothing', async () => {
    const { session, token } = await newSession();
    await send(token);
    const file = await exported();
    await call('DELETE', `sessions/${session.id}`);
    (file.responses[0] as { lat: number }).lat = 500;
    expect((await call('POST', 'restore', file)).status).toBe(400);
    expect((await call('POST', 'restore', { format: 'other' })).status).toBe(400);
    expect((await exported()).sessions).toHaveLength(0);
  });
});

describe('mapping game', () => {
  const point = { kind: 'point', category: 'park', coords: [[44.8, 41.7]] };

  async function game() {
    const res = await call('POST', 'sessions', { name: 'Uban', game: 'mapping' });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string }; token: string };
  }

  const draw = (token: string, answer: unknown, participantId = 'student-0001') =>
    student('submit', { token, submissionId: id('sub'), participantId, answer, lat: 0, lon: 0 });

  const start = (sessionId: string, seconds = 180) =>
    call('POST', `sessions/${sessionId}/timer`, { seconds, center: [41.7, 44.8], zoom: 14 });

  async function rows(sessionId: string) {
    return (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as {
      responses: { round: number; lat: number; lon: number; answer: { coords: number[][]; kind: string } }[];
    };
  }

  it('waits for the teacher, then takes points, lines and polygons', async () => {
    const { session, token } = await game();
    expect((await draw(token, point)).status).toBe(409);

    expect((await start(session.id)).status).toBe(200);
    const joined = (await (await student('join', { token })).json()) as { settings: { endsAt: number; center: number[]; zoom: number }; now: number };
    expect(joined.settings.endsAt - joined.now).toBeGreaterThan(170);
    expect(joined.settings.center).toEqual([41.7, 44.8]);

    expect((await draw(token, point)).status).toBe(201);
    expect((await draw(token, { kind: 'line', category: 'park', coords: [[44.81, 41.7], [44.82, 41.71]] })).status).toBe(201);
    const square = [[44.9, 41.8], [44.91, 41.8], [44.91, 41.81]];
    expect((await draw(token, { kind: 'polygon', category: 'stadium', coords: square })).status).toBe(201);

    const { responses } = await rows(session.id);
    expect(responses.map((r) => r.round)).toEqual([0, 1, 2]);
    // The server works out the location itself.
    expect(responses[0].lat).toBeCloseTo(41.7);
    expect(responses[2].answer.kind).toBe('polygon');
    expect(responses[2].lon).toBeCloseTo((44.9 + 44.91 + 44.91) / 3);
  });

  it('refuses bad shapes and the same place twice', async () => {
    const { session, token } = await game();
    await start(session.id);
    expect((await draw(token, { kind: 'polygon', category: 'park', coords: [[44, 41], [45, 41]] })).status).toBe(400);
    expect((await draw(token, { kind: 'line', category: 'park', coords: [[44, 41]] })).status).toBe(400);
    expect((await draw(token, { kind: 'point', category: 'park', coords: [[44, 41], [45, 41]] })).status).toBe(400);
    expect((await draw(token, { kind: 'point', category: 'nope', coords: [[44, 41]] })).status).toBe(400);
    expect((await draw(token, { kind: 'point', category: 'park', coords: [[244, 41]] })).status).toBe(400);
    expect((await draw(token, { kind: 'point', category: 'park', coords: Array(101).fill([44, 41]) })).status).toBe(400);

    expect((await draw(token, point)).status).toBe(201);
    const again = await draw(token, point);
    expect(again.status).toBe(409);
    expect(await again.json()).toEqual({ error: 'same_place' });
    // Another category, or another student, is a different object.
    expect((await draw(token, { ...point, category: 'food' })).status).toBe(201);
    expect((await draw(token, point, 'student-0002')).status).toBe(201);
  });

  it('stops when the teacher stops the clock, and a reset starts over', async () => {
    const { session, token } = await game();
    await start(session.id, 0);
    await env.DB.prepare("UPDATE sessions SET settings = json_set(settings, '$.endsAt', unixepoch() - 60) WHERE id = ?").bind(session.id).run();
    const late = await draw(token, point);
    expect(late.status).toBe(409);
    expect(await late.json()).toEqual({ error: 'time_up' });

    await call('DELETE', `sessions/${session.id}/responses`);
    expect(await (await draw(token, point)).json()).toEqual({ error: 'not_started' });
  });

  it('only sets a valid timer, and only on this game', async () => {
    const { session } = await game();
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: -1 })).status).toBe(400);
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 4000 })).status).toBe(400);
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 60, center: [99, 0] })).status).toBe(400);
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 60 }, {})).status).toBe(401);
    const other = await newSession();
    expect((await call('POST', `sessions/${other.session.id}/timer`, { seconds: 60 })).status).toBe(400);
  });

  it('keeps every object through a backup', async () => {
    const { session, token } = await game();
    await start(session.id);
    await draw(token, point);
    await draw(token, { kind: 'line', category: 'food', coords: [[44.81, 41.7], [44.82, 41.71]] });
    const file = await (await call('GET', `backup?session=${session.id}`)).json();
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await rows(session.id)).responses.length).toBe(2);
  });
});

describe('puzzle game', () => {
  const settings = { kind: 'municipalities', area: 'ge_guria', rotation: 'quarter', help: 'frame', names: true, look: 'map', base: 'topo', seed: 7, pieces: 3 };

  async function game(puzzle: unknown = settings) {
    const res = await call('POST', 'sessions', { name: 'Puzzle', game: 'puzzle', puzzle });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: Record<string, unknown> }; token: string };
  }

  const play = (token: string, answer: unknown, participantId = 'student-0001') =>
    student('submit', { token, submissionId: id('sub'), participantId, answer, lat: 0, lon: 0 });

  it('keeps the settings, waits for the clock, then counts each piece once and every miss', async () => {
    const { session, token } = await game({ ...settings, extra: 'dropped' });
    expect(session.settings).toEqual({ ...settings, rows: 0, cols: 0 });
    expect((await play(token, { ok: true, piece: 0 })).status).toBe(409);
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 300 })).status).toBe(200);

    expect((await play(token, { ok: false, piece: 2 })).status).toBe(201);
    expect((await play(token, { ok: true, piece: 2 })).status).toBe(201);
    expect(await (await play(token, { ok: true, piece: 2 })).json()).toEqual({ ok: true, duplicate: true });
    expect((await play(token, { ok: false, piece: 1 })).status).toBe(201);
    expect((await play(token, { ok: true, piece: 3 })).status).toBe(400);
    expect((await play(token, { ok: true, pair: 0 })).status).toBe(400);

    const { responses } = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as {
      responses: { round: number; answer: { ok: boolean; piece: number } }[];
    };
    expect(responses.map((r) => [r.round, r.answer.ok, r.answer.piece])).toEqual([
      [100, false, 2],
      [2, true, 2],
      [101, false, 1],
    ]);
  });

  it('remembers when the round began, through added minutes, until a reset', async () => {
    const { session } = await game();
    const timer = async (seconds: number) =>
      ((await (await call('POST', `sessions/${session.id}/timer`, { seconds })).json()) as { session: { settings: { startedAt?: number } } })
        .session.settings.startedAt;
    const started = await timer(300);
    expect(started).toBeGreaterThan(0);
    await env.DB.prepare("UPDATE sessions SET settings = json_set(settings, '$.startedAt', 5) WHERE id = ?").bind(session.id).run();
    expect(await timer(400)).toBe(5);
    await call('DELETE', `sessions/${session.id}/responses`);
    const joined = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { session: { settings: Record<string, unknown> } };
    expect(joined.session.settings.startedAt).toBeUndefined();
  });

  it('a grid has rows times columns pieces', async () => {
    const { session } = await game({ kind: 'grid', area: 'georgia', rows: 4, cols: 6, seed: 1, pieces: 2 });
    expect(session.settings.pieces).toBe(24);
    expect(session.settings.rotation).toBe('none');
  });

  it('rejects a bad puzzle', async () => {
    const bad = async (puzzle: unknown) => (await call('POST', 'sessions', { name: 'x', game: 'puzzle', puzzle })).status;
    expect(await bad(undefined)).toBe(400);
    expect(await bad({ ...settings, kind: 'jigsaw' })).toBe(400);
    expect(await bad({ ...settings, kind: 'regions' })).toBe(400);
    expect(await bad({ ...settings, area: '../x' })).toBe(400);
    expect(await bad({ ...settings, pieces: 81 })).toBe(400);
    expect(await bad({ ...settings, pieces: 1 })).toBe(400);
    expect(await bad({ ...settings, seed: -1 })).toBe(400);
    expect(await bad({ ...settings, help: 'all' })).toBe(400);
    expect(await bad({ kind: 'grid', area: 'georgia', rows: 9, cols: 3, seed: 1 })).toBe(400);
  });

  it('survives a backup and a restore', async () => {
    const { session, token } = await game();
    await call('POST', `sessions/${session.id}/timer`, { seconds: 300 });
    await play(token, { ok: true, piece: 1 });
    const file = await (await call('GET', `backup?session=${session.id}`)).json();
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const restored = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as {
      session: { settings: Record<string, unknown> };
      responses: { round: number }[];
    };
    expect(restored.session.settings.pieces).toBe(3);
    expect(restored.responses.map((r) => r.round)).toEqual([1]);
  });
});

describe('map layout game', () => {
  const layout = { area: 'georgia', legend: [3, 0, 1, 2] };
  const sheet = (over: Record<string, unknown> = {}) => ({
    fills: [3, 0, 2, -1],
    elements: [
      { kind: 'title', x: 0.3, y: 0.02, w: 0.4, h: 0.08 },
      { kind: 'north', x: 0.9, y: 0.1, w: 0.06, h: 0.1 },
      { kind: 'legend', x: 1.2, y: 0.5, w: 0.2, h: 0.3 },
    ],
    grid: 0.5,
    title: 'საქართველოს რეგიონები',
    ...over,
  });

  async function game() {
    const res = await call('POST', 'sessions', { name: 'Layout', game: 'layout', layout: { ...layout, extra: 1 } });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: unknown }; token: string };
  }

  const hand = (token: string, answer: unknown, participantId = 'student-0001') =>
    student('submit', { token, submissionId: id('sub'), participantId, answer, lat: 0, lon: 0 });

  async function rows(sessionId: string) {
    return (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as {
      responses: { participantId: string; score: number; answer: { title: string } }[];
    };
  }

  it('scores a sheet on the server, and a second one replaces the first', async () => {
    const { session, token } = await game();
    expect(session.settings).toEqual(layout);
    const res = await hand(token, sheet());
    expect(res.status).toBe(201);
    // 2 of 4 colours right (35), title and north on the page (12), the legend off it, the grid on (6).
    expect(((await res.json()) as { score: number }).score).toBe(53);
    expect((await hand(token, sheet({ fills: [3, 0, 1, 2], title: '' }))).status).toBe(201);
    await hand(token, sheet(), 'student-0002');
    const { responses } = await rows(session.id);
    expect(responses.map((r) => [r.participantId, r.score])).toEqual([
      ['student-0001', 82],
      ['student-0002', 53],
    ]);
  });

  it('rejects a bad sheet or a bad legend', async () => {
    const { token } = await game();
    expect((await hand(token, sheet({ fills: [0, 1] }))).status).toBe(400);
    expect((await hand(token, sheet({ grid: 2 }))).status).toBe(400);
    expect((await hand(token, sheet({ elements: [{ kind: 'logo', x: 0, y: 0, w: 0.1, h: 0.1 }] }))).status).toBe(400);
    expect((await hand(token, sheet({ elements: [{ kind: 'north', x: 0, y: 0, w: 0, h: 0.1 }] }))).status).toBe(400);
    expect((await hand(token, sheet({ title: 'x'.repeat(81) }))).status).toBe(400);
    const bad = async (l: unknown) => (await call('POST', 'sessions', { name: 'x', game: 'layout', layout: l })).status;
    expect(await bad(undefined)).toBe(400);
    expect(await bad({ area: 'georgia', legend: [1] })).toBe(400);
    expect(await bad({ area: 'georgia', legend: [0, 80] })).toBe(400);
    expect(await bad({ area: 'x/y', legend: [0, 1] })).toBe(400);
  });

  it('survives a backup and a restore, score worked out again', async () => {
    const { session, token } = await game();
    await hand(token, sheet());
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { score?: number }[] };
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await rows(session.id)).responses.map((r) => r.score)).toEqual([53]);
  });
});

describe('cards game', () => {
  const pairs = ['a', 'b', 'c'].map((x, i) => ({ a: `${x}-1.jpg`, b: `${x}-2.jpg`, label: `ადგილი ${i}`, ra: 0, rb: i * 90 }));
  const deck = { pairs, arrow: true, rotation: 'quarter' };

  async function game(over: Record<string, unknown> = {}) {
    const res = await call('POST', 'sessions', { name: 'Cards', game: 'cards', cards: deck, ...over });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: { order?: number[]; answers?: string } }; token: string };
  }

  const play = (token: string, answer: unknown, participantId = 'student-0001', submissionId = id('sub')) =>
    student('submit', { token, submissionId, participantId, answer, lat: 0, lon: 0 });

  const start = (sessionId: string, seconds = 180) => call('POST', `sessions/${sessionId}/timer`, { seconds });

  async function rows(sessionId: string) {
    return (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as {
      responses: { round: number; participantId: string; answer: { ok: boolean; pair?: number; x?: number; y?: number } }[];
    };
  }

  /** The two card ids of a pair, read from the hidden order as only the teacher's side can. */
  const idsOf = (order: number[], pair: number) => [order.indexOf(pair * 2), order.indexOf(pair * 2 + 1)];

  it('online is the default: students get opaque cards, no pairs, file names or labels', async () => {
    const { session, token } = await game();
    expect(session.settings.answers).toBe('online');
    expect([...session.settings.order!].sort()).toEqual([0, 1, 2, 3, 4, 5]);
    const res = await student('join', { token });
    const text = await res.text();
    const joined = JSON.parse(text) as { settings: Record<string, unknown> & { cards: { id: number; r: number }[] } };
    expect(joined.settings).not.toHaveProperty('pairs');
    expect(joined.settings).not.toHaveProperty('order');
    expect(joined.settings.cards.map((c) => c.id)).toEqual([0, 1, 2, 3, 4, 5]);
    expect(joined.settings.arrow).toBe(true);
    for (const secret of ['a-1', 'b-2', '.jpg', 'ადგილი']) expect(text).not.toContain(secret);
    // Each card keeps its own turn.
    const turns = pairs.flatMap((p) => [p.ra, p.rb]);
    expect(joined.settings.cards.map((c) => c.r)).toEqual(session.settings.order!.map((c) => turns[c]));
  });

  it('hands the cards to students once the clock runs', async () => {
    const { session, token } = await game();
    const joined = (await (await student('join', { token })).json()) as { settings: { endsAt?: number } };
    expect(joined.settings.endsAt).toBeUndefined();
    expect((await play(token, { a: 0, b: 1 })).status).toBe(409);
    expect((await start(session.id)).status).toBe(200);
    const running = (await (await student('join', { token })).json()) as { settings: { endsAt: number }; now: number };
    expect(running.settings.endsAt - running.now).toBeGreaterThan(170);
  });

  it('the server decides whether two cards match', async () => {
    const { session, token } = await game();
    await start(session.id);
    const order = session.settings.order!;
    const [a, b] = idsOf(order, 1);
    const found = await play(token, { a, b });
    expect(found.status).toBe(201);
    expect(await found.json()).toMatchObject({ match: true });
    const again = await play(token, { a: b, b: a });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ ok: true, duplicate: true, match: true });
    const [c] = idsOf(order, 0);
    const [, d] = idsOf(order, 2);
    expect(await (await play(token, { a: c, b: d })).json()).toMatchObject({ match: false });
    expect(await (await play(token, { a: c, b: d })).json()).toMatchObject({ match: false });
    // Another student finds the same pair: that is a different answer.
    expect((await play(token, { a, b }, 'student-0002')).status).toBe(201);

    const { responses } = await rows(session.id);
    expect(responses.filter((r) => r.answer.ok).map((r) => [r.participantId, r.answer.pair])).toEqual([
      ['student-0001', 1],
      ['student-0002', 1],
    ]);
    expect(responses.filter((r) => !r.answer.ok).map((r) => [r.round, r.answer.x, r.answer.y])).toEqual([
      [100, 0, 2],
      [100 + 1, 0, 2],
    ]);
  });

  it('a retry of the same try gets the same answer', async () => {
    const { session, token } = await game();
    await start(session.id);
    const [a, b] = idsOf(session.settings.order!, 0);
    const submissionId = id('sub');
    await play(token, { a, b }, 'student-0001', submissionId);
    expect(await (await play(token, { a, b }, 'student-0001', submissionId)).json()).toEqual({ ok: true, duplicate: true, match: true });
  });

  it('refuses forged submissions: a claimed match, bad ids, or one card twice', async () => {
    const { session, token } = await game();
    await start(session.id);
    // The old format, where the device said it had found a pair, is no longer believed.
    expect((await play(token, { ok: true, pair: 0 })).status).toBe(400);
    expect((await play(token, { ok: true, pair: 0, a: 0, b: 0 })).status).toBe(400);
    expect((await play(token, { a: 0, b: 6 })).status).toBe(400); // only 6 cards
    expect((await play(token, { a: 0, b: 99 })).status).toBe(400);
    expect((await play(token, { a: -1, b: 1 })).status).toBe(400);
    expect((await play(token, { a: 0.5, b: 1 })).status).toBe(400);
    expect((await play(token, { a: '0', b: '1' })).status).toBe(400);
    expect((await play(token, { a: 2, b: 2 })).status).toBe(400);
    expect((await rows(session.id)).responses).toHaveLength(0);
    // Every wrong pair of ids is stored as a mistake, never as a found pair.
    const order = session.settings.order!;
    const [a] = idsOf(order, 0);
    const [b] = idsOf(order, 1);
    await play(token, { ok: true, pair: 0, a, b });
    expect((await rows(session.id)).responses.map((r) => r.answer.ok)).toEqual([false]);
  });

  it('offline mode sends the deck, and the server still checks every pair', async () => {
    const { session, token } = await game({ answers: 'offline' });
    expect(session.settings.order).toBeUndefined();
    const joined = (await (await student('join', { token })).json()) as { settings: { pairs: unknown[] } };
    expect(joined.settings.pairs).toHaveLength(3);
    await start(session.id);
    // Offline the ids are pair * 2 + side, which the device knows.
    expect(await (await play(token, { a: 4, b: 5 })).json()).toMatchObject({ match: true });
    expect(await (await play(token, { a: 0, b: 3 })).json()).toMatchObject({ match: false });
    expect((await rows(session.id)).responses.map((r) => r.answer.ok).sort()).toEqual([false, true]);
  });

  it('a deck from before the choice keeps working offline', async () => {
    const { session, token } = await game({ answers: 'offline' });
    await env.DB.prepare("UPDATE sessions SET settings = json_remove(settings, '$.answers') WHERE id = ?").bind(session.id).run();
    const joined = (await (await student('join', { token })).json()) as { settings: { pairs: unknown[] } };
    expect(joined.settings.pairs).toHaveLength(3);
    await start(session.id);
    expect(await (await play(token, { a: 0, b: 1 })).json()).toMatchObject({ match: true });
  });

  it('serves a card picture under its id, and nothing else', async () => {
    const { session } = await game();
    const order = session.settings.order!;
    const files = pairs.flatMap((p) => [p.a, p.b]);
    for (let i = 0; i < order.length; i++) {
      const res = await call('GET', `card-image/${session.id}/${i}`, undefined, {});
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(`picture of /cards/${files[order[i]]}`);
    }
    expect((await call('GET', `card-image/${session.id}/6`, undefined, {})).status).toBe(404);
    expect((await call('GET', `card-image/${session.id}/x`, undefined, {})).status).toBe(404);
    expect((await call('GET', `card-image/nope/0`, undefined, {})).status).toBe(404);
    const offline = await game({ answers: 'offline' });
    expect((await call('GET', `card-image/${offline.session.id}/0`, undefined, {})).status).toBe(404);
  });

  it('stops at the end of the time, and a reset starts over', async () => {
    const { session, token } = await game();
    await start(session.id);
    await env.DB.prepare("UPDATE sessions SET settings = json_set(settings, '$.endsAt', unixepoch() - 60) WHERE id = ?").bind(session.id).run();
    expect(await (await play(token, { a: 0, b: 1 })).json()).toEqual({ error: 'time_up' });
    await call('DELETE', `sessions/${session.id}/responses`);
    expect(await (await play(token, { a: 0, b: 1 })).json()).toEqual({ error: 'not_started' });
    // The deck survives a reset.
    const joined = (await (await student('join', { token })).json()) as { settings: { cards: unknown[] } };
    expect(joined.settings.cards).toHaveLength(6);
  });

  it('rejects a bad deck', async () => {
    const bad = async (cards: unknown) => (await call('POST', 'sessions', { name: 'x', game: 'cards', cards })).status;
    expect(await bad(undefined)).toBe(400);
    expect(await bad({ pairs: [] })).toBe(400);
    expect(await bad({ pairs: pairs.slice(0, 1) })).toBe(400);
    expect(await bad({ pairs: Array(13).fill(pairs[0]) })).toBe(400);
    expect(await bad({ pairs: [{ ...pairs[0], a: '../a.jpg' }, pairs[1]] })).toBe(400);
    expect(await bad({ pairs: [{ ...pairs[0], b: 'a-1.jpg' }, pairs[1]] })).toBe(400);
    expect(await bad({ pairs: [{ ...pairs[0], ra: 360 }, pairs[1]] })).toBe(400);
    expect(await bad({ pairs: [{ ...pairs[0], ra: 1.5 }, pairs[1]] })).toBe(400);
    expect(await bad({ pairs, rotation: 'spin' })).toBe(400);
    expect(await bad(deck)).toBe(201);
  });

  it('has a timer for this game, like mapping', async () => {
    const { session } = await game();
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 60 })).status).toBe(200);
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 4000 })).status).toBe(400);
  });

  it('keeps the deck, its hidden order and every try through a backup', async () => {
    const { session, token } = await game();
    await start(session.id);
    const order = session.settings.order!;
    const [a, b] = idsOf(order, 2);
    await play(token, { a, b });
    await play(token, { a: idsOf(order, 0)[0], b: idsOf(order, 1)[0] });
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { sessions: { settings: Record<string, unknown> }[] };
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await rows(session.id)).responses.map((r) => r.round)).toEqual([2, 100]);
    const restored = async () =>
      ((await (await call('GET', `sessions/${session.id}/responses`)).json()) as { session: { settings: { pairs: unknown[]; order: number[]; answers?: string } } })
        .session.settings;
    expect((await restored()).pairs).toHaveLength(3);
    expect((await restored()).order).toEqual(order);

    // A broken order gets a new one rather than a deck nobody can play.
    file.sessions[0].settings.order = [0, 0, 1, 2, 3, 4];
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect([...(await restored()).order].sort()).toEqual([0, 1, 2, 3, 4, 5]);

    // A backup from before the mode existed comes back offline, as it was played.
    delete file.sessions[0].settings.answers;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await restored()).answers).toBeUndefined();
  });
});

describe('coordinates game', () => {
  const tasks = [
    { lat: 41.7, lon: 44.8, mode: 'to_map', format: 'dd', label: 'თბილისი' },
    { lat: 42.27, lon: 42.7, mode: 'read', format: 'utm', label: '' },
  ];
  const coordAnswer = { raw: '41.7, 44.8', format: 'dd', mode: 'to_map' };

  async function game() {
    const res = await call('POST', 'sessions', { name: 'Coords', game: 'coordinates', tasks });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string }; token: string };
  }

  const play = (token: string, over: Record<string, unknown> = {}) =>
    send(token, { answer: coordAnswer, lat: 41.7, lon: 44.8, round: 0, ...over });

  it('accepts every coordinate format', async () => {
    const formats = ['dd', 'dm', 'dms', 'utm'].map((format) => ({ ...tasks[0], format }));
    const res = await call('POST', 'sessions', { name: 'Formats', game: 'coordinates', tasks: formats });
    expect(res.status).toBe(201);
  });

  async function rows(sessionId: string) {
    return (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as {
      responses: { round: number; score: number; distanceM: number; lat: number }[];
    };
  }

  it('rejects a game without valid tasks', async () => {
    expect((await call('POST', 'sessions', { name: 'x', game: 'coordinates' })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: 'x', game: 'coordinates', tasks: [] })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: 'x', game: 'coordinates', tasks: [{ ...tasks[0], lat: 99 }] })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: 'x', game: 'coordinates', tasks: [{ ...tasks[0], mode: 'x' }] })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: 'x', game: 'coordinates', tasks: Array(31).fill(tasks[0]) })).status).toBe(400);
  });

  it('gives the tasks to the student on join', async () => {
    const { token } = await game();
    const data = (await (await student('join', { token })).json()) as { game: string; settings: { tasks: unknown[] } };
    expect(data.game).toBe('coordinates');
    expect(data.settings.tasks).toHaveLength(2);
  });

  it('scores on the server, ignoring any score sent by the client', async () => {
    const { session, token } = await game();
    expect((await play(token, { score: 1, distanceM: 999999 })).status).toBe(201);
    const [row] = (await rows(session.id)).responses;
    expect(row.score).toBe(100);
    expect(row.distanceM).toBeLessThan(1);
  });

  it('gives lower scores further away', async () => {
    const { session, token } = await game();
    await play(token, { lat: 41.79, lon: 44.8 }); // about 10 km
    await play(token, { lat: 43, lon: 44.8 }); // about 145 km
    const scores = (await rows(session.id)).responses.map((r) => r.score).sort((a, b) => b - a);
    expect(scores[0]).toBe(50);
    expect(scores[1]).toBe(0);
  });

  it('counts the first try for a task, and each task separately', async () => {
    const { session, token } = await game();
    const participantId = 'same-participant-3';
    await play(token, { participantId, lat: 43 });
    await play(token, { participantId, lat: 41.7 });
    await play(token, { participantId, round: 1, lat: 42.27, lon: 42.7 });
    const { responses: all } = await rows(session.id);
    expect(all).toHaveLength(2);
    expect(all.find((r) => r.round === 0)!.score).toBe(0);
    expect(all.find((r) => r.round === 1)!.score).toBe(100);
  });

  it('rejects a task that does not exist', async () => {
    const { token } = await game();
    expect((await play(token, { round: 2 })).status).toBe(400);
    expect((await play(token, { round: -1 })).status).toBe(400);
    expect((await play(token, { round: 'x' })).status).toBe(400);
    expect((await play(token, { round: undefined })).status).toBe(400);
  });

  it('rejects a bad answer format', async () => {
    const { token } = await game();
    expect((await play(token, { answer: { ...coordAnswer, format: 'x' } })).status).toBe(400);
    expect((await play(token, { answer: { ...coordAnswer, raw: 'x'.repeat(61) } })).status).toBe(400);
  });

  it('restores tasks and works scores out again', async () => {
    const { session, token } = await game();
    await play(token);
    const file = (await (await call('GET', 'backup')).json()) as { responses: { score: number; lat: number }[] };
    expect(file.responses[0].score).toBe(100);
    await call('DELETE', `sessions/${session.id}`);
    file.responses[0].score = 12345;
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const [row] = (await rows(session.id)).responses;
    expect(row.score).toBe(100);
    const after = (await (await call('GET', 'sessions')).json()) as { sessions: { settings: { tasks: unknown[] } }[] };
    expect(after.sessions[0].settings.tasks).toHaveLength(2);
  });

  it('refuses a backup whose answer points to a missing task', async () => {
    const { session, token } = await game();
    await play(token);
    const file = (await (await call('GET', 'backup')).json()) as { responses: { round: number }[] };
    await call('DELETE', `sessions/${session.id}`);
    file.responses[0].round = 9;
    expect((await call('POST', 'restore', file)).status).toBe(400);
  });

  it('still restores a first-version backup', async () => {
    const res = await call('POST', 'restore', {
      format: 'geoclass-backup',
      version: 1,
      sessions: [{ id: 'old-session-1', name: 'Old', game: 'travel', archived: false, createdAt: 1790000000 }],
      responses: [
        { id: 'old-response-1', sessionId: 'old-session-1', participantId: 'old-participant', answer, lat: 1, lon: 2, hidden: false, createdAt: 1790000000 },
      ],
    });
    expect(res.status).toBe(200);
    expect((await responses('old-session-1')).responses).toHaveLength(1);
  });
});

describe('aerial game', () => {
  const tasks = [
    { lat: 41.7, lon: 44.8, photo: 'p01.jpg', label: 'თბილისი', labelEn: 'Tbilisi', mode: 'ignored', format: 'ignored' },
    { lat: 42.27, lon: 42.7, photo: 'p02.webp', label: 'ქუთაისი', labelEn: 'Kutaisi' },
  ];

  async function game() {
    const res = await call('POST', 'sessions', { name: 'Photos', game: 'aerial', tasks });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: { tasks: Record<string, unknown>[] } }; token: string };
  }

  const play = (token: string, over: Record<string, unknown> = {}) =>
    send(token, { participantId: 'aerial-player-0001', answer: { junk: 'x' }, lat: 41.79, lon: 44.8, round: 0, ...over });

  it('stores tasks in one fixed shape', async () => {
    const { session } = await game();
    expect(session.settings.tasks[0]).toEqual({ lat: 41.7, lon: 44.8, mode: 'photo', format: 'dd', label: 'თბილისი', labelEn: 'Tbilisi', photo: 'p01.jpg' });
  });

  it('refuses a photo that is not a plain file name', async () => {
    for (const photo of [undefined, '', '../secret.jpg', 'a/b.jpg', 'https://example.com/a.jpg', 'a.svg', 'a b.jpg']) {
      const res = await call('POST', 'sessions', { name: 'x', game: 'aerial', tasks: [{ ...tasks[1], photo }] });
      expect(res.status, String(photo)).toBe(400);
    }
  });

  it('scores on the server and keeps only the first try', async () => {
    const { session, token } = await game();
    expect((await play(token)).status).toBe(201);
    await play(token, { lat: 41.7 });
    const { responses: rows } = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as {
      responses: { score: number; answer: unknown }[];
    };
    expect(rows).toHaveLength(1);
    expect(rows[0].score).toBe(50);
    expect(rows[0].answer).toEqual({});
  });

  it('refuses a round outside the task list', async () => {
    const { token } = await game();
    expect((await play(token, { round: 2 })).status).toBe(400);
  });

  it('survives backup and restore', async () => {
    const { session, token } = await game();
    await play(token);
    const backup = (await (await call('GET', `backup?session=${session.id}`)).json()) as { sessions: { id: string }[] };
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', backup)).status).toBe(200);
    const restored = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as {
      session: { settings: { tasks: { photo: string }[] } };
      responses: { score: number }[];
    };
    expect(restored.session.settings.tasks[1].photo).toBe('p02.webp');
    expect(restored.responses[0].score).toBe(50);
  });
});

describe('evidence game', () => {
  const tasks = [
    { kind: 'receipt', lat: 41.6938, lon: 44.8015, shown: 'dms', ask: 'dd', questions: ['coords', 'map', 'name'], names: ['თავისუფლების მოედანი', 'Freedom Square'], converter: true, seed: 7 },
    { kind: 'dashcam', lat: 42.2679, lon: 42.7181, shown: 'utm', ask: 'dm', questions: ['map'], names: [], converter: false, seed: 99 },
  ];
  const game = async () => {
    const res = await call('POST', 'sessions', { name: 'IX b', game: 'evidence', tasks });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string }; token: string };
  };
  const participant = 'par-evidence-1';
  const play = (token: string, round: number, answer: Record<string, unknown>, lat = 0, lon = 0) =>
    student('submit', { token, submissionId: id('sub'), participantId: participant, round, answer, lat, lon });
  type Row = { id: string; round: number; score: number; distanceM: number | null; accepted: boolean };
  const rows = async (sessionId: string) => (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as { responses: Row[] };

  it('keeps the tasks in one shape and refuses bad ones', async () => {
    await game();
    const list = (await (await call('GET', 'sessions')).json()) as { sessions: { settings: { tasks: { questions: string[]; converter: boolean }[] } }[] };
    expect(list.sessions[0].settings.tasks[1].questions).toEqual(['map']);
    expect(list.sessions[0].settings.tasks[1].converter).toBe(false);
    const bad = [
      { ...tasks[0], kind: 'passport' },
      { ...tasks[0], shown: 'mgrs' },
      { ...tasks[0], questions: [] },
      { ...tasks[0], questions: ['coords', 'oops'] },
      { ...tasks[0], names: [] }, // asks for the name without accepting any
      { ...tasks[0], seed: -1 },
      { ...tasks[0], lat: 95 },
    ];
    for (const t of bad) {
      expect((await call('POST', 'sessions', { name: 'x', game: 'evidence', tasks: [t] })).status).toBe(400);
    }
  });

  it('scores typed coordinates strictly and a map tap like the coordinates game', async () => {
    const { session, token } = await game();
    expect((await play(token, 0, { q: 'coords', raw: '41.69380, 44.80150', format: 'dd' }, 41.6938, 44.8015)).status).toBe(201);
    // About 1 km off: a full score on the map, very little for typed coordinates.
    expect((await play(token, 0, { q: 'map' }, 41.7028, 44.8015)).status).toBe(201);
    const second = await student('submit', { token, submissionId: id('sub'), participantId: 'par-evidence-2', round: 0, answer: { q: 'coords', raw: 'x', format: 'dd' }, lat: 41.7028, lon: 44.8015 });
    expect(second.status).toBe(201);
    const list = (await rows(session.id)).responses;
    const byRound = (r: number) => list.filter((x) => x.round === r);
    expect(byRound(0).map((r) => r.score).sort((a, b) => b - a)).toEqual([100, 31]);
    expect(byRound(1)[0].score).toBe(100);
  });

  it('matches the name loosely and keeps only the first answer', async () => {
    const { session, token } = await game();
    const res = await play(token, 0, { q: 'name', name: '  თავისუფლების  მოედანი! ' });
    expect(res.status).toBe(201);
    expect(((await res.json()) as { score: number }).score).toBe(100);
    const again = await play(token, 0, { q: 'name', name: 'something else' });
    expect(again.status).toBe(200);
    const [row] = (await rows(session.id)).responses;
    expect(row.round).toBe(2);
    expect(row.score).toBe(100);
    expect(row.distanceM).toBeNull();
    const other = await student('submit', { token, submissionId: id('sub'), participantId: 'par-evidence-3', round: 0, answer: { q: 'name', name: 'freedom-square' }, lat: 0, lon: 0 });
    expect(((await other.json()) as { score: number }).score).toBe(100);
  });

  it('refuses a question the task does not ask, or a missing task', async () => {
    const { token } = await game();
    expect((await play(token, 1, { q: 'name', name: 'Kutaisi' })).status).toBe(400);
    expect((await play(token, 5, { q: 'map' }, 41, 44)).status).toBe(400);
    expect((await play(token, 0, { q: 'coords', raw: '', format: 'dd' }, 41, 44)).status).toBe(400);
    expect((await play(token, 0, { q: 'coords', raw: '41 44', format: 'mgrs' }, 41, 44)).status).toBe(400);
  });

  it('lets the teacher count an answer as right, and take it back', async () => {
    const { session, token } = await game();
    await play(token, 0, { q: 'name', name: 'Freedom Sqare' });
    const [row] = (await rows(session.id)).responses;
    expect(row.score).toBe(0);
    expect(row.accepted).toBe(false);
    expect((await call('PATCH', `responses/${row.id}`, { accepted: true })).status).toBe(200);
    expect((await rows(session.id)).responses[0].accepted).toBe(true);
    expect((await rows(session.id)).responses[0].score).toBe(0); // the real score stays, for undoing
    expect((await call('PATCH', `responses/${row.id}`, { accepted: false })).status).toBe(200);
    expect((await rows(session.id)).responses[0].accepted).toBe(false);
    expect((await call('PATCH', `responses/${row.id}`, { accepted: 'yes' })).status).toBe(400);
    expect((await call('PATCH', `responses/${row.id}`, { accepted: true }, {})).status).toBe(401);
  });

  it('marks answers as accepted only in this game', async () => {
    const { token } = await newSession();
    await send(token);
    const list = (await (await call('GET', 'sessions')).json()) as { sessions: { id: string }[] };
    const [row] = (await responses(list.sessions[0].id)).responses;
    expect((await call('PATCH', `responses/${row.id}`, { accepted: true })).status).toBe(400);
  });

  it('keeps tasks, answers and the teacher marks through a backup, scoring again', async () => {
    const { session, token } = await game();
    await play(token, 0, { q: 'name', name: 'Freedom Sqare' });
    await play(token, 1, { q: 'map' }, 42.2679, 42.7181);
    const [first] = (await rows(session.id)).responses;
    await call('PATCH', `responses/${first.id}`, { accepted: true });
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { score: number; round: number }[] };
    await call('DELETE', `sessions/${session.id}`);
    file.responses[0].score = 100;
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const after = (await rows(session.id)).responses;
    expect(after.map((r) => [r.round, r.score, r.accepted])).toEqual([
      [2, 0, true],
      [4, 100, false],
    ]);
  });

  it('refuses a backup whose round and answer disagree', async () => {
    const { session, token } = await game();
    await play(token, 0, { q: 'name', name: 'x' });
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { round: number }[] };
    await call('DELETE', `sessions/${session.id}`);
    file.responses[0].round = 1;
    expect((await call('POST', 'restore', file)).status).toBe(400);
  });
});

describe('protected answers', () => {
  const aerial = [
    { lat: 41.7, lon: 44.8, photo: 'p01.jpg', label: 'თბილისი', labelEn: 'Tbilisi' },
    { lat: 42.27, lon: 42.7, photo: 'p02.webp', label: 'ქუთაისი', labelEn: 'Kutaisi' },
  ];
  const evidence = [
    { kind: 'receipt', lat: 41.6938, lon: 44.8015, shown: 'dms', ask: 'dd', questions: ['coords', 'map', 'name'], names: ['თავისუფლების მოედანი', 'Freedom Square'], converter: true, seed: 7 },
  ];
  const create = async (game: string, tasks: unknown, answers?: string) => {
    const res = await call('POST', 'sessions', { name: 'x', game, tasks, ...(answers ? { answers } : {}) });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: Record<string, unknown> }; token: string };
  };
  const join = async (token: string) => {
    const res = await student('join', { token });
    expect(res.status).toBe(200);
    const text = await res.text();
    return { text, data: JSON.parse(text) as { settings: { answers?: string; tasks: Record<string, unknown>[] } } };
  };
  // A session made before the answer mode existed.
  const makeLegacy = (id: string) => env.DB.prepare("UPDATE sessions SET settings = json_remove(settings, '$.answers') WHERE id = ?").bind(id).run();

  it('online is the default and the teacher still sees everything', async () => {
    const { session } = await create('aerial', aerial);
    expect(session.settings.answers).toBe('online');
    expect((session.settings.tasks as Record<string, unknown>[])[0].label).toBe('თბილისი');
    expect((await create('evidence', evidence)).session.settings.answers).toBe('online');
  });

  it('refuses an unknown answer mode', async () => {
    expect((await call('POST', 'sessions', { name: 'x', game: 'aerial', tasks: aerial, answers: 'maybe' })).status).toBe(400);
  });

  it('aerial online: the join response has no point and no place name', async () => {
    const { token } = await create('aerial', aerial);
    const { text, data } = await join(token);
    expect(data.settings.tasks).toEqual([
      { mode: 'photo', format: 'dd', photo: 'p01.jpg' },
      { mode: 'photo', format: 'dd', photo: 'p02.webp' },
    ]);
    for (const secret of ['თბილისი', 'Tbilisi', 'ქუთაისი', 'Kutaisi', '41.7', '44.8', '42.27', '42.7']) expect(text).not.toContain(secret);
  });

  it('evidence online: the join response has no accepted names', async () => {
    const { token } = await create('evidence', evidence);
    const { text, data } = await join(token);
    expect(data.settings.tasks[0]).not.toHaveProperty('names');
    expect(data.settings.tasks[0]).toMatchObject({ kind: 'receipt', lat: 41.6938, lon: 44.8015, questions: ['coords', 'map', 'name'], seed: 7 });
    for (const secret of ['თავისუფლების', 'Freedom']) expect(text).not.toContain(secret);
  });

  it('offline mode, chosen by the teacher, sends the answers for scoring on the device', async () => {
    const a = await join((await create('aerial', aerial, 'offline')).token);
    expect(a.data.settings.tasks[0]).toMatchObject({ lat: 41.7, lon: 44.8, label: 'თბილისი' });
    const e = await join((await create('evidence', evidence, 'offline')).token);
    expect(e.data.settings.tasks[0].names).toEqual(['თავისუფლების მოედანი', 'Freedom Square']);
  });

  it('a session from before the choice keeps working as it did', async () => {
    for (const [game, tasks] of [['aerial', aerial], ['evidence', evidence]] as const) {
      const { session, token } = await create(game, tasks);
      await makeLegacy(session.id);
      const { data } = await join(token);
      expect(data.settings.answers).toBeUndefined();
      expect(data.settings.tasks[0]).toHaveProperty(game === 'aerial' ? 'label' : 'names');
    }
  });

  it('aerial: the result comes from the server, and only the first try counts', async () => {
    const { token } = await create('aerial', aerial);
    const submissionId = id('sub');
    const body = { token, submissionId, participantId: 'protected-0001', round: 0, answer: {}, lat: 41.79, lon: 44.8 };
    const res = await student('submit', body);
    expect(res.status).toBe(201);
    const first = (await res.json()) as { score: number; distanceM: number; target: Record<string, unknown> };
    expect(first.score).toBe(50);
    expect(Math.round(first.distanceM / 100)).toBe(100);
    expect(first.target).toEqual({ lat: 41.7, lon: 44.8, label: 'თბილისი', labelEn: 'Tbilisi' });
    // A retry of the same answer, after a lost connection, gets the same result.
    const retry = (await (await student('submit', body)).json()) as { duplicate: boolean; score: number };
    expect(retry).toMatchObject({ duplicate: true, score: 50 });
    // A better second try is not counted, and the reply says so.
    const second = (await (await student('submit', { ...body, submissionId: id('sub'), lat: 41.7 })).json()) as { duplicate: boolean; score: number };
    expect(second).toMatchObject({ duplicate: true, score: 50 });
  });

  it('evidence: trying other names after a wrong one does not tell which is right', async () => {
    const { token } = await create('evidence', evidence);
    const body = { token, participantId: 'protected-0002', round: 0, lat: 0, lon: 0 };
    const wrong = (await (await student('submit', { ...body, submissionId: id('sub'), answer: { q: 'name', name: 'Rustaveli' } })).json()) as Record<string, unknown>;
    expect(wrong).toMatchObject({ score: 0, right: 'თავისუფლების მოედანი' });
    const again = (await (await student('submit', { ...body, submissionId: id('sub'), answer: { q: 'name', name: 'Freedom Square' } })).json()) as Record<string, unknown>;
    expect(again).toMatchObject({ duplicate: true, score: 0 });
    const map = (await (await student('submit', { ...body, submissionId: id('sub'), answer: { q: 'map' }, lat: 41.6938, lon: 44.8015 })).json()) as Record<string, unknown>;
    expect(map).toMatchObject({ score: 100 });
    expect(map).not.toHaveProperty('right');
  });

  it('backup and restore keep the answer mode; an old backup stays offline', async () => {
    const { session } = await create('aerial', aerial);
    const mode = async () =>
      ((await (await call('GET', `sessions/${session.id}/responses`)).json()) as { session: { settings: { answers?: string } } }).session.settings.answers;
    const backup = (await (await call('GET', `backup?session=${session.id}`)).json()) as { sessions: { settings: Record<string, unknown> }[] };
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', backup)).status).toBe(200);
    expect(await mode()).toBe('online');

    delete backup.sessions[0].settings.answers;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', backup)).status).toBe(200);
    expect(await mode()).toBeUndefined();
  });

  it('other games are not changed', async () => {
    const { token } = await create('coordinates', [{ lat: 41.7, lon: 44.8, mode: 'to_map', format: 'dd', label: 'x' }]);
    const { data } = await join(token);
    expect(data.settings.answers).toBeUndefined();
    expect(data.settings.tasks[0]).toMatchObject({ lat: 41.7, lon: 44.8 });
  });
});

describe('paths outside the API', () => {
  it('answer 404 without asking for a key', async () => {
    expect((await call('GET', '../aerial/missing.jpg', undefined, {})).status).toBe(404);
  });
});

describe('plates game', () => {
  const deck = [
    { shape: 'georgia', palette: 'red_green', seed: 1 },
    { shape: 'ge_m_gori', palette: 'pink_violet', seed: 2 },
    { shape: 'italy', palette: 'blue_violet', seed: 3 },
  ];

  async function game() {
    const res = await call('POST', 'sessions', { name: 'Plates', game: 'plates', plates: { deck } });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string; settings: { at: number } }; token: string };
  }

  type Joined = { settings: { plate: { shape: string } | null; at: number; count: number; revealed: boolean; deck?: unknown } };
  const join = async (token: string) => (await (await student('join', { token })).json()) as Joined;
  const show = (sessionId: string, at: unknown, revealed: unknown) => call('POST', `sessions/${sessionId}/plate`, { at, revealed });

  it('checks the deck', async () => {
    for (const plates of [{ deck: [] }, { deck: [{ shape: 'Bad Name', palette: 'red_green', seed: 1 }] }, { deck: [{ shape: 'x', palette: 'gold', seed: 1 }] }, {}]) {
      expect((await call('POST', 'sessions', { name: 'P', game: 'plates', plates })).status).toBe(400);
    }
  });

  it('shows students only the plate on screen, and follows the teacher', async () => {
    const { session, token } = await game();
    let seen = await join(token);
    expect(seen.settings).toEqual({ plate: deck[0], at: 0, count: 3, revealed: false });
    expect(seen.settings.deck).toBeUndefined();

    expect((await show(session.id, 1, true)).status).toBe(200);
    seen = await join(token);
    expect(seen.settings).toEqual({ plate: deck[1], at: 1, count: 3, revealed: true });

    // Past the last plate: the end, never revealed.
    expect((await show(session.id, 3, true)).status).toBe(200);
    seen = await join(token);
    expect(seen.settings).toEqual({ plate: null, at: 3, count: 3, revealed: false });

    for (const [at, revealed] of [[4, false], [-1, false], [1.5, false], [1, 'yes']]) {
      expect((await show(session.id, at, revealed)).status).toBe(400);
    }
    expect((await call('POST', `sessions/${session.id}/plate`, { at: 0, revealed: false }, {})).status).toBe(401);
  });

  it('takes no answers', async () => {
    const { token } = await game();
    const res = await student('submit', { token, submissionId: id('sub'), participantId: id('par'), answer: {}, lat: 0, lon: 0 });
    expect(res.status).toBe(400);
  });

  it('moves plates only in this game', async () => {
    const { session } = await newSession();
    expect((await show(session.id, 0, false)).status).toBe(400);
  });

  it('keeps the deck through a backup and starts again', async () => {
    const { session } = await game();
    await show(session.id, 2, true);
    const file = await (await call('GET', `backup?session=${session.id}`)).json();
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const restored = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as {
      session: { settings: { deck: unknown[]; at: number; revealed: boolean } };
    };
    expect(restored.session.settings).toEqual({ deck, at: 0, revealed: false });
  });
});

describe('privacy', () => {
  it('a student deletes only their own answers, and only with the session token', async () => {
    const { session, token } = await newSession();
    await send(token, { participantId: 'student-mine-0001' });
    await send(token, { participantId: 'student-else-0001' });
    expect((await student('forget', { token: 'wrong', participantId: 'student-mine-0001' })).status).toBe(404);
    expect((await student('forget', { token, participantId: 'x' })).status).toBe(400);

    const before = (await responses(session.id)).session.rev;
    const res = await student('forget', { token, participantId: 'student-mine-0001' });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ deleted: 1 });
    const after = await responses(session.id);
    expect(after.responses).toHaveLength(1);
    expect(after.session.rev).toBeGreaterThan(before);
    expect(await (await student('forget', { token, participantId: 'student-mine-0001' })).json()).toEqual({ deleted: 0 });
  });

  it('deletes sessions and their answers six months after they were made', async () => {
    const { deleteOld, KEEP_SEC } = await import('../src/retention');
    const old = await newSession();
    const fresh = await newSession();
    await send(old.token);
    await send(fresh.token);
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare('UPDATE sessions SET created_at = ? WHERE id = ?').bind(now - KEEP_SEC - 60, old.session.id).run();

    expect(await deleteOld(env)).toBe(1);
    const left = await env.DB.prepare('SELECT session_id FROM responses').all<{ session_id: string }>();
    expect(left.results.map((r) => r.session_id)).toEqual([fresh.session.id]);
    expect((await call('GET', `sessions/${old.session.id}/responses`)).status).toBe(404);
    expect(await deleteOld(env)).toBe(0);
  });
});

describe('teacher accounts', () => {
  async function newTeacher(name = 'Nino', amount = 30, unit = 'day') {
    const res = await call('POST', 'teachers', { name, amount, unit });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { teacher: { id: string; expiresAt: number; active: boolean }; key: string };
    return { ...body, auth: { Authorization: `Bearer ${body.key}` } };
  }
  const as = (headers: Record<string, string>) => ({
    get: (path: string) => call('GET', path, undefined, headers),
    post: (path: string, body?: unknown) => call('POST', path, body ?? {}, headers),
    patch: (path: string, body: unknown) => call('PATCH', path, body, headers),
    del: (path: string) => call('DELETE', path, undefined, headers),
  });

  it('the owner makes a teacher with a validity in days, months or years; the key works and says who it is', async () => {
    const now = Math.floor(Date.now() / 1000);
    const { teacher, key, auth: tAuth } = await newTeacher('Nino', 30, 'day');
    expect(key).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(teacher.active).toBe(true);
    expect(Math.abs(teacher.expiresAt - (now + 30 * 86400))).toBeLessThan(5);
    const me = await (await call('GET', 'me', undefined, tAuth)).json();
    expect(me).toEqual({ ok: true, role: 'teacher', name: 'Nino', expiresAt: teacher.expiresAt });
    expect(await (await call('GET', 'me')).json()).toEqual({ ok: true, role: 'owner', name: null, expiresAt: null });

    const month = (await newTeacher('Month', 1, 'month')).teacher.expiresAt - now;
    expect(month).toBeGreaterThanOrEqual(28 * 86400);
    expect(month).toBeLessThanOrEqual(31 * 86400 + 5);
    const year = (await newTeacher('Year', 2, 'year')).teacher.expiresAt - now;
    expect(year).toBeGreaterThanOrEqual(730 * 86400);
    // Only the hash is stored.
    const stored = await env.DB.prepare('SELECT key_hash FROM teachers WHERE name = ?').bind('Nino').first<{ key_hash: string }>();
    expect(stored?.key_hash).not.toBe(key);
    expect(stored?.key_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('refuses a bad validity', async () => {
    for (const body of [
      { name: 'X', amount: 0, unit: 'day' },
      { name: 'X', amount: 1.5, unit: 'day' },
      { name: 'X', amount: 2, unit: 'week' },
      { name: 'X', amount: 6, unit: 'year' },
      { name: 'X' },
      { name: '', amount: 1, unit: 'day' },
    ]) {
      expect((await call('POST', 'teachers', body)).status).toBe(400);
    }
  });

  it('only the owner manages teachers', async () => {
    const { teacher, auth: tAuth } = await newTeacher();
    expect((await as(tAuth).get('teachers')).status).toBe(403);
    expect((await as(tAuth).post('teachers', { name: 'Y', amount: 1, unit: 'day' })).status).toBe(403);
    expect((await as(tAuth).patch(`teachers/${teacher.id}`, { amount: 5, unit: 'year' })).status).toBe(403);
    const list = (await (await call('GET', 'teachers')).json()) as { teachers: { id: string; name: string; sessions: number }[] };
    expect(list.teachers).toEqual([expect.objectContaining({ id: teacher.id, name: 'Nino', sessions: 0 })]);
  });

  it("a teacher sees and changes only their own sessions; the owner sees all, with the teacher's name", async () => {
    const { auth: tAuth } = await newTeacher();
    const t = as(tAuth);
    const owners = await newSession();
    const mineRes = await t.post('sessions', { name: 'VII b', game: 'travel' });
    expect(mineRes.status).toBe(201);
    const mine = (await mineRes.json()) as { session: { id: string; teacherId: string } };
    expect(mine.session.teacherId).toBeTruthy();

    const seen = (await (await t.get('sessions')).json()) as { sessions: { id: string; teacherName?: string }[] };
    expect(seen.sessions.map((s) => s.id)).toEqual([mine.session.id]);
    expect(seen.sessions[0].teacherName).toBeUndefined();
    const all = (await (await call('GET', 'sessions')).json()) as { sessions: { id: string; teacherName?: string }[] };
    expect(all.sessions.map((s) => s.id).sort()).toEqual([owners.session.id, mine.session.id].sort());
    expect(all.sessions.find((s) => s.id === mine.session.id)?.teacherName).toBe('Nino');
    expect(all.sessions.find((s) => s.id === owners.session.id)?.teacherName).toBeUndefined();

    const other = owners.session.id;
    expect((await t.get(`sessions/${other}/responses`)).status).toBe(404);
    expect((await t.patch(`sessions/${other}`, { status: 'paused' })).status).toBe(404);
    expect((await t.post(`sessions/${other}/token`)).status).toBe(404);
    expect((await t.del(`sessions/${other}/responses`)).status).toBe(404);
    expect((await t.del(`sessions/${other}`)).status).toBe(404);
    expect((await responses(other)).session.status).toBe('open');

    expect((await t.get(`sessions/${mine.session.id}/responses`)).status).toBe(200);
    expect((await t.patch(`sessions/${mine.session.id}`, { status: 'paused' })).status).toBe(200);
    expect((await t.post(`sessions/${mine.session.id}/token`)).status).toBe(200);
    // The owner can work in a teacher's session too.
    expect((await call('PATCH', `sessions/${mine.session.id}`, { status: 'open' })).status).toBe(200);
  });

  it("a teacher can't hide or delete an answer in someone else's session", async () => {
    const { auth: tAuth } = await newTeacher();
    const { session, token } = await newSession();
    expect((await send(token)).status).toBe(201);
    const [r] = (await responses(session.id)).responses;
    expect((await as(tAuth).patch(`responses/${r.id}`, { hidden: true })).status).toBe(404);
    expect((await as(tAuth).del(`responses/${r.id}`)).status).toBe(404);
    expect((await responses(session.id)).responses).toEqual([expect.objectContaining({ id: r.id, hidden: false })]);
  });

  it("backs up only the teacher's own sessions, and restores them as theirs", async () => {
    const { teacher, auth: tAuth } = await newTeacher();
    const t = as(tAuth);
    const owners = await newSession();
    expect((await send(owners.token)).status).toBe(201);
    const mine = (await (await t.post('sessions', { name: 'VII b', game: 'travel' })).json()) as { session: { id: string }; token: string };
    expect((await send(mine.token)).status).toBe(201);

    const file = (await (await t.get('backup')).json()) as { sessions: { id: string; teacherId: string }[]; responses: { sessionId: string }[] };
    expect(file.sessions.map((s) => s.id)).toEqual([mine.session.id]);
    expect(file.responses.map((r) => r.sessionId)).toEqual([mine.session.id]);
    expect((await t.get(`backup?session=${owners.session.id}`)).status).toBe(404);

    expect((await t.del(`sessions/${mine.session.id}`)).status).toBe(200);
    expect((await t.post('restore', file)).status).toBe(200);
    const back = await env.DB.prepare('SELECT teacher_id FROM sessions WHERE id = ?').bind(mine.session.id).first<{ teacher_id: string }>();
    expect(back?.teacher_id).toBe(teacher.id);

    // The owner's full backup keeps who made each session.
    const full = (await (await call('GET', 'backup')).json()) as { sessions: { id: string; teacherId: string | null }[] };
    expect(full.sessions.find((s) => s.id === mine.session.id)?.teacherId).toBe(teacher.id);
    expect(full.sessions.find((s) => s.id === owners.session.id)?.teacherId).toBeNull();
    await env.DB.exec('DELETE FROM sessions');
    expect((await call('POST', 'restore', full)).status).toBe(200);
    const again = await env.DB.prepare('SELECT teacher_id FROM sessions WHERE id = ?').bind(mine.session.id).first<{ teacher_id: string }>();
    expect(again?.teacher_id).toBe(teacher.id);
  });

  it("refuses a teacher's restore that names someone else's session, and changes nothing", async () => {
    const { auth: tAuth } = await newTeacher();
    const owners = await newSession();
    const forged = {
      format: 'geoclass-backup',
      version: 2,
      sessions: [{ id: owners.session.id, name: 'X', game: 'travel', createdAt: 1 }],
      responses: [{ id: 'forged-0000-1', sessionId: owners.session.id, participantId: 'forged-0000-2', answer, lat: 1, lon: 1, createdAt: 1 }],
    };
    const res = await as(tAuth).post('restore', forged);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: 'not_yours' });
    expect((await responses(owners.session.id)).responses).toEqual([]);
  });

  it('a revoked or expired key stops working, says why, and works again when given back or extended', async () => {
    const { teacher, auth: tAuth } = await newTeacher();
    const me = () => call('GET', 'me', undefined, tAuth);
    expect((await call('PATCH', `teachers/${teacher.id}`, { revoked: true })).status).toBe(200);
    const revoked = await me();
    expect(revoked.status).toBe(401);
    expect(await revoked.json()).toEqual({ error: 'key_expired' });
    expect((await call('PATCH', `teachers/${teacher.id}`, { revoked: false })).status).toBe(200);
    expect((await me()).status).toBe(200);

    await env.DB.prepare('UPDATE teachers SET expires_at = ? WHERE id = ?').bind(Math.floor(Date.now() / 1000) - 1, teacher.id).run();
    expect((await me()).status).toBe(401);
    const extended = (await (await call('PATCH', `teachers/${teacher.id}`, { amount: 1, unit: 'year' })).json()) as { teacher: { active: boolean } };
    expect(extended.teacher.active).toBe(true);
    expect((await me()).status).toBe(200);
  });

  it('deletes teachers that ended long ago and own no session', async () => {
    const { deleteOldTeachers, KEEP_SEC } = await import('../src/retention');
    const gone = await newTeacher('Gone');
    const kept = await newTeacher('Kept');
    expect((await as(kept.auth).post('sessions', { name: 'X', game: 'travel' })).status).toBe(201);
    const later = Math.floor(Date.now() / 1000) + 31 * 86400 + KEEP_SEC + 1;
    expect(await deleteOldTeachers(env)).toBe(0);
    expect(await deleteOldTeachers(env, later)).toBe(1);
    const left = (await env.DB.prepare('SELECT name FROM teachers').all<{ name: string }>()).results.map((r) => r.name);
    expect(left).toEqual(['Kept']);
    expect(gone.teacher.id).toBeTruthy();
  });
});

describe('schema 0012 and backup version 3', () => {
  const now = () => Math.floor(Date.now() / 1000);

  async function withStudent() {
    const { session, token } = await newSession();
    await send(token, { participantId: 'student-pid-0001' });
    await env.DB.batch([
      env.DB.prepare('INSERT INTO participants (session_id, pid, nickname, created_at) VALUES (?, ?, ?, ?)').bind(session.id, 'student-pid-0001', 'მწვანე მელა', now()),
      env.DB.prepare('INSERT INTO participants (session_id, pid, created_at) VALUES (?, ?, ?)').bind(session.id, 'student-pid-0002', now()),
      env.DB.prepare("INSERT INTO attempts (id, session_id, pid, answer, created_at) VALUES (?, ?, ?, '{}', ?)").bind(id('att'), session.id, 'student-pid-0001', now()),
      env.DB.prepare("INSERT INTO attempts (id, session_id, pid, answer, created_at) VALUES (?, ?, ?, '{}', ?)").bind(id('att'), session.id, 'student-pid-0002', now()),
    ]);
    return { session, token };
  }

  const count = async (table: string, sessionId: string) =>
    (await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE session_id = ?`).bind(sessionId).first<{ n: number }>())!.n;

  type File = { version: number; sessions: unknown[]; responses: unknown[]; participants: { nickname: string | null; sessionId: string }[]; attempts: unknown[] };
  const exported = async () => (await (await call('GET', 'backup')).json()) as File;

  it('the database takes any game name and answers without a place; the Worker still allows only its games', async () => {
    await env.DB.prepare("INSERT INTO sessions (id, name, game, token_hash, created_at) VALUES ('future-game-01', 'F', 'terrain', 'tok-f', 1)").run();
    const { session } = await newSession();
    await env.DB.prepare("INSERT INTO responses (id, session_id, participant_id, answer, lat, lon, created_at) VALUES ('no-place-0001', ?, 'student-pid-0009', ?, NULL, NULL, 1)")
      .bind(session.id, JSON.stringify(answer))
      .run();
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { lat: number | null; lon: number | null }[] };
    expect(rows.responses[0]).toMatchObject({ lat: null, lon: null });
    expect((await call('POST', 'sessions', { name: 'X', game: 'terrain' })).status).toBe(400);
  });

  it('a backup is version 3 and carries participants and attempts', async () => {
    const { session } = await withStudent();
    const file = await exported();
    expect(file.version).toBe(3);
    expect(file.participants).toHaveLength(2);
    expect(file.participants.find((p) => p.nickname)).toMatchObject({ sessionId: session.id, participantId: 'student-pid-0001', nickname: 'მწვანე მელა' });
    expect(file.attempts).toHaveLength(2);
  });

  it('restores participants, and refuses attempts until a game can score them again', async () => {
    const { session } = await withStudent();
    const file = await exported();
    await call('DELETE', `sessions/${session.id}`);

    expect((await call('POST', 'restore', file)).status).toBe(400);
    expect(await count('sessions', session.id).catch(() => 0)).toBe(0);

    const restored = await call('POST', 'restore', { ...file, attempts: [] });
    expect(restored.status).toBe(200);
    expect(await restored.json()).toMatchObject({ sessions: 1, responses: 1, participants: 2 });
    expect(await count('participants', session.id)).toBe(2);
    expect(await count('attempts', session.id)).toBe(0);
  });

  it('refuses bad participants, changing nothing', async () => {
    const { session } = await withStudent();
    const file = { ...(await exported()), attempts: [] };
    await call('DELETE', `sessions/${session.id}`);
    const bad = [
      { nickname: 'x'.repeat(21) },
      { nickname: '' },
      { nickname: 5 },
      { participantId: 'x' },
      { sessionId: 'not-in-this-file' },
      { createdAt: 'yesterday' },
    ];
    for (const change of bad) {
      const participants = [{ ...file.participants[0], ...change }];
      expect((await call('POST', 'restore', { ...file, participants })).status).toBe(400);
    }
    expect((await call('POST', 'restore', { ...file, participants: 'all' })).status).toBe(400);
    expect((await exported()).sessions).toHaveLength(0);
  });

  it('still restores a version 2 file, which has no participants', async () => {
    const { session } = await withStudent();
    const { participants: _p, attempts: _a, ...file } = await exported();
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', { ...file, version: 2 })).status).toBe(200);
    expect(await count('responses', session.id)).toBe(1);
    expect(await count('participants', session.id)).toBe(0);
  });

  it('forget deletes the student’s attempts and nickname too, and nobody else’s', async () => {
    const { session, token } = await withStudent();
    expect(await (await student('forget', { token, participantId: 'student-pid-0001' })).json()).toEqual({ deleted: 1 });
    const left = await env.DB.prepare('SELECT pid FROM participants WHERE session_id = ? UNION ALL SELECT pid FROM attempts WHERE session_id = ?')
      .bind(session.id, session.id)
      .all<{ pid: string }>();
    expect(left.results.map((r) => r.pid)).toEqual(['student-pid-0002', 'student-pid-0002']);
  });

  it('a reset, deleting the session, and the six-month clean-up remove participants and attempts', async () => {
    const reset = await withStudent();
    expect((await call('DELETE', `sessions/${reset.session.id}/responses`)).status).toBe(200);
    expect(await count('participants', reset.session.id)).toBe(0);
    expect(await count('attempts', reset.session.id)).toBe(0);

    const gone = await withStudent();
    await call('DELETE', `sessions/${gone.session.id}`);
    expect(await count('participants', gone.session.id)).toBe(0);
    expect(await count('attempts', gone.session.id)).toBe(0);

    const { deleteOld, KEEP_SEC } = await import('../src/retention');
    const old = await withStudent();
    const fresh = await withStudent();
    await env.DB.prepare('UPDATE sessions SET created_at = ? WHERE id = ?').bind(now() - KEEP_SEC - 60, old.session.id).run();
    expect(await deleteOld(env)).toBe(1);
    expect(await count('participants', old.session.id)).toBe(0);
    expect(await count('attempts', old.session.id)).toBe(0);
    expect(await count('participants', fresh.session.id)).toBe(2);
    expect(await count('attempts', fresh.session.id)).toBe(2);
  });
});

describe('terrain profile game', () => {
  const profile = {
    area: { id: 'kazbegi', version: 1 },
    line: [
      [42.70, 44.50],
      [42.66, 44.56],
      [42.66, 44.64],
    ],
    length: 13300,
    questions: [
      { kind: 'max', answer: 4598, tolerance: 50 },
      { kind: 'min', answer: 1660 },
      { kind: 'length', answer: 13300 },
      { kind: 'steepest', answer: 0 },
      { kind: 'where_max', answer: 0 },
    ],
  };

  async function game(over: Record<string, unknown> = {}) {
    return call('POST', 'sessions', { name: 'Profile', game: 'profile', profile: { ...profile, ...over } });
  }

  const play = (token: string, round: number, kind: string, value: unknown, over: Record<string, unknown> = {}) =>
    student('submit', {
      token,
      submissionId: id('sub'),
      participantId: 'profile-player-01',
      answer: { kind, value },
      lat: 42.7,
      lon: 44.5,
      round,
      ...over,
    });

  it('stores the line and questions, with the default tolerance filled in', async () => {
    const res = await game();
    expect(res.status).toBe(201);
    const { session } = (await res.json()) as { session: { settings: { questions: { tolerance?: number }[] } } };
    expect(session.settings.questions[1].tolerance).toBe(50);
    expect(session.settings.questions[2]).toEqual({ kind: 'length', answer: 13300 });
  });

  it('refuses settings it cannot score', async () => {
    const bad = [
      { area: { id: '../x', version: 1 } },
      { line: [[42.7, 44.5]] },
      { line: Array.from({ length: 11 }, (_, i) => [42.7, 44.5 + i / 100]) },
      { line: [[95, 44.5], [42.6, 44.6]] },
      { length: 0 },
      { questions: [] },
      { questions: [{ kind: 'nope', answer: 1 }] },
      { questions: [{ kind: 'max', answer: 4598, tolerance: 1 }] },
      { questions: [{ kind: 'length', answer: 9000 }] },
      { questions: [{ kind: 'steepest', answer: 2 }] },
      { questions: [{ kind: 'steepest', answer: 0.5 }] },
      { line: [[42.7, 44.5], [42.6, 44.6]], questions: [{ kind: 'steepest', answer: 0 }] },
      { questions: [{ kind: 'where_max', answer: 20000 }] },
    ];
    for (const over of bad) expect((await game(over)).status, JSON.stringify(over)).toBe(400);
  });

  it('students get the line and the kinds of question, not the answers', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    const joined = (await (await student('join', { token })).json()) as { game: string; settings: Record<string, unknown> };
    expect(joined.game).toBe('profile');
    expect(joined.settings).toEqual({
      area: profile.area,
      line: profile.line,
      questions: [{ kind: 'max', tolerance: 50 }, { kind: 'min', tolerance: 50 }, { kind: 'length' }, { kind: 'steepest' }, { kind: 'where_max' }],
    });
    expect(JSON.stringify(joined)).not.toContain('4598');
  });

  it('scores each kind on the server, gives the right answer, and keeps the first try', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    expect(await (await play(token, 0, 'max', 4620)).json()).toEqual({ ok: true, duplicate: false, score: 100, kind: 'max', answer: 4598 });
    expect(await (await play(token, 0, 'max', 4598)).json()).toMatchObject({ duplicate: true, score: 100 });
    expect(await (await play(token, 1, 'min', 1760)).json()).toMatchObject({ score: 50, answer: 1660 }); // 100 m off, tolerance 50
    expect(await (await play(token, 2, 'length', 9000)).json()).toMatchObject({ score: 0 }); // 32 % short: nothing
    expect(await (await play(token, 3, 'steepest', 1)).json()).toMatchObject({ score: 0, answer: 0 });
    expect(await (await play(token, 4, 'where_max', 50)).json()).toMatchObject({ score: 100 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { round: number; score: number; answer: unknown }[] };
    expect(rows.responses.map((r) => [r.round, r.score])).toEqual([
      [0, 100],
      [1, 50],
      [2, 0],
      [3, 0],
      [4, 100],
    ]);
    expect(rows.responses[0].answer).toEqual({ kind: 'max', value: 4620 });
    expect(await (await play(token, 2, 'length', 10000, { participantId: 'profile-player-02' })).json()).toMatchObject({ score: 26 }); // 25 % short
  });

  it('refuses an answer of the wrong kind, a bad value or a round with no question', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    expect((await play(token, 0, 'min', 4598)).status).toBe(400);
    expect((await play(token, 0, 'max', 'high')).status).toBe(400);
    expect((await play(token, 3, 'steepest', 0.5)).status).toBe(400);
    expect((await play(token, 5, 'max', 4598)).status).toBe(400);
  });

  it('survives backup and restore, scored again', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    await play(token, 3, 'steepest', 1);
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { score: number }[] };
    file.responses[0].score = 100;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(0);
  });
});

describe('slope game', () => {
  const answer = '0110' + '0110' + '0000' + '0001';
  const slope = { area: { id: 'kazbegi', version: 1 }, box: { row: 100, col: 120, cells: 10, n: 4 }, threshold: 15, answer };

  const game = (over: Record<string, unknown> = {}) => call('POST', 'sessions', { name: 'Slope', game: 'slope', slope: { ...slope, ...over } });
  const play = (token: string, marks: unknown, over: Record<string, unknown> = {}) =>
    student('submit', { token, submissionId: id('sub'), participantId: 'slope-player-01', answer: { marks }, lat: 42.7, lon: 44.5, round: 0, ...over });

  it('refuses settings it cannot score', async () => {
    const bad = [
      { box: { row: 0, col: 120, cells: 10, n: 4 } },
      { box: { row: 100, col: 120, cells: 2, n: 4 } },
      { box: { row: 100, col: 120, cells: 10, n: 13 } },
      { threshold: 20 },
      { answer: '0'.repeat(16) },
      { answer: '01' },
      { answer: 'x'.repeat(16) },
      { area: { id: 'Kazbegi', version: 1 } },
    ];
    for (const over of bad) expect((await game(over)).status, JSON.stringify(over)).toBe(400);
  });

  it('students get the box and the threshold, not the right squares', async () => {
    const res = await game();
    expect(res.status).toBe(201);
    const { token } = (await res.json()) as { token: string };
    const joined = (await (await student('join', { token })).json()) as { settings: unknown };
    expect(joined.settings).toEqual({ area: slope.area, box: slope.box, threshold: 15 });
  });

  it('scores the overlap on the server and keeps the first answer', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    // 4 right of 5 right squares, plus 1 wrong: 4 / 6.
    const marks = '0110' + '0100' + '0000' + '0011';
    expect(await (await play(token, marks)).json()).toEqual({ ok: true, duplicate: false, score: 67, answer });
    expect(await (await play(token, answer)).json()).toMatchObject({ duplicate: true, score: 67 });
    expect(await (await play(token, answer, { participantId: 'slope-player-02' })).json()).toMatchObject({ score: 100 });
    expect(await (await play(token, '0'.repeat(16), { participantId: 'slope-player-03' })).json()).toMatchObject({ score: 0 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number; answer: unknown }[] };
    expect(rows.responses.map((r) => r.score).sort()).toEqual([0, 100, 67]);
  });

  it('refuses a marking of the wrong size or another round', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    expect((await play(token, '01')).status).toBe(400);
    expect((await play(token, '2'.repeat(16))).status).toBe(400);
    expect((await play(token, answer, { round: 1 })).status).toBe(400);
  });

  it('survives backup and restore, scored again', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    await play(token, '0'.repeat(16));
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { score: number }[] };
    file.responses[0].score = 100;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(0);
  });
});

describe('viewshed game', () => {
  const area = { id: 'kazbegi', version: 1 };
  const targets = [
    { row: 10, col: 10 },
    { row: 20, col: 30 },
    { row: 40, col: 5 },
    { row: 7, col: 70 },
  ];
  const byTargets = { area, observer: { row: 50, col: 50 }, height: 10, kind: 'targets', targets, answer: '1010' };
  const bySquares = { area, observer: { row: 50, col: 50 }, height: 1.7, kind: 'squares', box: { row: 0, col: 0, cells: 10, n: 4 }, answer: '0110' + '0110' + '0000' + '0001' };

  const game = (base: Record<string, unknown>, over: Record<string, unknown> = {}) =>
    call('POST', 'sessions', { name: 'View', game: 'viewshed', viewshed: { ...base, ...over } });
  const play = (token: string, seen: unknown, over: Record<string, unknown> = {}) =>
    student('submit', { token, submissionId: id('sub'), participantId: 'view-player-01', answer: { seen }, lat: 42.7, lon: 44.5, round: 0, ...over });

  it('refuses settings it cannot score', async () => {
    const bad: [Record<string, unknown>, Record<string, unknown>][] = [
      [byTargets, { height: 5 }],
      [byTargets, { kind: 'lines' }],
      [byTargets, { targets: targets.slice(0, 2), answer: '10' }],
      [byTargets, { targets: [...targets, targets[0]], answer: '10101' }],
      [byTargets, { targets: [...targets.slice(0, 3), { row: 50, col: 50 }] }],
      [byTargets, { targets: [{ row: -1, col: 0 }, ...targets.slice(1)] }],
      [byTargets, { answer: '101' }],
      [byTargets, { observer: { row: 1.5, col: 3 } }],
      [bySquares, { answer: '0'.repeat(16) }],
      [bySquares, { box: { row: 0, col: 0, cells: 2, n: 4 } }],
      [bySquares, { box: { row: 0, col: 0, cells: 10, n: 13 } }],
      [bySquares, { area: { id: 'Kazbegi', version: 1 } }],
    ];
    for (const [base, over] of bad) expect((await game(base, over)).status, JSON.stringify(over)).toBe(400);
  });

  it('students get the observer and the targets or the box, not what is seen', async () => {
    for (const [base, extra] of [
      [byTargets, { targets }],
      [bySquares, { box: bySquares.box }],
    ] as const) {
      const { token } = (await (await game(base)).json()) as { token: string };
      const joined = (await (await student('join', { token })).json()) as { settings: unknown };
      expect(joined.settings).toEqual({ area, observer: base.observer, height: base.height, kind: base.kind, ...extra });
    }
  });

  it('scores the targets judged right, and the first answer counts', async () => {
    const { session, token } = (await (await game(byTargets)).json()) as { session: { id: string }; token: string };
    expect(await (await play(token, '1000')).json()).toEqual({ ok: true, duplicate: false, score: 75, answer: '1010' });
    expect(await (await play(token, '1010')).json()).toMatchObject({ duplicate: true, score: 75 });
    expect(await (await play(token, '0101', { participantId: 'view-player-02' })).json()).toMatchObject({ score: 0 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses.map((r) => r.score).sort()).toEqual([0, 75]);
  });

  it('scores the squares by their overlap', async () => {
    const { token } = (await (await game(bySquares)).json()) as { token: string };
    expect(await (await play(token, '0110' + '0100' + '0000' + '0011')).json()).toMatchObject({ score: 67 });
  });

  it('refuses an answer of the wrong size or another round', async () => {
    const { token } = (await (await game(byTargets)).json()) as { token: string };
    expect((await play(token, '10')).status).toBe(400);
    expect((await play(token, '1x10')).status).toBe(400);
    expect((await play(token, '1010', { round: 1 })).status).toBe(400);
  });

  it('survives backup and restore, scored again', async () => {
    const { session, token } = (await (await game(bySquares)).json()) as { session: { id: string }; token: string };
    await play(token, '0'.repeat(16));
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as { responses: { score: number }[] };
    file.responses[0].score = 100;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(0);
  });
});

describe('game registry', () => {
  // A game that exists only in this test: registering this one module is all it takes.
  type Quiz = { questions: { q: string; right: string }[] };
  function readQuiz(raw: unknown): Quiz {
    const questions = (raw as Quiz | undefined)?.questions;
    if (!Array.isArray(questions) || questions.length === 0) throw new HttpError(400, 'bad_quiz');
    return { questions: questions.map((x) => ({ q: String(x.q), right: String(x.right) })) };
  }
  const quiz: GameModule<Quiz> = {
    id: 'test-quiz',
    timed: false,
    answers: 'first',
    settings: (body) => readQuiz(body.quiz),
    studentView: (s) => ({ questions: s.questions.map((x) => ({ q: x.q })) }),
    validateAnswer(raw) {
      const text = (raw as { text?: unknown } | null)?.text;
      if (typeof text !== 'string' || text.length > 50) throw new HttpError(400, 'bad_answer');
      return { text };
    },
    score(s, answer, _place, round) {
      const question = typeof round === 'number' ? s.questions[round] : undefined;
      if (!question) throw new HttpError(400, 'bad_round');
      return { round: round as number, distance: null, score: answer.text === question.right ? 100 : 0 };
    },
    feedback: (s, row) => ({ score: row.score, right: s.questions[row.round]?.right }),
    restoreSettings: readQuiz,
  };
  registerGame(quiz);
  registerGame({ ...quiz, id: 'test-quiz-timed', timed: true });

  const settings = { quiz: { questions: [{ q: 'Capital of Georgia?', right: 'Tbilisi' }, { q: 'Highest peak?', right: 'Shkhara' }] } };
  const play = (token: string, round: number, text: string, over: Record<string, unknown> = {}) =>
    student('submit', { token, submissionId: id('sub'), participantId: 'quiz-student-01', answer: { text }, lat: 41.7, lon: 44.8, round, ...over });

  async function quizSession(game = 'test-quiz') {
    const res = await call('POST', 'sessions', { name: 'Quiz', game, ...settings });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string }; token: string };
  }

  it('makes sessions of a registered game and still refuses unknown ones', async () => {
    await quizSession();
    expect((await call('POST', 'sessions', { name: 'Q', game: 'test-quiz' })).status).toBe(400);
    expect((await call('POST', 'sessions', { name: 'Q', game: 'not-registered' })).status).toBe(400);
  });

  it('gives students the module’s view, without the answers', async () => {
    const { token } = await quizSession();
    const joined = (await (await student('join', { token })).json()) as { game: string; settings: unknown };
    expect(joined.game).toBe('test-quiz');
    expect(joined.settings).toEqual({ questions: [{ q: 'Capital of Georgia?' }, { q: 'Highest peak?' }] });
  });

  it('checks, scores and gives feedback; the first answer counts', async () => {
    const { session, token } = await quizSession();
    const first = await play(token, 0, 'Tbilisi');
    expect(first.status).toBe(201);
    expect(await first.json()).toEqual({ ok: true, duplicate: false, score: 100, right: 'Tbilisi' });
    expect(await (await play(token, 0, 'Batumi')).json()).toEqual({ ok: true, duplicate: true, score: 100, right: 'Tbilisi' });
    expect(await (await play(token, 1, 'Kazbek')).json()).toMatchObject({ score: 0, right: 'Shkhara' });
    expect((await play(token, 5, 'x')).status).toBe(400);
    expect((await play(token, 1, 'x'.repeat(51))).status).toBe(400);

    const sub = id('sub');
    await play(token, 1, 'again', { submissionId: sub, participantId: 'quiz-student-02' });
    expect(await (await play(token, 1, 'changed', { submissionId: sub, participantId: 'quiz-student-02' })).json()).toMatchObject({ duplicate: true, score: 0 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { round: number; score: number }[] };
    expect(rows.responses.map((r) => [r.round, r.score])).toEqual([
      [0, 100],
      [1, 0],
      [1, 0],
    ]);
  });

  it('restores through the module, scoring the answers again', async () => {
    const { session, token } = await quizSession();
    await play(token, 0, 'Batumi');
    const file = (await (await call('GET', 'backup')).json()) as { responses: { answer: { text: string }; score: number }[] };
    file.responses[0].answer.text = 'Tbilisi';
    file.responses[0].score = 0;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(100);

    await call('DELETE', `sessions/${session.id}`);
    (file as unknown as { sessions: { settings: unknown }[] }).sessions[0].settings = { questions: [] };
    expect((await call('POST', 'restore', file)).status).toBe(400);
  });

  it('a timed module gets the teacher’s clock', async () => {
    const plain = await quizSession();
    expect((await call('POST', `sessions/${plain.session.id}/timer`, { seconds: 60 })).status).toBe(400);

    const { session, token } = await quizSession('test-quiz-timed');
    expect(await (await play(token, 0, 'Tbilisi')).json()).toMatchObject({ error: 'not_started' });
    expect((await call('POST', `sessions/${session.id}/timer`, { seconds: 60 })).status).toBe(200);
    expect((await play(token, 0, 'Tbilisi')).status).toBe(201);
  });
});

describe('student nicknames', () => {
  const pick = (token: string, nickname: unknown, participantId = 'nick-student-01') => student('nickname', { token, participantId, nickname });
  const polled = async (sessionId: string) =>
    (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as { nicknames: Record<string, string>; session: { rev: number } };

  it('a student picks, changes and clears a nickname; the teacher sees it', async () => {
    const { session, token } = await newSession();
    const res = await pick(token, '  მწვანე   მელა ');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, nickname: 'მწვანე მელა' });
    expect((await polled(session.id)).nicknames).toEqual({ 'nick-student-01': 'მწვანე მელა' });

    const rev = (await polled(session.id)).session.rev;
    await pick(token, 'Rioni Otter');
    const after = await polled(session.id);
    expect(after.nicknames).toEqual({ 'nick-student-01': 'Rioni Otter' });
    expect(after.session.rev).toBeGreaterThan(rev);

    expect(await (await pick(token, null)).json()).toEqual({ ok: true, nickname: null });
    expect((await polled(session.id)).nicknames).toEqual({});
  });

  it('refuses what isn’t a made-up short name, and wrong tokens or ids', async () => {
    const { token } = await newSession();
    for (const bad of ['x'.repeat(21), '<b>hi</b>', '-dash', 'a\u0000b', 42, ['Fox']]) {
      expect((await pick(token, bad)).status, String(bad)).toBe(400);
    }
    expect((await pick('wrong-token', 'Fox')).status).toBe(404);
    expect((await pick(token, 'Fox', 'x')).status).toBe(400);
  });

  it('is kept per session: the same id elsewhere is someone else', async () => {
    const a = await newSession();
    const b = await newSession();
    await pick(a.token, 'Kazbegi Owl');
    expect((await polled(b.session.id)).nicknames).toEqual({});
  });

  it('goes with forget, and comes back through a backup', async () => {
    const { session, token } = await newSession();
    await send(token, { participantId: 'nick-student-01' });
    await pick(token, 'Mtatsminda Lynx');
    const file = (await (await call('GET', 'backup')).json()) as { participants: unknown[] };
    expect(file.participants).toHaveLength(1);

    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await polled(session.id)).nicknames).toEqual({ 'nick-student-01': 'Mtatsminda Lynx' });

    await call('DELETE', `sessions/${session.id}`);
    const edited = JSON.parse(JSON.stringify(file)) as { participants: { nickname: string }[] };
    edited.participants[0].nickname = '<b>x</b>';
    expect((await call('POST', 'restore', edited)).status).toBe(400);
  });

  it('forget deletes it', async () => {
    const { session, token } = await newSession();
    await pick(token, 'Borjomi Deer');
    await student('forget', { token, participantId: 'nick-student-01' });
    expect((await polled(session.id)).nicknames).toEqual({});
  });
});

describe('watershed game', () => {
  // A 30 × 30 area: the cells along the edge drain out of it; inside, water runs east or west to the middle
  // column, and down it to the south. The basin at (20, 15) is rows 1 to 20 of the inside: 20 × 28 cells.
  const W = 30;
  const flow = new Uint8Array(W * W);
  for (let r = 0; r < W; r++) {
    for (let c = 0; c < W; c++) {
      flow[r * W + c] = r === 0 ? 1 : r === W - 1 ? 255 : c === 0 ? 3 : c === W - 1 ? 7 : c < 15 ? 7 : c > 15 ? 3 : 5;
    }
  }
  const area = { id: 'basin-test', version: 1 };
  const basin = Array.from({ length: 20 }, (_, i) => [i + 1, 1, 29]);
  beforeEach(async () => {
    const gz = new Uint8Array(await new Response(new Blob([flow]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    await env.AREAS.put('areas/basin-test/1/area.json', JSON.stringify({ id: 'basin-test', width: W, height: W }));
    await env.AREAS.put('areas/basin-test/1/flow.u8.gz', gz);
  });

  const game = (over: Record<string, unknown> = {}) =>
    call('POST', 'sessions', { name: 'Basin', game: 'watershed', watershed: { area, outlet: { row: 20, col: 15 }, ...over } });
  const play = (token: string, poly: unknown, over: Record<string, unknown> = {}) =>
    student('submit', { token, submissionId: id('sub'), participantId: 'basin-player-01', answer: { poly }, lat: 42.2, lon: 42.7, round: 0, ...over });

  it('works the basin out on the server, from the area’s flow directions', async () => {
    const res = await game();
    expect(res.status).toBe(201);
    const { session } = (await res.json()) as { session: { settings: Record<string, unknown> } };
    expect(session.settings).toEqual({ area, outlet: { row: 20, col: 15 }, width: W, height: W, cells: 560, runs: basin });
  });

  it('refuses outlets with no playable basin, and areas without flow directions', async () => {
    // The same area, but the top row drains south into it: every basin reaching row 1 is cut off by the edge.
    const open = flow.map((d, i) => (i < W ? 5 : d));
    const gz = new Uint8Array(await new Response(new Blob([open]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    await env.AREAS.put('areas/basin-edge/1/area.json', JSON.stringify({ id: 'basin-edge', width: W, height: W }));
    await env.AREAS.put('areas/basin-edge/1/flow.u8.gz', gz);
    const bad: [Record<string, unknown>, string][] = [
      [{ area: { id: 'basin-edge', version: 1 } }, 'basin_edge'],
      // A cell on a side stream, reached only by the cells west of it in its row.
      [{ outlet: { row: 5, col: 3 } }, 'basin_small'],
      [{ outlet: { row: 30, col: 15 } }, 'bad_watershed'],
      [{ outlet: { row: 1.5, col: 15 } }, 'bad_watershed'],
      [{ area: { id: 'kazbegi', version: 1 } }, 'no_flow'],
      [{ area: { id: 'Basin', version: 1 } }, 'bad_watershed'],
    ];
    for (const [over, code] of bad) {
      const res = await game(over);
      expect(res.status, JSON.stringify(over)).toBe(400);
      expect(((await res.json()) as { error: string }).error, JSON.stringify(over)).toBe(code);
    }
  });

  it('students get the outlet, not the basin; the score is the overlap', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    const joined = (await (await student('join', { token })).json()) as { settings: unknown };
    expect(joined.settings).toEqual({ area, outlet: { row: 20, col: 15 } });
    // Rows 1 to 20, columns 1 to 15: half the basin, all of it in.
    const half = await play(token, [
      [1, 1],
      [1, 15],
      [21, 15],
      [21, 1],
    ]);
    expect(await half.json()).toEqual({ ok: true, duplicate: false, score: 50, basin });
    expect(await (await play(token, [[1, 1], [1, 29], [21, 29], [21, 1]])).json()).toMatchObject({ duplicate: true, score: 50 });
    expect(await (await play(token, [[1, 1], [1, 29], [21, 29], [21, 1]], { participantId: 'basin-player-02' })).json()).toMatchObject({ score: 100 });
  });

  it('refuses polygons it cannot score', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    for (const poly of [
      [
        [1, 1],
        [1, 5],
      ],
      [
        [0, 0],
        [0, 4],
        [4, 0],
        [4, 4],
      ],
      [
        [1, 1],
        [1, 31],
        [5, 5],
      ],
      [
        [1, 1],
        [1, 'x'],
        [5, 5],
      ],
      Array.from({ length: 101 }, (_, i) => [10 + 5 * Math.sin(i / 16), 10 + 5 * Math.cos(i / 16)]),
    ]) {
      expect((await play(token, poly)).status, JSON.stringify(poly).slice(0, 60)).toBe(400);
    }
    expect((await play(token, [[1, 1], [1, 5], [5, 5]], { round: 1 })).status).toBe(400);
  });

  it('survives backup and restore, scored again; a tampered basin is refused', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    await play(token, [[1, 1], [1, 15], [21, 15], [21, 1]]);
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as {
      sessions: { settings: { runs: number[][]; cells: number } }[];
      responses: { score: number }[];
    };
    file.responses[0].score = 100;
    await call('DELETE', `sessions/${session.id}`);
    const broken = structuredClone(file);
    broken.sessions[0].settings.runs[3] = [1, 1, 29]; // out of order
    expect((await call('POST', 'restore', broken)).status).toBe(400);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(50);
  });
});

describe('least-cost game', () => {
  // A 40 × 40 area rising evenly to the south, 3 m every 30 m: every cell costs the same, so the straight line
  // east from A to B is the best route, and a detour costs more.
  const W = 40;
  const steps = new Uint16Array(W * W).map((_, i) => (1000 + 3 * Math.floor(i / W)) * 10);
  const area = { id: 'route-test', version: 1 };
  const slope = { kind: 'slope', theta: 15 };
  const start = { row: 20, col: 5 };
  const end = { row: 20, col: 35 };
  beforeEach(async () => {
    const raw = new Uint8Array(steps.buffer);
    const gz = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    await env.AREAS.put('areas/route-test/1/area.json', JSON.stringify({ id: 'route-test', width: W, height: W, cell: 30, grid: { scale: 0.1, nodata: 65535 } }));
    await env.AREAS.put('areas/route-test/1/dem.u16.gz', gz);
  });
  const heights: Heights = { width: W, height: W, cell: 30, z: Float64Array.from(steps, (v) => v * 0.1) };
  const cost = (corners: { row: number; col: number }[]) =>
    routeCost(heights, { kind: 'slope', theta: 15 }, routeThrough(corners.map((c) => c.row * W + c.col), W))!;

  const game = (over: Record<string, unknown> = {}) =>
    call('POST', 'sessions', { name: 'Route', game: 'least-cost', leastCost: { area, model: slope, start, end, steps: '4'.repeat(30), ...over } });
  const play = (token: string, via: unknown, over: Record<string, unknown> = {}) =>
    student('submit', { token, submissionId: id('sub'), participantId: 'route-player-01', answer: { via }, lat: 42.6, lon: 44.6, round: 0, ...over });

  it('costs the teacher’s route on the server, from the area’s heights', async () => {
    const res = await game();
    expect(res.status).toBe(201);
    const { session } = (await res.json()) as { session: { settings: Record<string, unknown> } };
    expect(session.settings.best).toBeCloseTo(cost([start, end]), 9);
    expect(session.settings).toMatchObject({ area, model: slope, start, end, width: W, height: W });
  });

  it('refuses routes that aren’t from A to B, and settings it can’t score', async () => {
    const bad: [Record<string, unknown>, string][] = [
      [{ steps: '4'.repeat(29) }, 'bad_least_cost'], // stops short of B
      [{ steps: '4'.repeat(30) + '9' }, 'bad_least_cost'],
      [{ model: { kind: 'slope', theta: 12 } }, 'bad_least_cost'],
      [{ model: { kind: 'walk' } }, 'bad_least_cost'],
      [{ end: { row: 20, col: 12 }, steps: '4'.repeat(7) }, 'too_close'],
      [{ end: { row: 20, col: 40 } }, 'bad_least_cost'],
      // West off the edge from column 0 would land on the row above: refused, not wrapped.
      [{ model: { kind: 'tobler' }, start: { row: 20, col: 0 }, end: { row: 19, col: 39 }, steps: '3' }, 'bad_least_cost'],
      // The slope model can't cross the edge cells, which have no slope.
      [{ start: { row: 0, col: 5 }, end: { row: 0, col: 35 } }, 'blocked'],
      [{ area: { id: 'kazbegi', version: 1 } }, 'no_area'],
    ];
    for (const [over, code] of bad) {
      const res = await game(over);
      expect(res.status, JSON.stringify(over)).toBe(400);
      expect(((await res.json()) as { error: string }).error, JSON.stringify(over)).toBe(code);
    }
  });

  it('students get A, B and the model, not the route; the score is the best cost over theirs', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    const joined = (await (await student('join', { token })).json()) as { settings: unknown };
    expect(joined.settings).toEqual({ area, model: slope, start, end });
    const detour = { row: 30, col: 20 };
    const want = Math.round((100 * cost([start, end])) / cost([start, detour, end]));
    expect(want).toBeLessThan(100);
    const first = (await (await play(token, [[30, 20]])).json()) as Record<string, unknown>;
    expect(first).toMatchObject({ ok: true, duplicate: false, score: want, steps: '4'.repeat(30) });
    expect(first.best).toBeCloseTo(cost([start, end]), 9);
    expect(await (await play(token, [])).json()).toMatchObject({ duplicate: true, score: want });
    expect(await (await play(token, [], { participantId: 'route-player-02' })).json()).toMatchObject({ score: 100 });
  });

  it('refuses answers it cannot score', async () => {
    const { token } = (await (await game()).json()) as { token: string };
    for (const via of [[[40, 3]], [[1.5, 3]], 'x', Array.from({ length: 101 }, () => [10, 10]), [[0, 20]]]) {
      expect((await play(token, via)).status, JSON.stringify(via).slice(0, 40)).toBe(400);
    }
    expect((await play(token, [], { round: 1 })).status).toBe(400);
  });

  it('survives backup and restore, scored again from the heights; a stored best cost changes nothing', async () => {
    const { session, token } = (await (await game()).json()) as { session: { id: string }; token: string };
    await play(token, [[30, 20]]);
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as {
      sessions: { settings: { best: number; steps: string } }[];
      responses: { score: number }[];
    };
    const was = file.responses[0].score;
    file.responses[0].score = 100;
    file.sessions[0].settings.best = 1e9;
    await call('DELETE', `sessions/${session.id}`);
    const broken = structuredClone(file);
    broken.sessions[0].settings.steps = '4'.repeat(29);
    expect((await call('POST', 'restore', broken)).status).toBe(400);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(was);
  });
});
