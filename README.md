# GeoClass

Classroom geography games. The teacher shows a QR code, students answer anonymously on their phones, and the answers appear live on a map.

საკლასო გეოგრაფიული თამაშები. მასწავლებელი აჩვენებს QR კოდს, მოსწავლეები ტელეფონიდან ანონიმურად პასუხობენ, პასუხები კი პირდაპირ რუკაზე ჩნდება.

**Status:** Stage 1 of 4. The travel game works from QR code to live map.

| Stage | Contents | Status |
|---|---|---|
| 1 | Sessions, QR, "Where would you travel?", live map, layers, search, backup, reset | Done |
| 2 | Coordinates game (DD, DMS, UTM 37N/38N) | Planned |
| 3 | Aerial photo guessing game | Planned |
| 4 | Android release build for Google Play | Planned |

## Features

- Flutter app for Web (PWA), Android, Windows and Linux, from one codebase
- Georgian and English, light and dark themes
- Students need no account: no name, email or phone, only a random id made on the device
- Answers wait on the device when the connection drops, and are sent later without duplicates
- OpenStreetMap and OpenTopoMap base maps, layer control, opacity, marker clusters, lesson mode
- Place search bundled with the app, so searching calls no outside service
- Hide or delete an answer before the class sees it
- CSV, GeoJSON and JSON export, restore from backup, and reset per session

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

`npm run key` prints a teacher key and its hash. Put the hash in `worker/.dev.vars`:

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

`assets/places.tsv` comes from [GeoNames](https://www.geonames.org/) dumps `cities15000` and `GE`:

```bash
node tool/build_places.mjs cities15000.txt GE.txt
```

## Data and credits

- Map data © OpenStreetMap contributors (ODbL), [OpenTopoMap](https://opentopomap.org/about) (CC BY-SA). Base map addresses are in `lib/geo_map.dart`.
- Places: GeoNames (CC BY 4.0). Country names: Unicode CLDR.
- Font: Noto Sans Georgian (SIL OFL).

## License

MIT
