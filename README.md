# GeoClass

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.24144115.svg)](https://doi.org/10.5281/zenodo.24144115) [![Release](https://img.shields.io/github/v/release/GIS-GEORGIA/geoclass)](https://github.com/GIS-GEORGIA/geoclass/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Classroom geography games. The teacher shows a QR code, students answer anonymously on their phones, and the answers appear live on a map.

საკლასო გეოგრაფიული თამაშები. მასწავლებელი აჩვენებს QR კოდს, მოსწავლეები ტელეფონიდან ანონიმურად პასუხობენ, პასუხები კი პირდაპირ რუკაზე ჩნდება.

GeoClass is a set of classroom geography games for students in grades 6–9. Students play on their own phones during the lesson, get used to online maps, learn the different ways of writing coordinates and train their memory, while the teacher sees the results at once and the class talks them over together.

GeoClass არის გეოგრაფიის საკლასო თამაშების კრებული VI–IX კლასის მოსწავლეებისთვის. მოსწავლეები გაკვეთილზე საკუთარ ტელეფონზე თამაშობენ, ეჩვევიან ონლაინ რუკებთან მუშაობას, სწავლობენ კოორდინატების სხვადასხვა ფორმას და ავარჯიშებენ მეხსიერებას. მასწავლებელი შედეგებს მაშინვე ხედავს და ისინი კლასთან ერთად განიხილება.

**Idea and development / იდეა და შემუშავება:** Giorgi Kapanadze, Associate Professor at the Business and Technology University (BTU) / გიორგი კაპანაძე, ბიზნესისა და ტექნოლოგიების უნივერსიტეტის (BTU) ასოცირებული პროფესორი.

**Status:** Nine games work from QR code to live map: travel, coordinates, aerial photo, mapping race, cards, coordinate detective, colour plates, map puzzle and map layout. Live at https://geoclass.qgis.ge. Version 1.0.0 is [released](https://github.com/GIS-GEORGIA/geoclass/releases/tag/v1.0.0) and archived on Zenodo ([10.5281/zenodo.24144115](https://doi.org/10.5281/zenodo.24144115)). The Android build is ready to publish, see [docs/play-store.md](docs/play-store.md).

| Stage | Contents | Status |
|---|---|---|
| 1 | Sessions, QR, "Where would you travel?", live map, layers, search, backup, reset | Done |
| 2 | Coordinates game (DD, DM, DMS, UTM 37N/38N), leaderboard, links to Google Maps and OpenStreetMap | Done |
| 3 | Aerial photo guessing game, from our own photos | Done |
| 4 | Android release build for Google Play | Built, not published |
| 5 | Mapping race: draw points, lines and polygons against a clock the teacher sets | Done |
| 6 | Cards game: find pairs of map cards against a clock | Done |
| 7 | Coordinate detective: read coordinates from a training picture, convert them, find and name the place | Done |
| 8 | Colour plates, with Georgia's regions and municipalities | Done |
| 9 | Privacy: ⓘ dialog, sessions deleted after 6 months, students erase their own answers | Done |
| 10 | Map puzzle: regions, municipalities or a jigsaw of the live map | Done |
| 11 | Map layout: colour by a legend, lay out the sheet, print an A4 PDF | Done |
| 12 | About text, citation (`CITATION.cff`, in-app dialog), release 1.0.0 with a Zenodo DOI | Done |

## Games

Every game runs as a session: the teacher creates it, shows the QR code, and students join on their own phones with no account. The teacher's screen fills in live.

| Game | What students do | What it practises |
|---|---|---|
| Where would you travel? | Put a point on the map and say why | Finding places on an online map, zoom and layers |
| Coordinates game | Find a place from its coordinates, or read the coordinates of a place | DD, DM, DMS and UTM; latitude and longitude |
| Aerial photo | Guess where a photo from above was taken | Reading the landscape, matching a photo to a map |
| Mapping race | Draw points, lines and polygons before the clock runs out | Drawing on a map, working against time |
| Cards | Find pairs of map cards that show the same place | Visual memory, recognising places |
| Coordinate detective | Read coordinates from a training picture, write them in another format, find the place and name it | Converting coordinates, careful reading, step-by-step reasoning |
| Colour plates | Find the region, country or continent hidden in a plate of coloured dots; the class answers aloud | Recognising shapes; why map colours matter for people who see colour differently |
| Map puzzle | Put Georgia together from its regions or municipalities | The shapes and positions of regions and municipalities |
| Map layout | Colour the units by a legend, place title, north arrow, legend, scale and grid, print on A4 | The parts of a map, scale, grids and care with detail |

All games teach working alone on a small problem and talking the results over with the class.

## Features

- Flutter app for Web (PWA), Android, Windows and Linux, from one codebase
- Georgian and English, light and dark themes
- Students need no account: no name, email or phone, only a random id made on the device
- Answers wait on the device when the connection drops, and are sent later without duplicates
- OpenStreetMap and OpenTopoMap base maps, layer control, opacity, marker clusters, lesson mode
- Place search bundled with the app, so searching calls no outside service
- Hide or delete an answer before the class sees it
- CSV, GeoJSON and JSON export, restore from backup, and reset per session
- A clock the teacher starts for timed games (mapping race, cards, map puzzle), and leaderboards by random nicknames
- Coordinate converter for students (DD, DM, DMS, UTM 37N/38N), which the teacher can turn off per task
- A4 PDF of a map layout sheet, made on the device
- Privacy ⓘ dialog on every page; sessions deleted after 6 months
- About text and a citation dialog (APA and BibTeX) in the settings

## The travel game

Students answer "Where would you travel?" by putting a point on the map and writing a short reason. The points appear on the teacher's map at once, in clusters when many are close. The teacher can hide or delete an answer before showing the map to the class.

## The mapping race

The teacher sets the task and a clock. Students draw points, lines or polygons on the map, for example their neighbourhood, before the time runs out. The drawings come together on the teacher's map and can be exported as GeoJSON.

## The coordinates game

The teacher picks random Georgian places, taps the map or types coordinates, up to 30 tasks. Each task is one of:

- **Coordinates → map:** the student sees coordinates and places a point on the map.
- **Map → coordinates:** the student sees a marked point and types its coordinates.

Coordinates are decimal degrees (DD), degrees and decimal minutes (DM), degrees-minutes-seconds (DMS) or rectangular UTM on the WGS84 datum. The map shows a matching grid. After each task the student sees the miss in metres, the score, both points in all three formats, and links to Google Maps and OpenStreetMap.

The score is 100 within 1 km, 50 at 10 km and 0 from 100 km, on a logarithmic scale. The Worker works it out from the coordinates, and only the first try at each task counts. The leaderboard shows nicknames like „ლურჯი მელა“ made from the random student id, so no name is asked for or stored.

## The aerial photo game

The student sees a photo, taps the map where they think it is, and is scored by distance as in the coordinates game. On the teacher's map the answer stays hidden until the eye button is pressed, so the page can be projected during play.

Photos come only from this repository, with no outside imagery service:

1. Put the files in `web/aerial/`. Use JPEG, PNG or WebP, with names of letters, digits, `-` and `_` only. About 1600 px wide and under 500 KB keeps them quick on phones.
2. List each one in `web/aerial/index.json`:

   ```json
   [
     { "file": "p01.jpg", "ka": "თბილისი", "en": "Tbilisi", "lat": 41.6938, "lon": 44.8015 }
   ]
   ```

3. Run `flutter test`, which names any mistake in the list, then build and deploy as usual.

Students' phones receive the photo names and coordinates so the app can score offline. A student who reads the page's network traffic could find them, and this is a classroom game, so that is accepted. Neutral file names like `p01.jpg` and photos without GPS data in the file avoid giving the answer away more easily.

## The coordinate detective

Each task is a picture the app draws: an educational fine receipt, plainly marked as a training sample, or a dashcam frame. It shows coordinates the teacher gives, in the format the teacher picks (DD, DM, DMS or UTM). Every other detail on it (number, date, speed, offence) is made up from a seed, the same for every student. There is no emblem, office, person, car or plate on either picture.

For each task the teacher also picks the format of the answer, which can differ from the one shown, and which questions to ask, all three by default:

- a) write the coordinates in the answer format (UTM as zone, X and Y). 100 points within 30 m, falling to 0 at 5 km.
- b) mark the place on the map, scored as in the coordinates game.
- c) name what is there. The teacher lists the accepted names; case, spaces and punctuation don't count.

Students can open a coordinate converter (DD, DM or DMS to every format, and UTM 37N/38N back to DD), unless the teacher turns it off for the task. Results show after each task. On the review screen the teacher can mark any answer "count as right" for a small slip, and undo it; the leaderboard counts it as 100 and the original score is kept.

## The cards game

Every student gets the same table of cards, two for each place, at different scales and, if the teacher wants, turned. They find the pairs against the teacher's clock. The ranking is pairs found, then fewer wrong tries, then whoever was sooner. The teacher also sees which pairs were found least and mixed up most.

The teacher chooses the pairs, how the cards are turned (not at all, quarter turns or any angle) and whether a north arrow shows on each card. With the arrow on, a card can be opened full screen and, in the Android app, turned by the phone's compass so its north points to the real north. The compass is not offered on the web, where phones report it unreliably. It stays on the device and is never sent.

Pictures come only from this repository, like the aerial photos:

1. Put the files in `web/cards/`, two for each place: the same place at two scales, north up. JPEG, PNG or WebP, names of letters, digits, `-` and `_` only, roughly square, about 800 px and under 200 KB each.
2. List each place in `web/cards/index.json`. `level` is how different the two scales are, 1 (the same) to 3, and only helps the teacher choose:

   ```json
   [
     { "a": "tbilisi-1.jpg", "b": "tbilisi-2.jpg", "ka": "თბილისი", "en": "Tbilisi", "level": 2 }
   ]
   ```

3. Run `flutter test`, which names any mistake in the list, then build and deploy as usual.

The cards screens carry the credit that OpenStreetMap and Tracestrack Topo require, because these pictures come from those two layers (Tracestrack's terms are CC BY 4.0). Each osm.org layer has its own terms, so pictures from another layer or source need `CardsCredit` in `lib/cards.dart` changed. Turn off labels when making them, or students will compare the names instead of the map. PNG keeps map lines sharper than JPEG.

The app turns the cards itself, so a place needs no rotated copies. Students' phones receive the file names of the chosen pairs, which say which cards match. This is a classroom game, so that is accepted; neutral names like `p01-1.jpg` and `p01-2.jpg` make it less obvious.

## Colour plates

Each plate is a circle of coloured dots with a shape hidden in it, in colours of about the same lightness, so the shape shows only by its hue, as on colour vision plates. The teacher chooses what to hide (regions of Georgia, municipalities of Georgia, continents, countries of the world; one or more), how many plates and the colours, and the app picks the plates at random.

It is a session like the others: students scan the QR code and see the plate the teacher shows on their own phone or tablet, while the teacher projects it from the laptop. The teacher moves the plates and shows the answer; the phones follow within a few seconds. Nobody sends an answer: the class says it aloud, together. Phones ask the server for the current plate every 3 seconds while the screen is on, and only ever get the plate on screen, not the ones to come.

It opens with a notice for the teacher to read aloud, which students also see: taking part is voluntary, the class answers together and nobody is asked alone, "I can't see it" is a normal answer, it is not a medical test, and nothing is collected. "Show the answer" fades the background and darkens the shape, so everyone can see it. It ends with a short explanation of colour vision and why map colours matter. On the teacher's screen the arrow keys or Page Up/Down move between plates, and Space or Enter shows the answer.

The plates are drawn by the app from outlines in `assets/plates.json`. To change the list, edit `tool/plate_shapes.json` and rebuild. Countries and continents come from Natural Earth's [`ne_50m_admin_0_countries.geojson`](https://github.com/nvkelso/natural-earth-vector/tree/master/geojson), Georgia's regions and municipalities from OpenStreetMap, downloaded once through the Overpass API:

```bash
node tool/fetch_osm.mjs osm_boundaries.geojson
```

```bash
node tool/build_plates.mjs ne_50m_admin_0_countries.geojson osm_boundaries.geojson
```

An entry takes `countries` (ADM0_A3 codes, joined into one shape), `continent`, `osm` (a relation id) or `file`: a GeoJSON of your own in WGS84, for example a municipality exported from QGIS, with the path relative to `tool/`. `largestOnly` keeps only the biggest piece (Akhmeta's winter pastures in Shiraki, for instance, would shrink the rest). Small islands are left out.

The municipalities are the ones Georgia governs today. In the occupied territories OpenStreetMap has the de facto districts rather than Georgia's municipalities, so they are left out; Abkhazia is among the regions.

## Map puzzle

Each student puts a map of Georgia together on their own phone, against the teacher's clock. The teacher chooses:

- **What it's made of:** the 12 regions; the municipalities of the whole country or of one region; or a classic jigsaw, 9 to 64 pieces cut from the map of Georgia or of a region.
- **Turned pieces:** not at all, quarter turns or any angle (steps of 30°). A tap turns a piece.
- **Help on the board:** the outline of every piece, only the outer border, or nothing.
- **Names** under the pieces, or not. A placed piece always shows its name.
- **Picture:** the live OpenStreetMap or OpenTopoMap map, or plain colours (neighbours never share one).

A piece is dragged up from the tray to the board and stays where it belongs if it lands near its place, turned the right way; otherwise it counts as a wrong placement and goes back. Every phone deals its own order and turns. The teacher sees who finished, how fast (from the start of the clock) and with how many wrong placements, and which pieces were hardest. The solved picture is hidden on the teacher's screen until asked for, so it can't be copied from the projector.

The app cuts the pieces itself, so every phone gets the same puzzle from a few settings; the map picture comes from the tiles at the right zoom (about 25 for all of Georgia), with the OSM credit always on screen. If the tiles don't load, the pieces are in plain colours.

The outlines are in `assets/ge_units.json`, from OpenStreetMap through the Overpass API, with the relation ids from `tool/plate_shapes.json`:

```bash
node tool/build_ge_units.mjs
```

Neighbouring units share their border ways in OSM; each way is simplified once, so neighbours keep exactly the same edge. OSM doesn't divide Abkhazia into Georgian municipalities, so in the municipality puzzle it is one piece, and Tbilisi is one too. The Tskhinvali Region, which OSM keeps apart as de facto districts, is on the board from the start as one area.

## Map layout

Each student gets Georgia's outline on an A4 landscape sheet, the regions (or one region's municipalities) drawn but blank, and a ready legend that gives every unit its own colour. They colour the units by the legend, put a title, north arrow, legend and scale bar on the page wherever they like (drag to move, the blue circle to resize), choose a 1° or 0.5° grid, hand the sheet in and print it as an A4 PDF.

The teacher chooses the area; the colours are dealt at random and can be dealt again. The legend is kept in the session, so the server scores each sheet itself: 70 for the colouring (in proportion), 6 each for the title (with text), north arrow, legend and scale bar on the page, and 6 for the grid. Handing in again replaces the sheet. The teacher sees every sheet, can open it large and download it as a PDF.

The scale bar and the numeric scale (1 : n on A4) are worked out from the map's Web Mercator scale at its middle latitude, so they hold for a print at 100 %. The PDF is the sheet drawn at about 200 dpi, made on the device with the [`pdf`](https://pub.dev/packages/pdf) package (Apache 2.0); `image` is kept below 4.6 because `pdf` 3.12 needs `archive` below 4.1. The outlines are those of the puzzle (`assets/ge_units.json`), and every sheet carries the OSM credit.

## Privacy and GDPR

GeoClass asks students for no name or contact; answers are linked only by a random code made on the device. What it keeps, why and for how long is in the privacy policy, `web/privacy/index.html`, written for the GDPR and the Law of Georgia on Personal Data Protection.

- Sessions and their answers are deleted automatically 6 months after they were made: a cron trigger in `worker/wrangler.jsonc` runs `deleteOld` every night. Change `KEEP_SEC` in `worker/src/retention.ts` and the policy together.
- A student can delete their own answers in a session from the ⓘ dialog on the student page (`POST /api/forget` with the session token and the device's random code). That also clears the session from the device.
- Cloudflare's request logs (`observability` in `worker/wrangler.jsonc`) are kept for up to 7 days; the policy says so.
- The app sets no cookies; browser storage holds only what the app needs.

## How it fits together

```
Flutter app ──HTTP──> Cloudflare Worker (worker/) ──> D1 (SQLite)
```

The same Worker also serves the web build, so the app and `/api` share one origin.

| Decision | Why |
|---|---|
| A **session** is the only grouping | One teacher, one list. A new class gets a new session and old ones stay. |
| **Teacher key** instead of a password | Free Workers allow 10 ms CPU per request, too little for slow password hashing. A long random key is safe with plain SHA-256. |
| **Only the QR token's hash** is stored | A leaked database doesn't reveal working links. The token itself stays on the teacher's device. Showing the QR on another device means creating a new one, which cancels the old one. |
| **Polling every 3 seconds** instead of WebSockets | Works the same on all platforms. An unchanged session costs one row read. Polling slows after 10 idle minutes and stops in a hidden tab. |
| **All writes go through the Worker** | Students can't read each other's answers. Answers are validated on the server, and unknown fields are dropped. |
| **One answer per student** | Sending again replaces the earlier answer. A retry with the same submission id stores nothing new. |

## Run locally

Needs Flutter and Node.js.

```bash
flutter pub get
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run --base-href /
cd worker
npm install
npm run key
```

`npm run key` prints a teacher key and its hash. The optional `TEACHER_KEY_HINT` secret is deliberately public: the sign-in page's small copy button gives it out, so it should be the key without its last characters, and the shorter it is, the harder the rest is to guess. Put the hash in `worker/.dev.vars`:

```
TEACHER_KEY_HASH=<hash>
```

Then create the local database and start the server:

```bash
npm run db:local
npm run dev
```

Open http://localhost:8787 and enter the teacher key. Phones on the same network need the computer's address, and offline mode needs HTTPS.

## Tests

```bash
flutter analyze
flutter test
cd worker && npm run check && npm test
```

## Deploy to Cloudflare

```bash
cd worker
npx wrangler d1 create geoclass
```

Put the printed id into `database_id` in `wrangler.jsonc`, then:

```bash
npx wrangler d1 migrations apply geoclass --remote
npx wrangler secret put TEACHER_KEY_HASH
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run --base-href /
npx wrangler deploy
```

Run the `flutter build` line from the repository root. The migrations in `worker/migrations` (0001 to 0009) add one game each; before applying a new one to the live database, keep a copy with `npx wrangler d1 export geoclass --remote --output <file>.sql`. Native apps use `https://geoclass.qgis.ge` unless built with `--dart-define=API_BASE=<url>`.

## Rebuilding the place data

`assets/places.txt` comes from [GeoNames](https://www.geonames.org/) dumps `cities15000` and `GE`:

```bash
node tool/build_places.mjs cities15000.txt GE.txt
```

## Data and credits

- Map data © OpenStreetMap contributors (ODbL), [OpenTopoMap](https://opentopomap.org/about) (CC BY-SA). Base map addresses are in `lib/geo_map.dart`.
- Outlines in the colour plates: Natural Earth (public domain); regions and municipalities of Georgia © OpenStreetMap contributors (ODbL). The same for the map puzzle (`assets/ge_units.json`).
- Places: GeoNames (CC BY 4.0). Country names: Unicode CLDR.
- Font: Noto Sans Georgian (SIL OFL).
- Font: Roboto, reduced to Latin, Greek, Cyrillic and punctuation (Apache 2.0, `assets/fonts/Roboto_LICENSE.txt`).
- The cat in the settings: "Cat playing animation" by Abdul Latif, [LottieFiles](https://lottiefiles.com/free-animation/cat-playing-animation-1cwXJbHzz7), under the Lottie Simple License (`assets/lottie/LICENSE.txt`).

## Citation · ციტირება

**Author · ავტორი:** Giorgi Kapanadze / გიორგი კაპანაძე ([ORCID 0009-0006-4193-5939](https://orcid.org/0009-0006-4193-5939))
**Affiliation · აფილიაცია:** Associate Professor, Business and Technology University (BTU) / ასოცირებული პროფესორი, ბიზნესისა და ტექნოლოგიების უნივერსიტეტი (BTU)

GeoClass შექმნილია VI–IX კლასის მოსწავლეებისთვის, გეოგრაფიის გაკვეთილზე თამაშით სწავლისთვის. თუ მას კვლევაში, სტატიაში ან სასწავლო მასალაში იყენებთ, გთხოვთ, მიუთითოთ. GitHub-ის „Cite this repository“ ღილაკი (`CITATION.cff`) APA და BibTeX ფორმატებს ავტომატურად გასცემს. იგივე ტექსტი აპშიც არის: პარამეტრები → ციტირება.

If you use GeoClass in research, a paper or teaching materials, please cite it. GitHub's "Cite this repository" button (`CITATION.cff`) gives a ready-made APA or BibTeX entry. The app shows the same under Settings → How to cite.

```bibtex
@software{kapanadze_geoclass_2026,
  author      = {Kapanadze, Giorgi},
  title       = {{GeoClass}: ინტერაქციული გეოგრაფიული თამაშები სკოლის მოსწავლეებისთვის / {Interactive Geography Games for School Students}},
  year        = {2026},
  version     = {1.0.0},
  publisher   = {Zenodo},
  institution = {{Business and Technology University (BTU)}},
  doi         = {10.5281/zenodo.24144115},
  url         = {https://doi.org/10.5281/zenodo.24144115}
}
```

Kapanadze, G. (2026). GeoClass: ინტერაქციული გეოგრაფიული თამაშები სკოლის მოსწავლეებისთვის / Interactive Geography Games for School Students (Version 1.0.0) [Computer software]. Zenodo. Business and Technology University (BTU). https://doi.org/10.5281/zenodo.24144115

## License

MIT
