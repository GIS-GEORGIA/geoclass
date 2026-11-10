// Downloads the OpenStreetMap boundaries that tool/plate_shapes.json names by "osm" (a relation id)
// and writes them as GeoJSON for tool/build_plates.mjs:
//
//   node tool/fetch_osm.mjs osm_boundaries.geojson
//
// Uses the public Overpass API once, when the plates are rebuilt; the app itself never calls it.
// OSM data is © OpenStreetMap contributors, ODbL.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const here = dirname(new URL(import.meta.url).pathname);
const target = process.argv[2];
if (!target) {
  console.error('usage: node tool/fetch_osm.mjs osm_boundaries.geojson');
  process.exit(1);
}
const ids = JSON.parse(readFileSync(resolve(here, 'plate_shapes.json'), 'utf8'))
  .filter((s) => s.osm)
  .map((s) => s.osm);

const query = `[out:json][timeout:300];relation(id:${ids.join(',')});out geom;`;
const response = await fetch('https://overpass-api.de/api/interpreter', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': 'GeoClass-build-tool/1.0 (+https://github.com/GIS-GEORGIA/geoclass)',
  },
  body: new URLSearchParams({ data: query }),
});
if (!response.ok) throw new Error(`Overpass: ${response.status} ${await response.text()}`);
const { elements } = await response.json();

const key = ([lon, lat]) => `${lon},${lat}`;

/** Joins a relation's outer ways end to end into closed rings. */
function outerRings(relation) {
  const pieces = relation.members
    .filter((m) => m.type === 'way' && m.role !== 'inner' && m.geometry)
    .map((m) => m.geometry.map((p) => [p.lon, p.lat]));
  const rings = [];
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
    if (key(ring[0]) === key(ring[ring.length - 1]) && ring.length >= 4) rings.push(ring);
    else console.warn(`relation ${relation.id}: a ring doesn't close, left out`);
  }
  return rings;
}

const features = elements
  .filter((e) => e.type === 'relation')
  .map((r) => ({
    type: 'Feature',
    properties: { osm: r.id, name: r.tags?.name },
    geometry: { type: 'MultiPolygon', coordinates: outerRings(r).map((ring) => [ring]) },
  }));
const missing = ids.filter((id) => !features.some((f) => f.properties.osm === id));
if (missing.length) console.warn(`not found: ${missing.join(', ')}`);
writeFileSync(target, JSON.stringify({ type: 'FeatureCollection', features }));
console.log(`${features.length} boundaries → ${target}`);
