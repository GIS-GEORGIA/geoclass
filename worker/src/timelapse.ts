// Satellite time-lapse frames, built by tool/timelapse/build_timelapse.py and kept in R2.
//
//   GET /timelapse/catalog.json                 the sites and their years; changes when a site is added
//   GET /timelapse/<id>/<version>/site.json     the grid, the frames (date, sensor, resolution), attribution
//   GET /timelapse/<id>/<version>/<year>.jpg    one frame
//
// A new build gets a new version, so versioned files never change and are cached for a year.
// Anything else under /timelapse/ is a 404: only these names are looked up, never a path taken as is.

const CATALOG = /^\/timelapse\/catalog\.json$/;
const FILE = /^\/timelapse\/([a-z0-9-]{1,40})\/(\d{1,4})\/(site\.json|(?:19|20)\d\d\.jpg)$/;

const YEAR = 'public, max-age=31536000, immutable';
const FIVE_MINUTES = 'public, max-age=300';

export const TIMELAPSE_CATALOG = 'timelapse/catalog.json';

function notFound(): Response {
  return new Response('not found', {
    status: 404,
    headers: { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
  });
}

/** The R2 key for a request path, or null when the path isn't one of the known files. */
export function timelapseKey(pathname: string): string | null {
  if (CATALOG.test(pathname)) return TIMELAPSE_CATALOG;
  const m = FILE.exec(pathname);
  return m ? `timelapse/${m[1]}/${Number(m[2])}/${m[3]}` : null;
}

export async function serveTimelapse(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  const key = timelapseKey(url.pathname);
  if (!key) return notFound();
  const object = await env.AREAS.get(key);
  if (!object) return notFound();
  const image = key.endsWith('.jpg');
  return new Response(request.method === 'HEAD' ? null : object.body, {
    headers: {
      'Content-Type': image ? 'image/jpeg' : 'application/json; charset=utf-8',
      'Cache-Control': key === TIMELAPSE_CATALOG ? FIVE_MINUTES : YEAR,
      'X-Content-Type-Options': 'nosniff',
      'Content-Security-Policy': "default-src 'none'",
      // The Android app reads these too; nothing here is private.
      'Access-Control-Allow-Origin': '*',
      ETag: object.httpEtag,
    },
  });
}
