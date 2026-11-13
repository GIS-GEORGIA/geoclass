import { env, exports } from 'cloudflare:workers';
import { areaKey } from '../src/areas';
import { beforeAll, describe, expect, it } from 'vitest';

const get = (path: string, method = 'GET') => exports.default.fetch(`https://geoclass.test${path}`, { method });

// Two heights, 1234.5 m and no data, as UInt16 little-endian; stored gzip-compressed like dem.u16.gz.
const raw = new Uint8Array([0x39, 0x30, 0xff, 0xff]);
const gzip = async (bytes: Uint8Array) =>
  new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());

beforeAll(async () => {
  await env.AREAS.put('areas/catalog.json', JSON.stringify({ areas: [{ id: 'kazbegi', version: 1 }] }));
  await env.AREAS.put('areas/kazbegi/1/area.json', JSON.stringify({ id: 'kazbegi', width: 2, height: 1 }));
  await env.AREAS.put('areas/kazbegi/1/dem.u16.gz', await gzip(raw));
  await env.AREAS.put('areas/kazbegi/1/flow.u8.gz', await gzip(new Uint8Array([7, 255])));
  await env.AREAS.put('areas/kazbegi/1/watershed.json', JSON.stringify({ file: 'flow.u8.gz' }));
  await env.AREAS.put('areas/secret.txt', 'not an area file');
});

describe('area packages', () => {
  it('serves the catalog, cached only briefly because it changes', async () => {
    const res = await get('/areas/catalog.json');
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toBe('application/json; charset=utf-8');
    expect(res.headers.get('Cache-Control')).toBe('public, max-age=300');
    expect(await res.json()).toEqual({ areas: [{ id: 'kazbegi', version: 1 }] });
  });

  it('serves a versioned area file for a year', async () => {
    const res = await get('/areas/kazbegi/1/area.json');
    expect(res.status).toBe(200);
    expect(res.headers.get('Cache-Control')).toBe('public, max-age=31536000, immutable');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
    expect(res.headers.get('ETag')).toBeTruthy();
    expect(await res.json()).toEqual({ id: 'kazbegi', width: 2, height: 1 });
  });

  it('sends the grid as stored, marked gzip, so the client receives the raw heights', async () => {
    const res = await get('/areas/kazbegi/1/dem.u16.gz');
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Encoding')).toBe('gzip');
    expect(res.headers.get('Content-Type')).toBe('application/octet-stream');
    // fetch undoes the gzip, as a browser does: compressed once, not twice.
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(raw);
  });

  it('answers HEAD without a body', async () => {
    const res = await get('/areas/kazbegi/1/area.json', 'HEAD');
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('');
  });

  it('is a 404 for an area or version that does not exist', async () => {
    expect((await get('/areas/kazbegi/2/area.json')).status).toBe(404);
    expect((await get('/areas/mestia/1/dem.u16.gz')).status).toBe(404);
  });

  it('serves only the known file names, whatever else is in the bucket', async () => {
    for (const path of [
      '/areas/secret.txt',
      '/areas/',
      '/areas/kazbegi/1/',
      '/areas/kazbegi/1/other.json',
      '/areas/kazbegi/../secret.txt',
      '/areas/kazbegi/1/..%2F..%2Fsecret.txt',
      '/areas/%2e%2e/secret.txt',
      '/areas/Kazbegi/1/area.json',
      '/areas/kazbegi/x/area.json',
    ]) {
      const res = await get(path);
      expect(res.status, path).toBe(404);
      expect(await res.text(), path).not.toContain('not an area file');
    }
  });

  it('serves the flow directions like the grid, and their description', async () => {
    const res = await get('/areas/kazbegi/1/flow.u8.gz');
    expect(res.status).toBe(200);
    expect(res.headers.get('Cache-Control')).toBe('public, max-age=31536000, immutable');
    expect(res.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([7, 255]));
    expect(await (await get('/areas/kazbegi/1/watershed.json')).json()).toEqual({ file: 'flow.u8.gz' });
    expect(areaKey('/areas/kazbegi/1/flow.u8')).toBeNull();
  });

  it('refuses to change anything', async () => {
    for (const method of ['POST', 'PUT', 'DELETE']) {
      expect((await get('/areas/kazbegi/1/area.json', method)).status, method).toBe(405);
    }
    expect(await (await env.AREAS.get('areas/kazbegi/1/area.json'))?.text()).toContain('kazbegi');
  });

  it('maps paths to keys only for the known shapes', () => {
    expect(areaKey('/areas/catalog.json')).toBe('areas/catalog.json');
    expect(areaKey('/areas/kutaisi-rioni/01/dem.u16.gz')).toBe('areas/kutaisi-rioni/1/dem.u16.gz');
    expect(areaKey('/areas/a/1/area.json/x')).toBeNull();
    expect(areaKey('/areas/' + 'a'.repeat(41) + '/1/area.json')).toBeNull();
  });

  it('leaves the API as it was', async () => {
    expect((await get('/api/health')).status).toBe(200);
  });
});
