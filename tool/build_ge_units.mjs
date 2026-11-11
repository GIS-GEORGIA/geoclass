// Builds assets/ge_units.json, the pieces of the Georgia puzzle: regions and municipalities
// with their real coordinates, from OpenStreetMap through the public Overpass API:
//
//   node tool/build_ge_units.mjs
//
// The names and relation ids come from tool/plate_shapes.json (groups ge_region and ge_municipality).
// OSM data is © OpenStreetMap contributors, ODbL.
//
// Neighbours share their border ways in OSM. Each way is simplified once, before the rings are put
// together, so two neighbouring pieces keep exactly the same edge.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const here = dirname(new URL(import.meta.url).pathname);
const shapes = JSON.parse(readFileSync(resolve(here, 'plate_shapes.json'), 'utf8'));
const regions = shapes.filter((s) => s.group === 'ge_region');
const municipalities = shapes.filter((s) => s.group === 'ge_municipality');
// Tbilisi is a region and a municipality at once.
const tbilisi = regions.find((r) => r.id === 'ge_tbilisi');
municipalities.push({ id: 'ge_m_tbilisi', ka: tbilisi.ka, en: tbilisi.en, osm: tbilisi.osm });

// Parts of Georgia that OSM doesn't divide into Georgian regions or municipalities. They show on the board
// as one fixed area each, so the map is always the whole country.
const FIXED = [
  // OSM keeps the Tskhinvali region apart from the regions, as five de facto districts: joined here into one.
  { id: 'tskhinvali', ka: 'ცხინვალის რეგიონი', en: 'Tskhinvali Region', osm: [2027316, 2027318, 2027319, 2027320, 2537350] },
];

const TOLERANCE = 0.0025; // degrees, about 250 m: under a pixel even for one region on a phone
const ids = [...regions, ...municipalities].map((s) => s.osm).concat(FIXED.flatMap((f) => f.osm));

const query = `[out:json][timeout:300];relation(id:${[...new Set(ids)].join(',')});out geom;`;
const response = await fetch('https://overpass-api.de/api/interpreter', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': 'GeoClass-build-tool/1.0 (+https://github.com/GIS-GEORGIA/geoclass)',
  },
  body: new URLSearchParams({ data: query }),
});
if (!response.ok) throw new Error(`Overpass: ${response.status} ${await response.text()}`);
const relations = new Map((await response.json()).elements.filter((e) => e.type === 'relation').map((r) => [r.id, r]));

/** Douglas-Peucker with both ends kept, so simplified ways still join. */
function simplify(points) {
  if (points.length < 3) return points;
  const keep = new Uint8Array(points.length);
  keep[0] = keep[points.length - 1] = 1;
  const stack = [[0, points.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const [ax, ay] = points[a];
    const [bx, by] = points[b];
    const len = Math.hypot(bx - ax, by - ay);
    let worst = -1;
    let at = -1;
    for (let i = a + 1; i < b; i++) {
      const [px, py] = points[i];
      const d = len === 0 ? Math.hypot(px - ax, py - ay) : Math.abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len;
      if (d > worst) [worst, at] = [d, i];
    }
    if (worst > TOLERANCE) {
      keep[at] = 1;
      stack.push([a, at], [at, b]);
    }
  }
  return points.filter((_, i) => keep[i]);
}

const ways = new Map(); // way id → simplified points, the same for every relation that uses the way
const key = ([lon, lat]) => `${lon},${lat}`;

function wayPoints(member) {
  if (!ways.has(member.ref)) {
    // Degrees of longitude are shorter here: scaled, so the tolerance is about the same both ways.
    const k = Math.cos((42 * Math.PI) / 180);
    const scaled = member.geometry.map((p) => [p.lon * k, p.lat]);
    const kept = new Set(simplify(scaled).map(key));
    ways.set(member.ref, member.geometry.filter((p) => kept.has(key([p.lon * k, p.lat]))).map((p) => [p.lon, p.lat]));
  }
  return ways.get(member.ref);
}

/** Joins a relation's ways end to end into closed rings, outer and inner alike: pieces are filled even-odd. */
function rings(relationId) {
  const relation = relations.get(relationId);
  if (!relation) throw new Error(`relation ${relationId} not found`);
  const pieces = relation.members.filter((m) => m.type === 'way' && m.geometry).map((m) => wayPoints(m));
  const out = [];
  while (pieces.length) {
    let ring = pieces.shift();
    let grown = true;
    while (key(ring[0]) !== key(ring[ring.length - 1]) && grown) {
      grown = false;
      for (let i = 0; i < pieces.length; i++) {
        const p = pieces[i];
        const end = key(ring[ring.length - 1]);
        if (key(p[0]) === end) ring = ring.concat(p.slice(1));
        else if (key(p[p.length - 1]) === end) ring = ring.concat(p.slice(0, -1).reverse());
        else continue;
        pieces.splice(i, 1);
        grown = true;
        break;
      }
    }
    if (key(ring[0]) !== key(ring[ring.length - 1])) {
      console.warn(`relation ${relationId}: a ring doesn't close, left out`);
      continue;
    }
    if (ring.length >= 4) out.push(ring.slice(0, -1).map(([lon, lat]) => [Math.round(lon * 1e4) / 1e4, Math.round(lat * 1e4) / 1e4]));
  }
  if (out.length === 0) throw new Error(`relation ${relationId}: no rings`);
  return out;
}

function inside([x, y], ring) {
  let c = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) c = !c;
  }
  return c;
}
const inRings = (pt, rs) => rs.reduce((c, r) => c !== inside(pt, r), false);

const regionRings = new Map(regions.map((r) => [r.id, rings(r.osm)]));

/** The region a municipality lies in: most of a grid of its inner points fall in it. */
function regionOf(rs) {
  const pts = rs.flat();
  const [x0, x1] = [Math.min(...pts.map((p) => p[0])), Math.max(...pts.map((p) => p[0]))];
  const [y0, y1] = [Math.min(...pts.map((p) => p[1])), Math.max(...pts.map((p) => p[1]))];
  const votes = new Map();
  for (let i = 1; i < 12; i++) {
    for (let j = 1; j < 12; j++) {
      const pt = [x0 + ((x1 - x0) * i) / 12, y0 + ((y1 - y0) * j) / 12];
      if (!inRings(pt, rs)) continue;
      for (const [id, r] of regionRings) if (inRings(pt, r)) votes.set(id, (votes.get(id) ?? 0) + 1);
    }
  }
  return [...votes].sort((a, b) => b[1] - a[1])[0]?.[0];
}

const out = {
  regions: regions.map((r) => ({ id: r.id, ka: r.ka, en: r.en, rings: regionRings.get(r.id) })),
  municipalities: municipalities.map((m) => {
    const rs = rings(m.osm);
    const region = m.id === 'ge_m_tbilisi' ? 'ge_tbilisi' : regionOf(rs);
    if (!region) throw new Error(`${m.id}: in no region`);
    return { id: m.id, ka: m.ka, en: m.en, region, rings: rs };
  }),
  fixed: FIXED.map((f) => ({ id: f.id, ka: f.ka, en: f.en, rings: f.osm.flatMap((id) => rings(id)) })),
};

const target = resolve(here, '../assets/ge_units.json');
writeFileSync(target, JSON.stringify(out));
const count = (xs) => xs.reduce((n, x) => n + x.rings.reduce((m, r) => m + r.length, 0), 0);
console.log(`${out.regions.length} regions (${count(out.regions)} points), ${out.municipalities.length} municipalities (${count(out.municipalities)} points), ${out.fixed.length} fixed`);
for (const r of out.regions) console.log(`  ${r.id}: ${out.municipalities.filter((m) => m.region === r.id).length} municipalities`);
console.log(`${readFileSync(target).length} bytes → assets/ge_units.json`);
