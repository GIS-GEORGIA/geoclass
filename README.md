# GeoClass

Classroom geography games. The teacher shows a QR code, students answer anonymously on their phones, and the answers appear live on a map.

საკლასო გეოგრაფიული თამაშები. მასწავლებელი აჩვენებს QR კოდს, მოსწავლეები ტელეფონიდან ანონიმურად პასუხობენ, პასუხები კი პირდაპირ რუკაზე ჩნდება.

**Status:** The travel, coordinates, aerial photo, coordinate detective, mapping and cards games work from QR code to live map. Live at https://geoclass.qgis.ge. The Android build is ready to publish, see [docs/play-store.md](docs/play-store.md).

| Stage | Contents | Status |
|---|---|---|
| 1 | Sessions, QR, "Where would you travel?", live map, layers, search, backup, reset | Done |
| 2 | Coordinates game (DD, DM, DMS, UTM 37N/38N), leaderboard, links to Google Maps and OpenStreetMap | Done |
| 3 | Aerial photo guessing game, from our own photos | Done |
| 4 | Android release build for Google Play | Built, not published |
| 5 | Mapping race: draw points, lines and polygons against a clock the teacher sets | Done |

## Features

- Flutter app for Web (PWA), Android, Windows and Linux, from one codebase
- Georgian and English, light and dark themes
- Students need no account: no name, email or phone, only a random id made on the device
- Answers wait on the device when the connection drops, and are sent later without duplicates
- OpenStreetMap and OpenTopoMap base maps, layer control, opacity, marker clusters, lesson mode
- Place search bundled with the app, so searching calls no outside service
- Hide or delete an answer before the class sees it
- CSV, GeoJSON and JSON export, restore from backup, and reset per session

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
flutter build web --release --no-web-resources-cdn --base-href /
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
flutter build web --release --no-web-resources-cdn --base-href /
npx wrangler deploy
```

Run the `flutter build` line from the repository root. Native apps use `https://geoclass.qgis.ge` unless built with `--dart-define=API_BASE=<url>`.

## Rebuilding the place data

`assets/places.txt` comes from [GeoNames](https://www.geonames.org/) dumps `cities15000` and `GE`:

```bash
node tool/build_places.mjs cities15000.txt GE.txt
```

## Data and credits

- Map data © OpenStreetMap contributors (ODbL), [OpenTopoMap](https://opentopomap.org/about) (CC BY-SA). Base map addresses are in `lib/geo_map.dart`.
- Outlines in the colour plates: Natural Earth (public domain); regions and municipalities of Georgia © OpenStreetMap contributors (ODbL).
- Places: GeoNames (CC BY 4.0). Country names: Unicode CLDR.
- Font: Noto Sans Georgian (SIL OFL).
- Font: Roboto, reduced to Latin, Greek, Cyrillic and punctuation (Apache 2.0, `assets/fonts/Roboto_LICENSE.txt`).
- The cat in the settings: "Loading cat" by Tasha Kostyuk, [LottieFiles](https://lottiefiles.com/free-animation/loading-cat-jXwKusdtpk), under the Lottie Simple License (`assets/lottie/LICENSE.txt`).

## License

MIT
