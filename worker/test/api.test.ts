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
    expect(Object.keys(data).sort()).toEqual(['game', 'name', 'settings', 'status']);
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
