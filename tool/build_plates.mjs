// Builds assets/plates.json, the outlines hidden in the colour plates.
//
//   node tool/build_plates.mjs ne_50m_admin_0_countries.geojson
//
// The countries file is Natural Earth's (public domain), from
// https://github.com/nvkelso/natural-earth-vector/tree/master/geojson
// Each entry of tool/plate_shapes.json takes its outline from Natural Earth countries
// ("countries": ADM0_A3 codes, or "continent": a CONTINENT value), or from a GeoJSON file
// of your own ("file", WGS84, e.g. a municipality exported from QGIS).
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const here = dirname(new URL(import.meta.url).pathname);
const countriesFile = process.argv[2];
if (!countriesFile) {
  console.error('usage: node tool/build_plates.mjs ne_50m_admin_0_countries.geojson');
  process.exit(1);
}
const countries = JSON.parse(readFileSync(countriesFile, 'utf8')).features;
const shapes = JSON.parse(readFileSync(resolve(here, 'plate_shapes.json'), 'utf8'));

// Islands and pieces smaller than this share of the biggest piece are left out: as dots they are noise.
const MIN_PART = 0.03;
const TOLERANCE = 0.006; // simplification, in the [-1, 1] box

/** Outer rings of a Polygon or MultiPolygon. Holes don't show in a plate of dots. */
function rings(geometry) {
  if (geometry.type === 'Polygon') return [geometry.coordinates[0]];
  if (geometry.type === 'MultiPolygon') return geometry.coordinates.map((p) => p[0]);
  return [];
}

const mercator = ([lon, lat]) => [lon, (Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360)) * 180) / Math.PI];

function area(ring) {
  let a = 0;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) a += (ring[j][0] + ring[i][0]) * (ring[j][1] - ring[i][1]);
  return Math.abs(a / 2);
}

/** Douglas-Peucker on a closed ring: split at the point farthest from the first, so no span has zero length. */
function simplifyRing(ring, tolerance) {
  const open = ring.slice(0, -1);
  let far = 0;
  for (let i = 1; i < open.length; i++) {
    if (Math.hypot(open[i][0] - open[0][0], open[i][1] - open[0][1]) > Math.hypot(open[far][0] - open[0][0], open[far][1] - open[0][1])) far = i;
  }
  const first = simplify(open.slice(0, far + 1), tolerance);
  const second = simplify([...open.slice(far), open[0]], tolerance);
  return [...first, ...second.slice(1)];
}

function simplify(points, tolerance) {
  if (points.length < 3) return points;
  const keep = new Uint8Array(points.length);
  keep[0] = keep[points.length - 1] = 1;
  const stack = [[0, points.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = points[a];
    const [bx, by] = points[b];
    const len = Math.hypot(bx - ax, by - ay) || 1e-12;
    let worst = -1;
    let at = -1;
    for (let i = a + 1; i < b; i++) {
      const d = Math.abs((bx - ax) * (ay - points[i][1]) - (ax - points[i][0]) * (by - ay)) / len;
      if (d > worst) [worst, at] = [d, i];
    }
    if (worst > tolerance) {
      keep[at] = 1;
      stack.push([a, at], [at, b]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

function source(shape) {
  if (shape.file) return JSON.parse(readFileSync(resolve(here, shape.file), 'utf8')).features;
  const picked = countries.filter((f) =>
    shape.countries ? shape.countries.includes(f.properties.ADM0_A3) : f.properties.CONTINENT === shape.continent,
  );
  if (picked.length === 0) throw new Error(`${shape.id}: nothing in the countries file`);
  return picked;
}

const out = [];
for (const shape of shapes) {
  let parts = source(shape).flatMap((f) => rings(f.geometry));
  // Russia crosses 180°: its far east is moved next to the rest.
  if (shape.unwrap) parts = parts.map((r) => r.map(([lon, lat]) => [lon < 0 ? lon + 360 : lon, lat]));
  parts = parts.map((r) => r.map(mercator));
  const sizes = parts.map(area);
  const biggest = Math.max(...sizes);
  parts = shape.largestOnly ? [parts[sizes.indexOf(biggest)]] : parts.filter((_, i) => sizes[i] >= biggest * MIN_PART);

  const xs = parts.flat().map((p) => p[0]);
  const ys = parts.flat().map((p) => p[1]);
  const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const scale = 2 / Math.max(maxX - minX, maxY - minY);
  const cx = (minX + maxX) / 2;
  const cy = (minY + maxY) / 2;
  // Into [-1, 1], y down as on a screen.
  const polys = parts
    .map((r) => simplifyRing(r.map(([x, y]) => [(x - cx) * scale, -(y - cy) * scale]), TOLERANCE))
    .filter((r) => r.length >= 4)
    .map((r) => r.map(([x, y]) => [Math.round(x * 1000) / 1000, Math.round(y * 1000) / 1000]));
  out.push({ id: shape.id, ka: shape.ka, en: shape.en, group: shape.group, polys });
  console.log(shape.id.padEnd(16), `${polys.length} parts`, `${polys.reduce((n, p) => n + p.length, 0)} points`);
}

const target = resolve(here, '../assets/plates.json');
writeFileSync(target, JSON.stringify(out));
console.log(`${out.length} shapes, ${readFileSync(target).length} bytes → assets/plates.json`);
