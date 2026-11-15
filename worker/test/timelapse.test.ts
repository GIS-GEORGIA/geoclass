import { env, exports } from 'cloudflare:workers';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import fixture from '../../test/fixtures/timelapse/iou.json';
import { iou, LIMITS, type Outline } from '../src/games/timelapse';
import { timelapseKey } from '../src/timelapse';

const auth = { Authorization: 'Bearer test-teacher-key' };

function call(method: string, path: string, body?: unknown, headers: Record<string, string> = auth) {
  return exports.default.fetch(`https://geoclass.test/api/${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
const get = (path: string, method = 'GET') => exports.default.fetch(`https://geoclass.test${path}`, { method });

let n = 0;
const sid = () => `timelapse-${String(++n).padStart(4, '0')}`;

const catalog = { sites: [{ id: 'madneuli', version: 1, ka: 'კაზრეთი', en: 'Kazreti', kind: 'mine', bbox: [44.37, 41.34, 44.49, 41.42], years: [1990, 2000, 2020] }] };
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

beforeAll(async () => {
  await env.AREAS.put('timelapse/catalog.json', JSON.stringify(catalog));
  await env.AREAS.put('timelapse/madneuli/1/site.json', JSON.stringify({ id: 'madneuli', frames: [] }));
  await env.AREAS.put('timelapse/madneuli/1/1990.jpg', jpeg);
  await env.AREAS.put('timelapse/secret.txt', 'not a frame');
});

beforeEach(async () => {
  await env.DB.exec('DELETE FROM sessions');
  await env.DB.exec('DELETE FROM templates');
});

describe('time-lapse IoU, against GDAL/OGR', () => {
  for (const c of fixture.cases) {
    it(c.name, () => {
      // Exact along each line, 2000 lines: within 0.002 of OGR's polygon overlay.
      expect(Math.abs(iou(c.truth as Outline, c.answer as Outline) - c.iou)).toBeLessThan(0.002);
    });
  }
  it('is 0 for an empty outline and does not depend on the order of the rings', () => {
    const c = fixture.cases.find((x) => x.name === 'many_pits')!;
    expect(iou(c.truth as Outline, [])).toBe(0);
    expect(iou(c.truth as Outline, [...(c.answer as Outline)].reverse())).toBeCloseTo(iou(c.truth as Outline, c.answer as Outline), 9);
  });
});

describe('time-lapse frames', () => {
  it('serves the catalog briefly and versioned files for a year', async () => {
    const cat = await get('/timelapse/catalog.json');
    expect(cat.status).toBe(200);
    expect(cat.headers.get('Cache-Control')).toBe('public, max-age=300');
    expect(await cat.json()).toEqual(catalog);
    const frame = await get('/timelapse/madneuli/1/1990.jpg');
    expect(frame.status).toBe(200);
    expect(frame.headers.get('Content-Type')).toBe('image/jpeg');
    expect(frame.headers.get('Cache-Control')).toBe('public, max-age=31536000, immutable');
    expect(frame.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(new Uint8Array(await frame.arrayBuffer())).toEqual(jpeg);
    expect((await get('/timelapse/madneuli/1/site.json')).headers.get('Content-Type')).toBe('application/json; charset=utf-8');
    expect(await (await get('/timelapse/madneuli/1/1990.jpg', 'HEAD')).text()).toBe('');
  });

  it('looks up only the known names', async () => {
    expect((await get('/timelapse/madneuli/1/2001.jpg')).status).toBe(404);
    expect((await get('/timelapse/secret.txt')).status).toBe(404);
    expect((await get('/timelapse/madneuli/1/../../secret.txt')).status).toBe(404);
    expect((await get('/timelapse/catalog.json', 'POST')).status).toBe(405);
    for (const p of ['/timelapse/x/1/1990.png', '/timelapse/X/1/1990.jpg', '/timelapse/x/1/1890.jpg', '/timelapse/x/01/site.json.gz']) {
      expect(timelapseKey(p), p).toBeNull();
    }
    expect(timelapseKey('/timelapse/x/01/2020.jpg')).toBe('timelapse/x/1/2020.jpg');
  });
});

describe('time-lapse game', () => {
  const c = fixture.cases.find((x) => x.name === 'concave')!;
  const truthA = c.truth as Outline;
  const truthB = fixture.cases.find((x) => x.name === 'overlapping_rings')!.truth as Outline;
  const data = (over: Record<string, unknown> = {}) => ({ site: 'madneuli', version: 1, years: [1990, 2020], truth: [truthA, truthB], ...over });

  async function newGame(over: Record<string, unknown> = {}) {
    const t = await call('POST', 'templates', { game: 'timelapse', name: 'Madneuli', data: data(over) });
    expect(t.status).toBe(201);
    const { template } = (await t.json()) as { template: { id: string } };
    return { id: template.id, res: await call('POST', 'sessions', { name: 'pits', game: 'timelapse', timelapse: { template: template.id } }) };
  }
  const play = (token: string, a: unknown, round: unknown = 0, participantId = sid()) =>
    call('POST', 'submit', { token, submissionId: sid(), participantId, answer: a, lat: 41.7, lon: 44.8, round }, {});

  it('keeps drafts; a template needs its site from the start', async () => {
    expect((await call('POST', 'templates', { game: 'timelapse', name: 'x' })).status).toBe(400);
    const draft = await call('POST', 'templates', { game: 'timelapse', name: 'x', data: data({ truth: [[], []] }) });
    expect(draft.status).toBe(201);
    const { template } = (await draft.json()) as { template: { id: string } };
    const made = await call('POST', 'sessions', { name: 'x', game: 'timelapse', timelapse: { template: template.id } });
    expect(await made.json()).toEqual({ error: 'template_unfinished' });
  });

  it('the student sees the site and years, not the outlines; scoring is the mean IoU', async () => {
    const { res } = await newGame();
    expect(res.status).toBe(201);
    const { token, session } = (await res.json()) as { token: string; session: { id: string } };
    const joined = (await (await call('POST', 'join', { token }, {})).json()) as { game: string; settings: Record<string, unknown> };
    expect(joined.game).toBe('timelapse');
    expect(Object.keys(joined.settings).sort()).toEqual(['name', 'site', 'template', 'version', 'years']);
    expect(joined.settings.years).toEqual([1990, 2020]);

    // Year A as in the fixture (IoU 0.4045), year B exact (1): 70.
    const r = await play(token, { a: c.answer, b: truthB }, 0, 'timelapse-player-1');
    expect(r.status).toBe(201);
    const fb = (await r.json()) as { score: number; truth: unknown };
    expect(fb.score).toBe(Math.round(((c.iou + 1) / 2) * 100));
    expect(fb.truth).toEqual([truthA, truthB]);
    expect(await (await play(token, { a: truthA, b: truthB }, 0, 'timelapse-player-1')).json()).toMatchObject({ duplicate: true, score: fb.score });
    // Nothing drawn for one year: that year is 0.
    expect(await (await play(token, { a: truthA, b: [] })).json()).toMatchObject({ score: 50 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: unknown[] };
    expect(rows.responses).toHaveLength(2);
  });

  it('refuses sites, years and outlines it cannot use, and bad answers', async () => {
    expect(await (await newGame({ site: 'chiatura' })).res.json()).toEqual({ error: 'no_site' });
    expect(await (await newGame({ years: [1990, 2021] })).res.json()).toEqual({ error: 'no_site' });
    expect(await (await newGame({ years: [2020, 1990] })).res.json()).toEqual({ error: 'template_unfinished' });
    const far = [[[42.0, 44.0], [42.0, 44.01], [42.01, 44.01]]];
    expect(await (await newGame({ truth: [far, truthB] })).res.json()).toEqual({ error: 'template_unfinished' });
    expect((await call('POST', 'templates', { game: 'timelapse', name: 'x', data: data({ years: [1990] }) })).status).toBe(400);
    expect((await call('POST', 'templates', { game: 'timelapse', name: 'x', data: data({ site: '../x' }) })).status).toBe(400);

    const { res } = await newGame();
    const { token } = (await res.json()) as { token: string };
    const ring = (k: number) => Array.from({ length: k }, (_, i) => [41.37 + i * 1e-4, 44.45 + (i % 2) * 1e-4]);
    for (const a of [
      null,
      { a: [], b: [] },
      { a: [ring(2)], b: [] },
      { a: [ring(LIMITS.answerVertices + 1)], b: [] },
      { a: Array.from({ length: LIMITS.answerRings + 1 }, () => ring(3)), b: [] },
      { a: [[[91, 44], [41, 44], [41, 45]]], b: [] },
      { a: 'x', b: [] },
    ]) {
      expect((await play(token, a)).status, JSON.stringify(a)).toBe(400);
    }
    expect((await play(token, { a: truthA, b: truthB }, 1)).status).toBe(400);
  });

  it('survives backup and restore', async () => {
    const { res } = await newGame();
    const { session, token } = (await res.json()) as { session: { id: string }; token: string };
    await play(token, { a: truthA, b: truthB });
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as Record<string, unknown>;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(100);
  });
});
