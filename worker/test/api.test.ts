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
    expect(Object.keys(data).sort()).toEqual(['game', 'name', 'status']);
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
