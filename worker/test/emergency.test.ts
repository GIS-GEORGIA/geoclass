import { env, exports } from 'cloudflare:workers';
import { beforeEach, describe, expect, it } from 'vitest';
import cases from '../../test/fixtures/emergency/formats.json';
import { classifyCoords, distancePoints } from '../src/games/emergency';

const auth = { Authorization: 'Bearer test-teacher-key' };

function call(method: string, path: string, body?: unknown, headers: Record<string, string> = auth) {
  return exports.default.fetch(`https://geoclass.test/api/${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

/** A JPEG as far as the server looks: it starts FF D8 FF. */
const jpeg = (size = 1000, fill = 7) => {
  const b = new Uint8Array(size).fill(fill);
  b.set([0xff, 0xd8, 0xff, 0xe0]);
  return b;
};

const upload = (template: string, bytes: Uint8Array, headers: Record<string, string> = auth) =>
  exports.default.fetch(`https://geoclass.test/api/templates/${template}/photos`, {
    method: 'POST',
    headers: { 'Content-Type': 'image/jpeg', ...headers },
    body: bytes,
  });

let n = 0;
const sid = () => `emergency-${String(++n).padStart(4, '0')}`;

const point = (photos: string[], over: Record<string, unknown> = {}) => ({
  lat: 41.7151,
  lon: 44.8271,
  format: 'dm',
  title: 'Mtatsminda',
  text: 'Your friend twisted an ankle on the path below the TV tower.',
  facts: { kind: 'injury', people: 2, injured: true, landmark: 'TV tower' },
  photos: photos.map((id, i) => ({ id, note: `note ${i}` })),
  best: 1,
  ...over,
});

async function newTemplate(headers = auth) {
  const res = await call('POST', 'templates', { game: 'emergency', name: 'Tbilisi walks' }, headers);
  expect(res.status).toBe(201);
  const { template } = (await res.json()) as { template: { id: string } };
  const photos: string[] = [];
  for (let i = 0; i < 3; i++) {
    const r = await upload(template.id, jpeg(1000, i), headers);
    expect(r.status).toBe(201);
    photos.push(((await r.json()) as { id: string }).id);
  }
  return { id: template.id, photos };
}

beforeEach(async () => {
  await env.DB.exec('DELETE FROM sessions');
  await env.DB.exec('DELETE FROM templates');
  await env.DB.exec('DELETE FROM teachers');
});

describe('112 coordinate formats, as the app classifies them', () => {
  it('classifies each shared case the same way', () => {
    for (const [text, format] of cases.formats) expect(classifyCoords(text as string), text as string).toBe(format);
  });
  it('gives distance points on a log scale, 40 within 50 m to 0 at 5 km', () => {
    for (const [d, p] of cases.distance) expect(distancePoints(d)).toBe(p);
  });
});

describe('templates and photos', () => {
  it('a teacher keeps templates; photos are JPEGs served publicly and deleted with the template', async () => {
    const { id, photos } = await newTemplate();
    const data = { points: [point(photos)] };
    const saved = await call('PATCH', `templates/${id}`, { data });
    expect(saved.status).toBe(200);
    expect(((await saved.json()) as { template: { data: unknown } }).template.data).toEqual(data);
    const list = (await (await call('GET', 'templates?game=emergency')).json()) as { templates: Record<string, unknown>[] };
    expect(list.templates).toHaveLength(1);
    expect(list.templates[0]).not.toHaveProperty('data');

    const photo = await exports.default.fetch(`https://geoclass.test/photos/${id}/${photos[0]}.jpg`);
    expect(photo.status).toBe(200);
    expect(photo.headers.get('Content-Type')).toBe('image/jpeg');
    expect(photo.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(photo.headers.get('Cache-Control')).toContain('immutable');
    expect(new Uint8Array(await photo.arrayBuffer())).toEqual(jpeg(1000, 0));
    for (const bad of [`/photos/${id}/${photos[0]}.png`, `/photos/${id}/../x.jpg`, `/photos/${id}/0000000000000000.jpg`]) {
      expect((await exports.default.fetch(`https://geoclass.test${bad}`)).status, bad).toBe(404);
    }

    expect((await call('DELETE', `templates/${id}/photos/${photos[2]}`)).status).toBe(200);
    expect((await exports.default.fetch(`https://geoclass.test/photos/${id}/${photos[2]}.jpg`)).status).toBe(404);
    expect((await call('DELETE', `templates/${id}`)).status).toBe(200);
    expect((await env.AREAS.list({ prefix: `photos/${id}/` })).objects).toHaveLength(0);
    expect((await call('GET', `templates/${id}`)).status).toBe(404);
  });

  it('refuses what is not a JPEG, too big, or not a template', async () => {
    const { id } = await newTemplate();
    expect((await upload(id, new TextEncoder().encode('<svg onload=alert(1)>'))).status).toBe(400);
    expect((await upload(id, jpeg(400 * 1024 + 1))).status).toBe(413);
    expect((await upload(id, jpeg(), {})).status).toBe(401);
    for (const body of [
      { game: 'travel', name: 'x' },
      { game: 'emergency', name: '' },
      { game: 'emergency', name: 'x', data: { points: 'no' } },
      { game: 'emergency', name: 'x', data: { points: [point([], { lat: 10 })] } },
      { game: 'emergency', name: 'x', data: { points: [point([], { format: 'mgrs' })] } },
      { game: 'emergency', name: 'x', data: { points: [point(['bad'])] } },
      { game: 'emergency', name: 'x', data: { points: Array.from({ length: 9 }, () => point([], { best: 0 })) } },
    ]) {
      expect((await call('POST', 'templates', body)).status, JSON.stringify(body)).toBe(400);
    }
    // A draft may be unfinished: no title, no photos yet.
    const draft = await call('POST', 'templates', { game: 'emergency', name: 'Draft', data: { points: [point([], { title: '', best: 0 })] } });
    expect(draft.status).toBe(201);
  });

  it('a teacher sees only their own templates; the owner sees all', async () => {
    const t = await call('POST', 'teachers', { name: 'Nino', amount: 30, unit: 'day' });
    const { key } = (await t.json()) as { key: string };
    const nino = { Authorization: `Bearer ${key}` };
    const mine = await newTemplate(nino);
    const owners = await newTemplate();
    const list = async (h: Record<string, string>) =>
      ((await (await call('GET', 'templates', undefined, h)).json()) as { templates: { id: string }[] }).templates.map((x) => x.id).sort();
    expect(await list(nino)).toEqual([mine.id]);
    expect(await list(auth)).toEqual([mine.id, owners.id].sort());
    expect((await call('GET', `templates/${owners.id}`, undefined, nino)).status).toBe(404);
    expect((await upload(owners.id, jpeg(), nino)).status).toBe(404);
    expect((await call('DELETE', `templates/${owners.id}`, undefined, nino)).status).toBe(404);
    // Nor can a session be made from someone else's template.
    await call('PATCH', `templates/${owners.id}`, { data: { points: [point(owners.photos)] } });
    const session = await call('POST', 'sessions', { name: 'X', game: 'emergency', emergency: { template: owners.id } }, nino);
    expect(session.status).toBe(400);
    expect(await session.json()).toEqual({ error: 'no_template' });
  });

  it('templates of a teacher deleted by the nightly job go with their photos', async () => {
    const { deleteOldTeachers, KEEP_SEC } = await import('../src/retention');
    const t = await call('POST', 'teachers', { name: 'Gone', amount: 1, unit: 'day' });
    const { key } = (await t.json()) as { key: string };
    const { id } = await newTemplate({ Authorization: `Bearer ${key}` });
    const later = Math.floor(Date.now() / 1000) + 2 * 86400 + KEEP_SEC;
    expect(await deleteOldTeachers(env, later)).toBe(1);
    expect(await env.DB.prepare('SELECT id FROM templates WHERE id = ?').bind(id).first()).toBeNull();
    expect((await env.AREAS.list({ prefix: `photos/${id}/` })).objects).toHaveLength(0);
  });
});

describe('112 game', () => {
  async function newGame(over: Record<string, unknown> = {}) {
    const { id, photos } = await newTemplate();
    const points = [point(photos, over), point(photos.slice(0, 2), { format: 'utm', best: 0, lat: 42.6576, lon: 44.6419 })];
    expect((await call('PATCH', `templates/${id}`, { data: { points } })).status).toBe(200);
    const res = await call('POST', 'sessions', { name: '112', game: 'emergency', emergency: { template: id } });
    return { res, id, photos };
  }
  const answer = (photo: string, over: Record<string, unknown> = {}) => ({
    coords: '41°42.906′ N, 44°49.626′ E',
    at: [41.7151, 44.8271],
    kind: 'injury',
    people: 2,
    injured: true,
    landmark: 'below the TV tower',
    photo,
    ...over,
  });
  const play = (token: string, a: unknown, round = 0, participantId = sid()) =>
    call('POST', 'submit', { token, submissionId: sid(), participantId, answer: a, lat: 41.7, lon: 44.8, round }, {});

  it('the student sees the scenario and shuffled photos, not the facts, best photo or notes', async () => {
    const { res, photos } = await newGame();
    expect(res.status).toBe(201);
    const { token } = (await res.json()) as { token: string };
    const joined = (await (await call('POST', 'join', { token }, {})).json()) as { game: string; settings: { points: Record<string, unknown>[] } };
    expect(joined.game).toBe('emergency');
    const p = joined.settings.points[0];
    expect(Object.keys(p).sort()).toEqual(['format', 'lat', 'lon', 'photos', 'text', 'title']);
    expect([...(p.photos as string[])].sort()).toEqual([...photos].sort());
    expect(JSON.stringify(joined)).not.toContain('note 1');
    expect(JSON.stringify(joined)).not.toMatch(/"(facts|best|notes|order)"/);
  });

  it('scores distance, format, message and photo; the first answer counts', async () => {
    const { res, photos } = await newGame();
    const { token, session } = (await res.json()) as { token: string; session: { id: string } };
    const full = await play(token, answer(photos[1]), 0, 'emergency-player-1');
    expect(await full.json()).toMatchObject({
      score: 100,
      truth: [41.7151, 44.8271],
      best: photos[1],
      facts: { kind: 'injury', people: 2, injured: true },
      notes: { [photos[0]]: 'note 0', [photos[1]]: 'note 1' },
    });
    expect(await (await play(token, answer(photos[0]), 0, 'emergency-player-1')).json()).toMatchObject({ duplicate: true, score: 100 });
    // 500 m north, in dd instead of dm, one person wrong, no landmark, the wrong photo: 20 + 0 + 10 + 0.
    const poor = answer(photos[0], { coords: '41.71960, 44.82710', at: [41.7196, 44.8271], people: 1, landmark: '' });
    expect(await (await play(token, poor)).json()).toMatchObject({ score: 30 });
    // Coordinates the app couldn't read: no distance points, still the rest.
    expect(await (await play(token, answer(photos[1], { coords: 'by the tower', at: null }))).json()).toMatchObject({ score: 40 });
    // The second point asks for UTM and has two photos.
    const utm = answer(photos[0], { coords: '38T 470650 4722855', at: [42.6576, 44.6419] });
    expect(await (await play(token, utm, 1)).json()).toMatchObject({ score: 100 });
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { answer: { coords: string } }[] };
    expect(rows.responses.map((r) => r.answer.coords)).toContain('38T 470650 4722855');
  });

  it('refuses unfinished templates, missing photos and bad answers', async () => {
    expect((await (await newGame({ title: '' })).res.json())).toEqual({ error: 'template_unfinished' });
    const { id, photos } = await newTemplate();
    await call('PATCH', `templates/${id}`, { data: { points: [point(photos)] } });
    await call('DELETE', `templates/${id}/photos/${photos[0]}`);
    const missing = await call('POST', 'sessions', { name: '112', game: 'emergency', emergency: { template: id } });
    expect(await missing.json()).toEqual({ error: 'template_photos' });
    expect((await call('POST', 'sessions', { name: '112', game: 'emergency', emergency: { template: 'nope' } })).status).toBe(400);

    const { res, photos: ok } = await newGame();
    const { token } = (await res.json()) as { token: string };
    for (const a of [
      null,
      answer(ok[1], { coords: 'x'.repeat(81) }),
      answer(ok[1], { at: [41.7] }),
      answer(ok[1], { kind: 'alien' }),
      answer(ok[1], { people: 100 }),
      answer(ok[1], { injured: 'yes' }),
      answer(ok[1], { landmark: 'x'.repeat(121) }),
      answer('0000000000000000'),
    ]) {
      expect((await play(token, a)).status, JSON.stringify(a)).toBe(400);
    }
    expect((await play(token, answer(ok[1]), 2)).status).toBe(400);
  });

  it('survives backup and restore with its photo order', async () => {
    const { res, photos } = await newGame();
    const { session, token } = (await res.json()) as { session: { id: string }; token: string };
    await play(token, answer(photos[1]));
    const before = (await (await call('POST', 'join', { token }, {})).json()) as { settings: unknown };
    const file = (await (await call('GET', `backup?session=${session.id}`)).json()) as Record<string, unknown>;
    await call('DELETE', `sessions/${session.id}`);
    expect((await call('POST', 'restore', file)).status).toBe(200);
    const rows = (await (await call('GET', `sessions/${session.id}/responses`)).json()) as { responses: { score: number }[] };
    expect(rows.responses[0].score).toBe(100);
    const restored = await env.DB.prepare('SELECT settings FROM sessions WHERE id = ?').bind(session.id).first<{ settings: string }>();
    expect((JSON.parse(restored!.settings) as { order: unknown }).order).toEqual(
      ((before.settings as { points: { photos: string[] }[] }).points.map((p) => p.photos.map((x) => photos.indexOf(x)))),
    );
  });
});
