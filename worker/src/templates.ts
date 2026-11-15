// Templates: what a teacher prepares once and makes sessions from again and again (the 112 game's points,
// scenarios and photos). Kept in D1 (migrations/0013_templates.sql); the photos in R2 under
// photos/<template id>/<photo id>.jpg, deleted with their template.
//
//   GET    /api/templates?game=emergency       the actor's templates (the 112 and time-lapse games) (the owner's: all), without their data
//   GET    /api/templates/:id                  one template with its data
//   POST   /api/templates                      { game, name, data } -> { template }
//   PATCH  /api/templates/:id                  { name?, data? }
//   DELETE /api/templates/:id                  the template and its photos
//   POST   /api/templates/:id/photos           a JPEG as the body (made small by the app) -> { id }
//   DELETE /api/templates/:id/photos/:photo
//   GET    /photos/<template id>/<photo id>.jpg  public: a student's app shows them; the ids can't be guessed
//
// A template's data is checked loosely when saved (a draft may be unfinished) and fully when a session is
// made from it (games/emergency.ts).

import { HttpError } from './validate';
import { readTemplateData } from './games/emergency';
import { readTemplateData as readTimelapseData } from './games/timelapse';

export type Owner = { admin: boolean; id: string | null };

const MAX_TEMPLATES_PER_TEACHER = 50;
export const MAX_TEMPLATE_BYTES = 32 * 1024;
export const MAX_PHOTO_BYTES = 400 * 1024;
const MAX_PHOTOS_PER_TEMPLATE = 40;
const TEMPLATE_ID = /^[0-9a-f-]{36}$/;
const PHOTO_ID = /^[0-9a-f]{16}$/;
const PHOTO_PATH = /^\/photos\/([0-9a-f-]{36})\/([0-9a-f]{16})\.jpg$/;

/** The games that have templates, and how each checks a template's data as saved. */
const READERS: Record<string, (raw: unknown) => unknown> = { emergency: readTemplateData, timelapse: (raw) => readTimelapseData(raw) };
/** A new template's data when none is sent; a game without one needs its data from the start (the site). */
const EMPTY: Record<string, unknown> = { emergency: { points: [] } };

type TemplateRow = { id: string; teacher_id: string | null; game: string; name: string; data: string; created_at: number; updated_at: number };

const nowSec = () => Math.floor(Date.now() / 1000);

function templateJson(t: TemplateRow, withData: boolean): Record<string, unknown> {
  return {
    id: t.id,
    game: t.game,
    name: t.name,
    createdAt: t.created_at,
    updatedAt: t.updated_at,
    ...(withData ? { data: JSON.parse(t.data) } : {}),
  };
}

function cleanName(v: unknown): string {
  const name = typeof v === 'string' ? v.trim() : '';
  if (!name || name.length > 80) throw new HttpError(400, 'bad_name');
  return name;
}

function cleanData(game: string, v: unknown): string {
  const data = JSON.stringify(READERS[game](v));
  if (data.length > MAX_TEMPLATE_BYTES) throw new HttpError(413, 'too_large');
  return data;
}

/** A template the actor may touch: any for the owner, only their own for a teacher. Someone else's is a 404. */
async function templateOr404(env: Env, id: string, owner: Owner): Promise<TemplateRow> {
  if (!TEMPLATE_ID.test(id)) throw new HttpError(404, 'not_found');
  const t = await env.DB.prepare('SELECT * FROM templates WHERE id = ? AND (? = 1 OR teacher_id = ?)')
    .bind(id, owner.admin ? 1 : 0, owner.id ?? '')
    .first<TemplateRow>();
  if (!t) throw new HttpError(404, 'not_found');
  return t;
}

export const photoKey = (template: string, photo: string) => `photos/${template}/${photo}.jpg`;

/** Every photo of a template, as R2 keys. */
async function photoKeys(env: Env, template: string): Promise<string[]> {
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.AREAS.list({ prefix: `photos/${template}/`, cursor });
    keys.push(...page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return keys;
}

/** Deletes templates and their photos. */
export async function deleteTemplates(env: Env, ids: string[]): Promise<void> {
  for (const id of ids) {
    const keys = await photoKeys(env, id);
    for (let i = 0; i < keys.length; i += 1000) await env.AREAS.delete(keys.slice(i, i + 1000));
    await env.DB.prepare('DELETE FROM templates WHERE id = ?').bind(id).run();
  }
}

type Json = (data: unknown, status?: number) => Response;
type ReadBody = <T>(request: Request, maxBytes?: number) => Promise<T>;

/** The /api/templates calls. parts: the path after /api/ ("templates", id, "photos", photo id). */
export async function templatesRoute(
  env: Env,
  request: Request,
  url: URL,
  parts: string[],
  owner: Owner,
  json: Json,
  readBody: ReadBody,
): Promise<Response> {
  const [, id, child, photo] = parts;
  const { method } = request;
  if (!id) {
    if (method === 'GET') {
      const game = url.searchParams.get('game');
      const { results } = await env.DB.prepare(
        `SELECT id, teacher_id, game, name, '{}' AS data, created_at, updated_at FROM templates
         WHERE (? = 1 OR teacher_id = ?) AND (? IS NULL OR game = ?) ORDER BY updated_at DESC`,
      )
        .bind(owner.admin ? 1 : 0, owner.id ?? '', game, game)
        .all<TemplateRow>();
      return json({ templates: results.map((t) => templateJson(t, false)) });
    }
    if (method === 'POST') {
      const body = await readBody<{ game?: unknown; name?: unknown; data?: unknown }>(request, MAX_TEMPLATE_BYTES + 1024);
      if (typeof body.game !== 'string' || !Object.hasOwn(READERS, body.game)) throw new HttpError(400, 'bad_game');
      const name = cleanName(body.name);
      const data = cleanData(body.game, body.data ?? EMPTY[body.game]);
      const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM templates WHERE teacher_id IS ?').bind(owner.id).first<{ n: number }>();
      if ((count?.n ?? 0) >= MAX_TEMPLATES_PER_TEACHER) throw new HttpError(409, 'too_many_templates');
      const now = nowSec();
      const tid = crypto.randomUUID();
      await env.DB.prepare('INSERT INTO templates (id, teacher_id, game, name, data, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
        .bind(tid, owner.id, body.game, name, data, now, now)
        .run();
      return json({ template: templateJson(await templateOr404(env, tid, owner), true) }, 201);
    }
    throw new HttpError(404, 'not_found');
  }
  const t = await templateOr404(env, id, owner);
  if (!child) {
    if (method === 'GET') return json({ template: templateJson(t, true) });
    if (method === 'PATCH') {
      const body = await readBody<{ name?: unknown; data?: unknown }>(request, MAX_TEMPLATE_BYTES + 1024);
      if (body.name === undefined && body.data === undefined) throw new HttpError(400, 'nothing_to_update');
      const name = body.name === undefined ? t.name : cleanName(body.name);
      const data = body.data === undefined ? t.data : cleanData(t.game, body.data);
      await env.DB.prepare('UPDATE templates SET name = ?, data = ?, updated_at = ? WHERE id = ?').bind(name, data, nowSec(), id).run();
      return json({ template: templateJson(await templateOr404(env, id, owner), true) });
    }
    if (method === 'DELETE') {
      await deleteTemplates(env, [id]);
      return json({ ok: true });
    }
  }
  if (child === 'photos') {
    if (!photo && method === 'POST') {
      const declared = Number(request.headers.get('content-length') ?? '0');
      if (declared > MAX_PHOTO_BYTES) throw new HttpError(413, 'too_large');
      const bytes = new Uint8Array(await request.arrayBuffer());
      if (bytes.length > MAX_PHOTO_BYTES) throw new HttpError(413, 'too_large');
      // A JPEG starts FF D8 FF: nothing else is kept, so nothing else can be served from here.
      if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) throw new HttpError(400, 'bad_photo');
      if ((await photoKeys(env, id)).length >= MAX_PHOTOS_PER_TEMPLATE) throw new HttpError(409, 'too_many_photos');
      const pid = [...crypto.getRandomValues(new Uint8Array(8))].map((b) => b.toString(16).padStart(2, '0')).join('');
      await env.AREAS.put(photoKey(id, pid), bytes, { httpMetadata: { contentType: 'image/jpeg' } });
      return json({ id: pid }, 201);
    }
    if (photo && method === 'DELETE') {
      if (!PHOTO_ID.test(photo)) throw new HttpError(404, 'not_found');
      await env.AREAS.delete(photoKey(id, photo));
      return json({ ok: true });
    }
  }
  throw new HttpError(404, 'not_found');
}

function notFound(): Response {
  return new Response('not found', {
    status: 404,
    headers: { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
  });
}

/** GET /photos/<template>/<photo>.jpg: a photo never changes under its id, so it is cached for a year. */
export async function servePhoto(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  const m = PHOTO_PATH.exec(url.pathname);
  if (!m) return notFound();
  const object = await env.AREAS.get(photoKey(m[1], m[2]));
  if (!object) return notFound();
  return new Response(request.method === 'HEAD' ? null : object.body, {
    headers: {
      'Content-Type': 'image/jpeg',
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'none'",
      'Access-Control-Allow-Origin': '*',
      ETag: object.httpEtag,
    },
  });
}
