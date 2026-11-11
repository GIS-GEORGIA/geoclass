import { env, exports } from 'cloudflare:workers';
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
});

describe('teacher access', () => {
  it('rejects a missing or wrong key', async () => {
    expect((await call('GET', 'sessions', undefined, {})).status).toBe(401);
    expect((await call('GET', 'sessions', undefined, { Authorization: 'Bearer nope' })).status).toBe(401);
    expect((await call('GET', 'backup', undefined, {})).status).toBe(401);
  });

  it('gives out only part of the key, and that part alone does not sign in', async () => {
    const res = await call('GET', 'key-hint', undefined, {});
    expect(res.status).toBe(200);
    const { hint } = (await res.json()) as { hint: string };
    expect(KEY.startsWith(hint)).toBe(true);
    expect(hint.length).toBeLessThan(KEY.length);
    expect((await call('GET', 'me', undefined, { Authorization: `Bearer ${hint}` })).status).toBe(401);
  });

  it('accepts the right key', async () => {
    expect((await call('GET', 'me')).status).toBe(200);
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

describe('cards game', () => {
  const pairs = ['a', 'b', 'c'].map((x, i) => ({ a: `${x}-1.jpg`, b: `${x}-2.jpg`, label: `ადგილი ${i}`, ra: 0, rb: i * 90 }));
  const deck = { pairs, arrow: true, rotation: 'quarter' };

  async function game(over: Record<string, unknown> = {}) {
    const res = await call('POST', 'sessions', { name: 'Cards', game: 'cards', cards: deck, ...over });
    expect(res.status).toBe(201);
    return (await res.json()) as { session: { id: string }; token: string };
  }

  const play = (token: string, answer: unknown, participantId = 'student-0001') =>
    student('submit', { token, submissionId: id('sub'), participantId, answer, lat: 0, lon: 0 });

  const start = (sessionId: string, seconds = 180) => call('POST', `sessions/${sessionId}/timer`, { seconds });

  async function rows(sessionId: string) {
    return (await (await call('GET', `sessions/${sessionId}/responses`)).json()) as {
      responses: { round: number; participantId: string; answer: { ok: boolean; pair?: number } }[];
    };
  }

  it('hands the deck to students once the clock runs', async () => {
    const { session, token } = await game();
    const joined = (await (await student('join', { token })).json()) as { settings: { pairs: unknown[]; arrow: boolean; endsAt?: number } };
    expect(joined.settings.pairs).toHaveLength(3);
    expect(joined.settings.arrow).toBe(true);
    expect(joined.settings.endsAt).toBeUndefined();
    expect((await play(token, { ok: true, pair: 0 })).status).toBe(409);

    expect((await start(session.id)).status).toBe(200);
    const running = (await (await student('join', { token })).json()) as { settings: { endsAt: number }; now: number };
    expect(running.settings.endsAt - running.now).toBeGreaterThan(170);
  });

  it('keeps a found pair once and counts wrong tries', async () => {
    const { session, token } = await game();
    await start(session.id);
    expect((await play(token, { ok: true, pair: 1 })).status).toBe(201);
    const again = await play(token, { ok: true, pair: 1 });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ ok: true, duplicate: true });
    expect((await play(token, { ok: false, x: 0, y: 2 })).status).toBe(201);
    expect((await play(token, { ok: false, x: 0, y: 2 })).status).toBe(201);
    // Another student finds the same pair: that is a different answer.
    expect((await play(token, { ok: true, pair: 1 }, 'student-0002')).status).toBe(201);

    const { responses } = await rows(session.id);
    expect(responses.filter((r) => r.answer.ok).map((r) => r.participantId)).toEqual(['student-0001', 'student-0002']);
    expect(responses.filter((r) => !r.answer.ok).map((r) => r.round)).toEqual([100, 101]);
  });

  it('refuses answers that do not fit the deck', async () => {
    const { session, token } = await game();
    await start(session.id);
    expect((await play(token, { ok: true, pair: 3 })).status).toBe(400);
    expect((await play(token, { ok: true, pair: 99 })).status).toBe(400);
    expect((await play(token, { ok: true, pair: -1 })).status).toBe(400);
    expect((await play(token, { ok: true })).status).toBe(400);
    expect((await play(token, { ok: false, x: 0, y: 3 })).status).toBe(400);
    expect((await play(token, { ok: 'yes', pair: 0 })).status).toBe(400);
    expect((await rows(session.id)).responses).toHaveLength(0);
  });

  it('stops at the end of the time, and a reset starts over', async () => {
    const { session, token } = await game();
    await start(session.id);
    await env.DB.prepare("UPDATE sessions SET settings = json_set(settings, '$.endsAt', unixepoch() - 60) WHERE id = ?").bind(session.id).run();
    expect(await (await play(token, { ok: true, pair: 0 })).json()).toEqual({ error: 'time_up' });
    await call('DELETE', `sessions/${session.id}/responses`);
    expect(await (await play(token, { ok: true, pair: 0 })).json()).toEqual({ error: 'not_started' });
    // The deck survives a reset.
    const joined = (await (await student('join', { token })).json()) as { settings: { pairs: unknown[] } };
    expect(joined.settings.pairs).toHaveLength(3);
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

  it('keeps the deck and every try through a backup', async () => {
    const { session, token } = await game();
    await start(session.id);
    await play(token, { ok: true, pair: 2 });
    await play(token, { ok: false, x: 0, y: 1 });
    const file = await (await call('GET', `backup?session=${session.id}`)).json();
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    expect((await rows(session.id)).responses.map((r) => r.round)).toEqual([2, 100]);
    const restored = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { session: { settings: { pairs: unknown[] } } };
    expect(restored.session.settings.pairs).toHaveLength(3);
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
