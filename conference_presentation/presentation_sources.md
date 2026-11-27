# Source inventory

This file records the evidence for every factual statement in the slides. It was checked against the repository at commit `051e4ee` (main, 26 Nov 2026).

Status codes:
- **impl**: implemented in the repository.
- **rationale**: educational rationale.
- **hyp**: research hypothesis.
- **plan**: future evaluation plan.

Nothing in the slides reports measured learning outcomes, user numbers, schools, testimonials, awards, partnerships or certifications. No such data exists in the repository.

## Repository facts verified in code

| Claim | Evidence | Status |
|---|---|---|
| 18 games are registered: 9 core and 9 added after 1.0 | `lib/games/registry.dart` (`_order`), `docs/play-store.md` | impl |
| The nine core games and what each one practises | `README.md` § Games and the per-game sections | impl |
| The target age is grades 6–9 | `README.md`, `CITATION.cff` abstract | impl |
| Flow: session → QR → anonymous join → answers on the teacher's live map | `README.md` § How it fits together; real screenshots | impl |
| Flutter app → Cloudflare Worker → D1 (SQLite); polling every 3 s | `README.md` decision table; `worker/src/index.ts` | impl |
| No student account, name, e-mail or phone | `README.md` § Features; privacy dialog (screenshot); `web/privacy/index.html` | impl |
| Random id made on the device, new for every session | `lib/queue.dart` (`randomId`: `Random.secure()`, 18 bytes; `participantId`: per QR token) | impl |
| Optional nickname; automatic nicknames are made from the random id | `README.md` § coordinates game; `worker/src/index.ts` (`setNickname`) | impl |
| A student can erase their own answers | `worker/src/index.ts` (`forget`, `POST /api/forget`); `lib/queue.dart` (`forgetSessionOnDevice`) | impl |
| The teacher can hide or delete an answer | `worker/src/index.ts` (`updateResponse` with `hidden`, `deleteResponse`) | impl |
| Sessions and answers are deleted after 6 months | `worker/src/retention.ts` (`KEEP_SEC = 183 days`), cron `30 2 * * *` in `worker/wrangler.jsonc` | impl |
| Only the hash of the QR token is stored | `worker/src/index.ts` (`token_hash`, `sha256(token)`) | impl |
| Server-side validation; unknown fields are dropped | `worker/src/validate.ts`; `README.md` decision table | impl |
| No GPS, camera, cookies, ads or analytics | privacy dialog text; `README.md` § Privacy; `web/privacy/index.html` | impl |
| Request logs kept up to 7 days (mentioned in notes only) | `README.md` § Privacy and GDPR | impl |
| DD, DM, DMS and UTM 37N/38N on WGS 84, through proj4 | `lib/coords.dart` (`+proj=utm +zone=… +datum=WGS84`) | impl |
| Tbilisi example: DD 41.6938, 44.8015 → UTM 38N E 483 482, N 4 615 799 | Computed with pyproj (EPSG:4326 → EPSG:32638); DMS as the app shows it (screenshot) | impl |
| CSV, GeoJSON and JSON export; restore from backup | `README.md` § Features; `lib/export.dart`; `lib/mapping.dart` | impl |
| Base maps: OSM and OpenTopoMap, attribution always visible | `lib/geo_map.dart` | impl |
| Open data: Natural Earth, GeoNames, OSM boundaries | `README.md` § Data and credits | impl |
| Copernicus DEM GLO-30 for the terrain games | `tool/areas/build_area.py` header | impl |
| Landsat and Sentinel-2 imagery for the time-lapse (notes only) | `tool/timelapse/build_timelapse.py` header | impl |
| Web/PWA, Android, Windows and Linux from one codebase | `README.md` § Features; `android/`, `windows/`, `linux/`, `web/` | impl |
| The app shell is cached by a service worker; the API must be live | `web/sw.js` header comment | impl |
| Answers are queued and resent without duplicates | `lib/queue.dart`; `worker/src/index.ts` (`submit`: an existing `submissionId` returns `duplicate`) | impl |
| Android App Links open QR sessions | `web/.well-known/assetlinks.json`; `lib/main.dart` (`routePath`) | impl |
| MIT licence; Zenodo DOI 10.5281/zenodo.24144115 | `LICENSE`, `CITATION.cff` | impl |
| Colour plates are voluntary and send nothing | `README.md` § Colour plates; screenshot | impl |
| Coordinate detective uses a training document marked as a sample | `README.md` § The coordinate detective; phone screenshot | impl |

## Per-slide inventory

| # | Main claim | Evidence | Status |
|---|---|---|---|
| 1 | Title, conference, organisers, anniversary | Conference details as given by the organisers; author left as a placeholder | — |
| 2 | Geography needs spatial thinking, map literacy, reasoning and digital competencies | NRC 2006; Vuorikari et al. 2022 (DigComp 2.2) | rationale |
| 3 | GIS skills can be built step by step; each step maps to games | Bednarz 2004; Kerski 2003; Baker et al. 2015; game list from the repository | rationale + impl |
| 4 | Session workflow and architecture | `README.md`; `worker/src/index.ts`; screenshots | impl |
| 5 | Nine core games plus nine newer ones | `README.md`; `lib/games/registry.dart` | impl |
| 6 | Skill × game matrix; question → decision → feedback → reflection | Author's design rationale, labelled on the slide as not measured | rationale |
| 7 | The teacher designs, observes, gives feedback; illustrative lesson | Black & Wiliam 1998; teacher features in `README.md`. The lesson is labelled illustrative. | rationale + impl |
| 8 | Privacy measures; pseudonymity; GDPR and Georgian law as frameworks, not certification | See verified facts above; GDPR Art. 5 and 25; Law of Georgia on Personal Data Protection | impl + rationale |
| 9 | Coordinate notations, formats and open data; no OGC claim | `lib/coords.dart`; `lib/export.dart`; RFC 7946; EPSG | impl |
| 10 | Four platforms; connectivity behaviour stated accurately | `pubspec.yaml`, platform folders, `web/sw.js`, `lib/queue.dart` | impl + rationale |
| 11 | Non-standard games; scores are not a measure of competence | `README.md`; Freeman et al. 2014 | impl + rationale |
| 12 | No evaluation yet; limitations; proposed studies | Uttal et al. 2013; Baker et al. 2015 | hyp + plan |
| 13 | Conclusion | Summary of slides 2–12 | — |
| 14 | References | See below | — |
| 15 | Questions; QR codes to the repository and the DOI | `CITATION.cff` | — |

## External references

These are cited on the slides. Check page numbers against the originals before publishing a written version.

1. Kapanadze, G. (2026). *GeoClass: Interactive geography games for school students* (Version 1.0.0) [Software]. Zenodo. https://doi.org/10.5281/zenodo.24144115
2. National Research Council. (2006). *Learning to think spatially: GIS as a support system in the K-12 curriculum*. National Academies Press. https://doi.org/10.17226/11019
3. Bednarz, S. W. (2004). Geographic information systems: A tool to support geography and environmental education? *GeoJournal, 60*(2), 191–199.
4. Kerski, J. J. (2003). The implementation and effectiveness of geographic information systems technology and methods in secondary education. *Journal of Geography, 102*(3), 128–137.
5. Baker, T. R., Battersby, S., Bednarz, S. W., Bodzin, A. M., Kolvoord, B., Moore, S., Sinton, D., & Uttal, D. (2015). A research agenda for geospatial technologies and learning. *Journal of Geography, 114*(3), 118–130.
6. Uttal, D. H., Meadow, N. G., Tipton, E., Hand, L. L., Alden, A. R., Warren, C., & Newcombe, N. S. (2013). The malleability of spatial skills: A meta-analysis of training studies. *Psychological Bulletin, 139*(2), 352–402.
7. Black, P., & Wiliam, D. (1998). Assessment and classroom learning. *Assessment in Education: Principles, Policy & Practice, 5*(1), 7–74.
8. Freeman, S., et al. (2014). Active learning increases student performance in science, engineering, and mathematics. *PNAS, 111*(23), 8410–8415.
9. Vuorikari, R., Kluzer, S., & Punie, Y. (2022). *DigComp 2.2: The Digital Competence Framework for Citizens*. Publications Office of the European Union.
10. Regulation (EU) 2016/679 (General Data Protection Regulation), Article 5 (principles) and Article 25 (data protection by design and by default).
11. Law of Georgia on Personal Data Protection (2023). Check the official number and date on matsne.gov.ge before citing it in writing.
12. Butler, H., Daly, M., Doyle, A., Gillies, S., Hagen, S., & Schaub, T. (2016). *The GeoJSON Format* (RFC 7946). IETF.
13. EPSG Geodetic Parameter Dataset: EPSG:4326 (WGS 84), EPSG:32637 and EPSG:32638 (WGS 84 / UTM zones 37N and 38N).
14. Map data © OpenStreetMap contributors (ODbL); OpenTopoMap (CC BY-SA); Natural Earth (public domain); GeoNames (CC BY 4.0); Copernicus DEM GLO-30 (produced using Copernicus WorldDEM-30 © DLR e.V. 2010–2014 and © Airbus Defence and Space GmbH 2014–2018, provided under COPERNICUS by the European Union and ESA).

## Screenshots

All screenshots are of the real application, built from `main` at `051e4ee`.

- **`assets/screens/{en,ka}_*`** were taken from a local test server (`wrangler dev`, local database, a local-only teacher key) with made-up demonstration data.
  - The QR codes in them point to `localhost` and do not work anywhere else.
  - The demonstration data is generated by `_build/seed.py`.
  - No real student data, teacher key or token is shown.
- **`assets/screens/ka_phone_detective.png`** comes from a real Android phone and is one of the Play Store screenshots. Its demonstration session was deleted from the live server afterwards.
- **Mapping race and aerial photo (and the coordinate detective in English):** slide 11 shows these with drawn symbols, labelled "Conceptual illustration", instead of screenshots.
