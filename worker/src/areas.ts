// Elevation packages for the terrain games, built by tool/areas/build_area.py and kept in R2.
//
//   GET /areas/catalog.json                  the list of areas; changes when one is added
//   GET /areas/<id>/<version>/area.json      size, position, scale, attribution
//   GET /areas/<id>/<version>/dem.u16.gz     the height grid, stored gzip-compressed
//   GET /areas/<id>/<version>/watershed.json the flow directions' checksum and source (tool/areas/build_watershed.py)
//   GET /areas/<id>/<version>/flow.u8.gz     where water leaves each cell, stored gzip-compressed
//
// A new build gets a new version, so versioned files never change and are cached for a year.
// Anything else under /areas/ is a 404: only these names are looked up, never a path taken as is.

const CATALOG = /^\/areas\/catalog\.json$/;
const FILE = /^\/areas\/([a-z0-9-]{1,40})\/(\d{1,4})\/(area\.json|dem\.u16\.gz|watershed\.json|flow\.u8\.gz)$/;

const YEAR = 'public, max-age=31536000, immutable';
const FIVE_MINUTES = 'public, max-age=300';

function notFound(): Response {
  return new Response('not found', {
    status: 404,
    headers: { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
  });
}

/** The R2 key for a request path, or null when the path isn't one of the known files. */
export function areaKey(pathname: string): string | null {
  if (CATALOG.test(pathname)) return 'areas/catalog.json';
  const m = FILE.exec(pathname);
  return m ? `areas/${m[1]}/${Number(m[2])}/${m[3]}` : null;
}

export async function serveArea(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  const key = areaKey(url.pathname);
  if (!key) return notFound();
  const object = await env.AREAS.get(key);
  if (!object) return notFound();
  const grid = key.endsWith('.gz');
  const headers = new Headers({
    'Content-Type': grid ? 'application/octet-stream' : 'application/json; charset=utf-8',
    'Cache-Control': key === 'areas/catalog.json' ? FIVE_MINUTES : YEAR,
    'X-Content-Type-Options': 'nosniff',
    // The Android app reads these too; nothing here is private.
    'Access-Control-Allow-Origin': '*',
    ETag: object.httpEtag,
  });
  // The grid is stored compressed. The browser and the app's HTTP client undo the gzip themselves,
  // so they receive the raw grid. 'manual' stops the runtime from compressing it a second time.
  if (grid) headers.set('Content-Encoding', 'gzip');
  return new Response(request.method === 'HEAD' ? null : object.body, {
    headers,
    encodeBody: grid ? 'manual' : 'automatic',
  });
}
