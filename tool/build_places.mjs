// Builds assets/places.txt and assets/countries.json for the offline place search.
// Input: GeoNames dumps (CC BY 4.0) from https://download.geonames.org/export/dump/
//   node tool/build_places.mjs <cities15000.txt> <GE.txt>
import { readFileSync, writeFileSync } from 'node:fs';

const [citiesPath, georgiaPath] = process.argv.slice(2);
if (!citiesPath || !georgiaPath) {
  console.error('usage: build_places.mjs <cities15000.txt> <GE.txt>');
  process.exit(1);
}

const GEORGIAN = /^[Ⴀ-ჿ\s-]+$/;

// Georgia also gets villages and natural features, not only large cities.
const GEORGIA_FEATURES = new Set(['P', 'T', 'H', 'L', 'S']);
const GEORGIA_CODES = new Set(['PPL', 'PPLA', 'PPLA2', 'PPLC', 'PPLL', 'MT', 'PK', 'PASS', 'VAL', 'LK', 'RSV', 'STM', 'WTRF', 'CAVE', 'MNMT', 'CSTL', 'RUIN', 'MSTY', 'CH', 'PRK', 'RGN']);

const places = new Map();

function read(path, keep) {
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line) continue;
    const f = line.split('\t');
    const [id, name, , alternates, lat, lon, featureClass, featureCode, country] = f;
    const population = Number(f[14]) || 0;
    if (!keep(featureClass, featureCode)) continue;
    const ka = (alternates ?? '').split(',').find((a) => GEORGIAN.test(a)) ?? '';
    places.set(id, { name, ka, country, lat: Number(lat).toFixed(3), lon: Number(lon).toFixed(3), population });
  }
}

read(citiesPath, () => true);
read(georgiaPath, (cls, code) => GEORGIA_FEATURES.has(cls) && GEORGIA_CODES.has(code));

const rows = [...places.values()].sort((a, b) => b.population - a.population);
const clean = (s) => s.replace(/[\t\n]/g, ' ');
writeFileSync(
  'assets/places.txt',
  rows.map((p) => [clean(p.name), clean(p.ka), p.country, p.lat, p.lon].join('\t')).join('\n') + '\n',
);

// Country names come from CLDR through Node's Intl data.
const en = new Intl.DisplayNames(['en'], { type: 'region' });
const ka = new Intl.DisplayNames(['ka'], { type: 'region' });
const countries = {};
for (const code of new Set(rows.map((p) => p.country))) {
  if (/^[A-Z]{2}$/.test(code)) countries[code] = [en.of(code), ka.of(code)];
}
writeFileSync('assets/countries.json', JSON.stringify(countries));

const withKa = rows.filter((p) => p.ka).length;
console.log(`${rows.length} places, ${withKa} with a Georgian name, ${Object.keys(countries).length} countries`);
