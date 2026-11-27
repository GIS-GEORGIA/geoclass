# GeoClass: Geography Games as a First Step toward GIS Education

Spatial thinking, map literacy and privacy by design in the school classroom

Scientific conference “Modern Problems of Geography” · 19 December 2026

[Speaker name] · [Affiliation] · [e-mail]

## 2. The educational challenge: beyond place names

*Knowing where places are is necessary, but geography asks students to reason with space.*

- **Spatial thinking:** Concepts of space, tools of representation and processes of reasoning (NRC, 2006).
- **Map literacy:** Reading symbols, scale, orientation and coordinates, and judging what a map leaves out.
- **Geographic reasoning:** Explaining why something is where it is, and comparing places and patterns.
- **Digital geographic competencies:** Working confidently with online maps, spatial data and their formats (cf. DigComp 2.2).

Typical difficulty: memorised facts without the ability to apply them to a new map.

<sub>National Research Council, 2006; Vuorikari et al., 2022</sub>

## 3. Why GIS education should begin at school

*GIS skills can be built step by step, long before students open professional software.*

- **Read the map** (zoom, layers, symbols): Travel · Aerial · Cards
- **Locate precisely** (coordinates and datums): Coordinates · Detective
- **Create spatial data** (points, lines, polygons): Mapping race
- **Represent and design** (legend, scale, colour): Layout · Plates · Puzzle
- **Analyse** (terrain, thematic data): Terrain and thematic games*
- **Professional GIS** (QGIS and other desktop GIS): Next step, outside GeoClass

* Additional games in the current repository (terrain profile, slopes, viewshed, drainage basin, thematic map).

<sub>Bednarz, 2004; Kerski, 2003; Baker et al., 2015</sub>

## 4. GeoClass: concept and architecture

*A teacher-led session that runs on the students' own devices.*

- Teacher creates a session
- QR code on the screen
- Students join without accounts
- Students solve the task
- Answers appear on the teacher's map
- Class discussion

Flutter app (one codebase) → Cloudflare Worker (validation) → D1 / SQLite · polling every 3 s

<sub>Repository: README.md, lib/, worker/src/index.ts</sub>

## 5. Nine core educational games

*Each game links a short student activity to a geographic skill.*

- **1. Where would you travel?** — Place a point and give a reason · Online maps, zoom, layers · Choose, justify, compare · Lesson opener; discussing a class map
- **2. Coordinates game** — Coordinates → map, map → coordinates · DD, DM, DMS, UTM; latitude/longitude · Estimate, check the miss in metres · Practising coordinate notation
- **3. Aerial photo** — Find where an aerial photo was taken · Reading the landscape · Look for clues, form a guess · Landscape and settlement patterns
- **4. Mapping race** — Draw points, lines, polygons in time · Vector geometry on a map · Choose the right geometry · Mapping the school neighbourhood
- **5. Cards** — Match map cards of the same place · Scale and orientation · Compare shapes across scales · Visual memory, north arrow
- **6. Coordinate detective** — Read, convert and locate coordinates · Format conversion · Step-by-step inference · Careful reading of documents
- **7. Colour plates** — Spot a hidden region in coloured dots · Shape recognition, colour · Why map colours matter · Discussing colour vision and maps
- **8. Map puzzle** — Assemble regions or municipalities · Shapes and neighbours · Use adjacency and outline · Administrative geography of Georgia
- **9. Map layout** — Colour by legend, place map elements · Title, legend, scale, north, grid · Design a readable map · Cartographic conventions, A4 PDF

Since version 1.0 the repository adds nine more: terrain profile, steep slopes, viewshed, drainage basin, basin from the DEM, least-cost route, thematic map, 112 location report, satellite time-lapse.

<sub>README.md; lib/games/registry.dart</sub>

## 6. From game mechanics to spatial thinking

*Design intent: which aspects of spatial thinking each game addresses.*

| | Travel | Coord. | Aerial | Mapping | Cards | Detect. | Plates | Puzzle | Layout |
|---|---|---|---|---|---|---|---|---|---|
| Spatial orientation | ● | ● | ○ | ● | ● |  |  | ○ | ○ |
| Coordinate interpretation |  | ● |  |  |  | ● |  |  | ○ |
| Scale awareness | ○ | ○ | ● | ○ | ● |  |  |  | ● |
| Pattern recognition | ○ |  | ● |  | ● |  | ● | ● |  |
| Spatial relationships | ○ |  | ○ | ● | ○ |  |  | ● | ○ |
| Map interpretation | ● | ○ | ● | ○ | ○ | ○ | ● | ○ | ● |
| Problem-solving |  | ○ | ○ | ○ |  | ● |  | ● | ○ |
| Hypothesis formation | ○ |  | ● |  |  | ○ |  |  |  |

Question → Spatial decision → Immediate feedback → Reflection in class

Example: “Where was this photo taken?” → the student taps the map → the miss is shown in kilometres → the class compares the clues that worked.

_This matrix is the authors' design rationale, not a measured result._

## 7. The teacher as a learning facilitator

*GeoClass supports the teacher; it does not replace the teacher.*

- Designs the task
- Selects the game
- Sets difficulty and time
- Observes answers live
- Identifies misconceptions
- Invites explanation
- Gives formative feedback
- Adapts the next activity

**Illustrative 45-minute lesson**
- 0–5: Topic, QR code, students join
- 5–15: Coordinates game: DMS and UTM tasks
- 15–22: Discuss the largest misses on the map
- 22–37: Mapping race: our neighbourhood
- 37–45: Reflection; export of results

<sub>Black & Wiliam, 1998; README.md</sub>

## 8. Privacy by design and student confidentiality

*Technical measures verified in the source code.*

- No student account; no name, e-mail or phone number is requested
- A random identifier is generated on the device, new for every session
- Answers are linked only to that identifier; a nickname is optional
- A student can delete their own answers from the ⓘ dialog
- The teacher can hide or delete any answer
- Sessions and answers are deleted automatically after 6 months
- Only a hash of the QR token is stored on the server
- Every answer is validated on the server; unknown fields are dropped
- No phone location (GPS), camera, cookies, ads or analytics

Data minimisation · Purpose limitation · Storage limitation · Privacy by design and by default · Transparency · Student dignity

Pseudonymous, not absolutely anonymous: free-text answers or a chosen nickname could still identify a student. Students are asked not to write personal information.

Relevant frameworks: GDPR (Art. 5, 25) and the Law of Georgia on Personal Data Protection. These measures are technical; they are not a certification of legal compliance.

<sub>lib/queue.dart; worker/src/index.ts, validate.ts, retention.ts; web/privacy/</sub>

## 9. Standards, interoperability and open geospatial principles

*One location, four notations: the coordinates game and the detective use all of them.*

**Tbilisi, WGS 84 (EPSG:4326)**
- DD: 41.6938° N, 44.8015° E
- DM: 41°41.628′ N, 44°48.090′ E
- DMS: 41°41′38″ N, 44°48′05″ E
- UTM 38N: E 483 482 m, N 4 615 799 m (EPSG:32638)
- **Datum and projection:** WGS 84; UTM zones 37N/38N via proj4; Web Mercator base maps
- **Data formats:** GeoJSON (RFC 7946), CSV and JSON export; restore from backup
- **Open data:** OpenStreetMap (ODbL), OpenTopoMap, Natural Earth, GeoNames, Copernicus DEM GLO-30
- **Open source:** MIT licence; archived on Zenodo with a DOI

No formal OGC certification is claimed. Open formats are used so that classroom data can be opened in professional GIS.

<sub>lib/coords.dart; lib/export.dart; README.md; RFC 7946; EPSG registry</sub>

## 10. Multiplatform accessibility

*One Flutter codebase, four platforms: the school chooses the hardware, not the app.*

- **Web / PWA:** any phone or laptop with a browser
- **Android:** native app; App Links open QR sessions
- **Windows:** teacher's classroom computer
- **Linux:** school computer labs
- Mixed school hardware
- Students' own devices
- The teacher's classroom computer
- Less dependence on one operating system

**Connectivity, as implemented**
- The web app shell is cached by a service worker and opens offline
- Answers wait on the device if the connection drops and are sent later, without duplicates
- Live results, map tiles and the server still need a connection

<sub>pubspec.yaml; web/sw.js; lib/queue.dart; README.md</sub>

## 11. Educational innovation: non-standard games

*Tasks that require interpretation, not only recall.*

- **Coordinate detective:** Read coordinates from a training document, convert, locate, name the place
- **Mapping race:** Create points, lines and polygons; export as GeoJSON
- **Map puzzle:** Assemble Georgia from regions or municipalities
- **Aerial photo:** Connect what the landscape shows with a location on the map
- **Map layout:** Legend, title, north arrow, scale bar and grid on an A4 sheet
- **Colour plates:** Voluntary; the class answers aloud and nothing is sent

Inquiry-based learning · Active learning · Formative assessment · Collaborative discussion · Learning through mistakes

Game scores are feedback for discussion, not a complete measure of geographic competence.

<sub>README.md; Freeman et al., 2014</sub>

## 12. Limitations and research opportunities

*No empirical evaluation has been carried out yet.*

**Limitations**
- Learning effects are not yet measured
- Unequal access to devices
- Dependence on internet connectivity
- Teachers need preparation time
- Speed-based scoring may reward haste over reasoning
- No formal accessibility audit yet
- Tasks must be matched to age (designed for grades 6–9)

**Proposed research**
- Pre-test / post-test of spatial reasoning
- Structured classroom observation
- Teacher interviews
- Student engagement analysis
- Usability studies (e.g. SUS)
- Comparison with other teaching methods
- Longitudinal study of GIS skill development

<sub>Uttal et al., 2013; Baker et al., 2015</sub>

## 13. Conclusion

*GeoClass shows how school geography can become:*

- more interactive
- more spatially oriented
- more accessible
- more teacher-centred
- more privacy-conscious
- more connected to modern GIS

> The first step into GIS is not software. It is curiosity about where things are, and why.

## 14. References

- Kapanadze, G. (2026). GeoClass: Interactive geography games for school students (Version 1.0.0) [Software]. Zenodo. https://doi.org/10.5281/zenodo.24144115 · github.com/GIS-GEORGIA/geoclass
- National Research Council. (2006). Learning to think spatially: GIS as a support system in the K-12 curriculum. National Academies Press.
- Bednarz, S. W. (2004). Geographic information systems: A tool to support geography and environmental education? GeoJournal, 60(2), 191–199.
- Kerski, J. J. (2003). The implementation and effectiveness of GIS technology and methods in secondary education. Journal of Geography, 102(3), 128–137.
- Baker, T. R., et al. (2015). A research agenda for geospatial technologies and learning. Journal of Geography, 114(3), 118–130.
- Uttal, D. H., et al. (2013). The malleability of spatial skills: A meta-analysis of training studies. Psychological Bulletin, 139(2), 352–402.
- Black, P., & Wiliam, D. (1998). Assessment and classroom learning. Assessment in Education, 5(1), 7–74.
- Freeman, S., et al. (2014). Active learning increases student performance in science, engineering, and mathematics. PNAS, 111(23), 8410–8415.
- Vuorikari, R., Kluzer, S., & Punie, Y. (2022). DigComp 2.2: The Digital Competence Framework for Citizens. Publications Office of the EU.
- Regulation (EU) 2016/679 (General Data Protection Regulation), Articles 5 and 25.
- Law of Georgia on Personal Data Protection (2023).
- Butler, H., et al. (2016). The GeoJSON Format. IETF RFC 7946. · EPSG:4326 (WGS 84), EPSG:32637/32638 (UTM 37N/38N).
- Map data © OpenStreetMap contributors (ODbL); OpenTopoMap (CC BY-SA); Natural Earth; GeoNames (CC BY 4.0); Copernicus DEM GLO-30 (WorldDEM-30 © DLR e.V. 2010–2014, © Airbus Defence and Space GmbH 2014–2018, provided under COPERNICUS by the EU and ESA).

## 15. Questions and discussion

*Thank you for your attention.*

- How could GeoClass be evaluated in Georgian schools?
- Which GIS concepts should come next?
- How can privacy and assessment be balanced?
