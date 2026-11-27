// All slide text for both presentations. build.mjs turns this into the .pptx files and the Markdown files,
// so the Georgian and English decks always have the same structure.
// Status tags: impl = implemented in the repository, rationale = educational rationale, hyp = research hypothesis,
// plan = future evaluation plan.

export const GAMES = ['travel', 'coords', 'aerial', 'mapping', 'cards', 'detective', 'plates', 'puzzle', 'layout'];

// Skill × game matrix: 2 = primary design aim, 1 = secondary, 0 = none. Design intent, not measured.
export const MATRIX = {
  orientation: [2, 2, 1, 2, 2, 0, 0, 1, 1],
  coordinates: [0, 2, 0, 0, 0, 2, 0, 0, 1],
  scale: [1, 1, 2, 1, 2, 0, 0, 0, 2],
  patterns: [1, 0, 2, 0, 2, 0, 2, 2, 0],
  relations: [1, 0, 1, 2, 1, 0, 0, 2, 1],
  interpretation: [2, 1, 2, 1, 1, 1, 2, 1, 2],
  problem: [0, 1, 1, 1, 0, 2, 0, 2, 1],
  hypothesis: [1, 0, 2, 0, 0, 1, 0, 0, 0],
};

export const T = {
  en: {
    font: 'Noto Sans',
    head: 'Noto Serif',
    conf: 'Modern Problems of Geography',
    confLine: 'Scientific conference “Modern Problems of Geography” · 19 December 2026',
    footer: 'GeoClass · Modern Problems of Geography · 19.12.2026',
    title: 'GeoClass: Geography Games as a First Step toward GIS Education',
    subtitle: 'Spatial thinking, map literacy and privacy by design in the school classroom',
    orgs: 'Georgian Geographical Society named after Alexander Javakhishvili · Ivane Javakhishvili Tbilisi State University',
    anniv: 'Dedicated to the 110th anniversary of the birth of Alexander Aslanikashvili',
    speaker: 'Giorgi Kapanadze',
    aff: 'Associate Professor, Business and Technology University (BTU) · ORCID 0009-0006-4193-5939',
    illus: 'Conceptual illustration',
    tags: { impl: 'Implemented', rationale: 'Educational rationale', hyp: 'Hypothesis', plan: 'Planned' },
    games: {
      travel: { n: 'Where would you travel?', a: 'Place a point and give a reason', s: 'Online maps, zoom, layers', r: 'Choose, justify, compare', u: 'Lesson opener; discussing a class map' },
      coords: { n: 'Coordinates game', a: 'Coordinates → map, map → coordinates', s: 'DD, DM, DMS, UTM; latitude/longitude', r: 'Estimate, check the miss in metres', u: 'Practising coordinate notation' },
      aerial: { n: 'Aerial photo', a: 'Find where an aerial photo was taken', s: 'Reading the landscape', r: 'Look for clues, form a guess', u: 'Landscape and settlement patterns' },
      mapping: { n: 'Mapping race', a: 'Draw points, lines, polygons in time', s: 'Vector geometry on a map', r: 'Choose the right geometry', u: 'Mapping the school neighbourhood' },
      cards: { n: 'Cards', a: 'Match map cards of the same place', s: 'Scale and orientation', r: 'Compare shapes across scales', u: 'Visual memory, north arrow' },
      detective: { n: 'Coordinate detective', a: 'Read, convert and locate coordinates', s: 'Format conversion', r: 'Step-by-step inference', u: 'Careful reading of documents' },
      plates: { n: 'Colour plates', a: 'Spot a hidden region in coloured dots', s: 'Shape recognition, colour', r: 'Why map colours matter', u: 'Discussing colour vision and maps' },
      puzzle: { n: 'Map puzzle', a: 'Assemble regions or municipalities', s: 'Shapes and neighbours', r: 'Use adjacency and outline', u: 'Administrative geography of Georgia' },
      layout: { n: 'Map layout', a: 'Colour by legend, place map elements', s: 'Title, legend, scale, north, grid', r: 'Design a readable map', u: 'Cartographic conventions, A4 PDF' },
    },
    s: [
      // 1 title — handled by layout
      { key: 'title', notes: `Good afternoon. It is an honour to speak at a conference that commemorates the 110th anniversary of Alexander Aslanikashvili, whose work reminds us that a map is not only a picture but a way of thinking about space.
My talk is about GeoClass, an open-source classroom environment that I see as a small, practical bridge between school geography and geographic information systems.
I will describe what is implemented, why it is designed this way, and what still has to be tested. I will be careful to separate these three things, because the project has not yet been evaluated in a formal study.` },
      { key: 'challenge', title: 'The educational challenge: beyond place names',
        lead: 'Knowing where places are is necessary, but geography asks students to reason with space.',
        tiles: [
          ['Spatial thinking', 'Concepts of space, tools of representation and processes of reasoning (NRC, 2006).'],
          ['Map literacy', 'Reading symbols, scale, orientation and coordinates, and judging what a map leaves out.'],
          ['Geographic reasoning', 'Explaining why something is where it is, and comparing places and patterns.'],
          ['Digital geographic competencies', 'Working confidently with online maps, spatial data and their formats (cf. DigComp 2.2).'],
        ],
        note: 'Typical difficulty: memorised facts without the ability to apply them to a new map.',
        cite: 'National Research Council, 2006; Vuorikari et al., 2022',
        notes: `Let me start with the problem. In many classrooms geography is still learned as lists: capitals, rivers, definitions. These are useful, but they do not automatically build the ability to reason with space.
The National Research Council's report "Learning to Think Spatially" describes spatial thinking as three things working together: concepts of space, tools of representation such as maps, and processes of reasoning.
Map literacy and geographic reasoning are the practical forms of this: reading scale and orientation, and explaining why a phenomenon is located where it is. Today we also have to add digital competencies, because students meet maps mostly on screens.
The difficulty I want to address is transfer: a student may know a fact, yet be unable to use it on an unfamiliar map.` },
      { key: 'ladder', title: 'Why GIS education should begin at school',
        lead: 'GIS skills can be built step by step, long before students open professional software.',
        steps: [
          ['Read the map', 'zoom, layers, symbols', 'Travel · Aerial · Cards'],
          ['Locate precisely', 'coordinates and datums', 'Coordinates · Detective'],
          ['Create spatial data', 'points, lines, polygons', 'Mapping race'],
          ['Represent and design', 'legend, scale, colour', 'Layout · Plates · Puzzle'],
          ['Analyse', 'terrain, thematic data', 'Terrain and thematic games*'],
          ['Professional GIS', 'QGIS and other desktop GIS', 'Next step, outside GeoClass'],
        ],
        foot: '* Additional games in the current repository (terrain profile, slopes, viewshed, drainage basin, thematic map).',
        cite: 'Bednarz, 2004; Kerski, 2003; Baker et al., 2015',
        notes: `Why at school? Research on GIS in secondary education, for example Kerski's work and Bednarz's review, shows both the promise and the barriers: software complexity, teacher time and hardware.
GeoClass takes a stepwise approach. The ladder on the slide starts with reading a map, then locating with coordinates, then creating simple vector data, then designing a map, then simple analysis. Each step has a game behind it.
The top step, professional GIS such as QGIS, is deliberately outside the app. GeoClass is not a replacement for GIS software; it is meant to make the first contact with GIS concepts easier, so that later the software makes sense.` },
      { key: 'workflow', title: 'GeoClass: concept and architecture',
        lead: 'A teacher-led session that runs on the students\' own devices.',
        flow: ['Teacher creates a session', 'QR code on the screen', 'Students join without accounts', 'Students solve the task', 'Answers appear on the teacher\'s map', 'Class discussion'],
        tech: 'Flutter app (one codebase) → Cloudflare Worker (validation) → D1 / SQLite · polling every 3 s',
        cap1: 'Teacher: QR code for the session', cap2: 'Student phone: the travel task',
        cite: 'Repository: README.md, lib/, worker/src/index.ts',
        notes: `This is how a lesson works. The teacher creates a session and chooses a game. The app shows a QR code. Students scan it with their phones, without creating accounts, and solve the task. Their answers appear on the teacher's map almost immediately, and the class discusses them.
Technically, one Flutter codebase produces the web, Android and desktop apps. All writes go through a small server, a Cloudflare Worker, which validates every answer before storing it in a database. Phones ask for updates every three seconds, which works the same way on every platform.
The screenshots on the right are from the real application, running on a local test server with demonstration data.` },
      { key: 'games', title: 'Nine core educational games',
        lead: 'Each game links a short student activity to a geographic skill.',
        legend: ['Student activity', 'Skill practised', 'Reasoning'],
        more: 'Since version 1.0 the repository adds nine more: terrain profile, steep slopes, viewshed, drainage basin, basin from the DEM, least-cost route, thematic map, 112 location report, satellite time-lapse.',
        cite: 'README.md; lib/games/registry.dart',
        notes: `These are the nine core games described in the project documentation. I will not read every card; let me point out the logic.
The first row is about locating: choosing a place, working with coordinates, and recognising a place from an aerial photo. The second row is about creating and comparing: drawing points, lines and polygons, matching map cards at different scales, and the coordinate detective, which asks students to read coordinates from a document, convert them and find the place. The third row is cartographic: colour, the shapes of regions, and the elements of a map layout.
At the bottom you see that the current version already contains nine further games, for example terrain profiles and drainage basins on a digital elevation model of Georgia. They are a natural continuation towards analytical GIS, but today I focus on the nine core games.` },
      { key: 'matrix', title: 'From game mechanics to spatial thinking',
        lead: 'Design intent: which aspects of spatial thinking each game addresses.',
        skills: { orientation: 'Spatial orientation', coordinates: 'Coordinate interpretation', scale: 'Scale awareness', patterns: 'Pattern recognition', relations: 'Spatial relationships', interpretation: 'Map interpretation', problem: 'Problem-solving', hypothesis: 'Hypothesis formation' },
        short: { travel: 'Travel', coords: 'Coord.', aerial: 'Aerial', mapping: 'Mapping', cards: 'Cards', detective: 'Detect.', plates: 'Plates', puzzle: 'Puzzle', layout: 'Layout' },
        key2: 'primary aim', key1: 'secondary aim',
        cycle: ['Question', 'Spatial decision', 'Immediate feedback', 'Reflection in class'],
        example: 'Example: “Where was this photo taken?” → the student taps the map → the miss is shown in kilometres → the class compares the clues that worked.',
        caveat: 'This matrix is the authors\' design rationale, not a measured result.',
        notes: `How do game mechanics relate to spatial thinking? The matrix shows the design intent: which aspects each game is meant to exercise. A filled circle is a primary aim, a ring a secondary one. I want to be clear that this is a rationale, not a measured result.
More important is the cycle on the right. Each task starts with a question, requires a spatial decision, gives immediate feedback, and then returns to the class for reflection. In the aerial photo game, for example, the student taps the map, sees how far off the guess was, and then the class compares which clues in the landscape were useful.
This movement from decision to reflection is what distinguishes reasoning from memorisation.` },
      { key: 'teacher', title: 'The teacher as a learning facilitator',
        lead: 'GeoClass supports the teacher; it does not replace the teacher.',
        roles: ['Designs the task', 'Selects the game', 'Sets difficulty and time', 'Observes answers live', 'Identifies misconceptions', 'Invites explanation', 'Gives formative feedback', 'Adapts the next activity'],
        lessonTitle: 'Illustrative 45-minute lesson',
        lesson: [['0–5', 'Topic, QR code, students join'], ['5–15', 'Coordinates game: DMS and UTM tasks'], ['15–22', 'Discuss the largest misses on the map'], ['22–37', 'Mapping race: our neighbourhood'], ['37–45', 'Reflection; export of results']],
        cap: 'Teacher view: answers on the live map, hide or delete before projecting',
        cite: 'Black & Wiliam, 1998; README.md',
        notes: `This is, for me, the most important slide. The teacher remains at the centre. The teacher designs the task, selects the game, sets the difficulty and the clock, and watches the answers arrive.
The live map makes misconceptions visible. If half of the class puts a point in the wrong hemisphere, the teacher sees it immediately and can ask: why did you decide this? This is formative assessment in the sense of Black and Wiliam: information used to adapt teaching while learning is still happening.
On the left is an illustrative lesson plan, not a report from a real lesson. Note that the teacher can hide or delete an answer before projecting the map, which protects students from embarrassment.` },
      { key: 'privacy', title: 'Privacy by design and student confidentiality',
        lead: 'Technical measures verified in the source code.',
        measures: [
          'No student account; no name, e-mail or phone number is requested',
          'A random identifier is generated on the device, new for every session',
          'Answers are linked only to that identifier; a nickname is optional',
          'A student can delete their own answers from the ⓘ dialog',
          'The teacher can hide or delete any answer',
          'Sessions and answers are deleted automatically after 6 months',
          'Only a hash of the QR token is stored on the server',
          'Every answer is validated on the server; unknown fields are dropped',
          'No phone location (GPS), camera, cookies, ads or analytics',
        ],
        principles: ['Data minimisation', 'Purpose limitation', 'Storage limitation', 'Privacy by design and by default', 'Transparency', 'Student dignity'],
        pseudo: 'Pseudonymous, not absolutely anonymous: free-text answers or a chosen nickname could still identify a student. Students are asked not to write personal information.',
        legal: 'Relevant frameworks: GDPR (Art. 5, 25) and the Law of Georgia on Personal Data Protection. These measures are technical; they are not a certification of legal compliance.',
        cap: 'Privacy dialog on the student page',
        cite: 'lib/queue.dart; worker/src/index.ts, validate.ts, retention.ts; web/privacy/',
        notes: `Educational technology often collects far more data than teaching requires. GeoClass was designed the other way round, and I verified each point on this slide in the source code.
Students have no accounts and are not asked for a name or contact. The device creates a random identifier, a new one for every session, so two sessions cannot be linked through it. A student can erase their own answers; the teacher can hide or delete answers; and everything is deleted automatically after six months. The server stores only a hash of the QR token, so a leaked database would not reveal working links.
I want to be precise about terminology. This is pseudonymity, not absolute anonymity. A nickname or a free-text answer could still identify someone, which is why students are asked not to write personal details.
These measures follow principles of the GDPR, Articles 5 and 25, and the Georgian law on personal data protection. But technical measures are not the same as a legal assessment, and I do not claim certified compliance.` },
      { key: 'standards', title: 'Standards, interoperability and open geospatial principles',
        lead: 'One location, four notations: the coordinates game and the detective use all of them.',
        place: 'Tbilisi, WGS 84 (EPSG:4326)',
        formats: [['DD', '41.6938° N, 44.8015° E'], ['DM', '41°41.628′ N, 44°48.090′ E'], ['DMS', '41°41′38″ N, 44°48′05″ E'], ['UTM 38N', 'E 483 482 m, N 4 615 799 m (EPSG:32638)']],
        rows: [
          ['Datum and projection', 'WGS 84; UTM zones 37N/38N via proj4; Web Mercator base maps'],
          ['Data formats', 'GeoJSON (RFC 7946), CSV and JSON export; restore from backup'],
          ['Open data', 'OpenStreetMap (ODbL), OpenTopoMap, Natural Earth, GeoNames, Copernicus DEM GLO-30'],
          ['Open source', 'MIT licence; archived on Zenodo with a DOI'],
        ],
        caveat: 'No formal OGC certification is claimed. Open formats are used so that classroom data can be opened in professional GIS.',
        cite: 'lib/coords.dart; lib/export.dart; README.md; RFC 7946; EPSG registry',
        notes: `GeoClass is small, but it is built on the same standards as professional GIS. All coordinates are on the WGS 84 datum. The app teaches four notations: decimal degrees, degrees and decimal minutes, degrees-minutes-seconds, and rectangular UTM coordinates in zones 37 and 38 North, which cover Georgia.
The example shows the same point in Tbilisi in all four notations. Students learn that these are not different places but different ways of writing one place, which is a basic but often misunderstood idea.
Drawings from the mapping race can be exported as GeoJSON and opened directly in QGIS. The base maps and boundaries come from open data such as OpenStreetMap, with attribution always visible. I do not claim formal OGC certification; the point is interoperability and a smooth transition to professional tools.` },
      { key: 'platforms', title: 'Multiplatform accessibility',
        lead: 'One Flutter codebase, four platforms: the school chooses the hardware, not the app.',
        plats: [['Web / PWA', 'any phone or laptop with a browser'], ['Android', 'native app; App Links open QR sessions'], ['Windows', 'teacher\'s classroom computer'], ['Linux', 'school computer labs']],
        why: ['Mixed school hardware', 'Students\' own devices', 'The teacher\'s classroom computer', 'Less dependence on one operating system'],
        conn: [
          'The web app shell is cached by a service worker and opens offline',
          'Answers wait on the device if the connection drops and are sent later, without duplicates',
          'Live results, map tiles and the server still need a connection',
        ],
        connTitle: 'Connectivity, as implemented',
        cite: 'pubspec.yaml; web/sw.js; lib/queue.dart; README.md',
        notes: `Schools in Georgia, as elsewhere, have very different equipment. Some classes have tablets, many rely on students' own phones, and the teacher often has one classroom computer.
GeoClass is built from one codebase for the web as a progressive web app, for Android, Windows and Linux. A student can simply open a link in a browser; no installation is required.
Connectivity is a real constraint, so I want to describe it accurately. The application shell is cached and opens without a network. If the connection drops while a student answers, the answer waits on the device and is sent later, and the server ignores duplicates. But live results and map tiles need the internet; GeoClass is not a fully offline application.` },
      { key: 'innovation', title: 'Educational innovation: non-standard games',
        lead: 'Tasks that require interpretation, not only recall.',
        cards: [
          ['Coordinate detective', 'Read coordinates from a training document, convert, locate, name the place', 'detective'],
          ['Mapping race', 'Create points, lines and polygons; export as GeoJSON', null],
          ['Map puzzle', 'Assemble Georgia from regions or municipalities', 'puzzle'],
          ['Aerial photo', 'Connect what the landscape shows with a location on the map', null],
          ['Map layout', 'Legend, title, north arrow, scale bar and grid on an A4 sheet', 'layout'],
          ['Colour plates', 'Voluntary; the class answers aloud and nothing is sent', 'plates'],
        ],
        ped: ['Inquiry-based learning', 'Active learning', 'Formative assessment', 'Collaborative discussion', 'Learning through mistakes'],
        caveat: 'Game scores are feedback for discussion, not a complete measure of geographic competence.',
        cite: 'README.md; Freeman et al., 2014',
        notes: `Some of the games are, I think, unusual for school geography. The coordinate detective gives students a clearly marked training document, a fine receipt or a dashcam frame, with coordinates in one format. They must convert them, find the place and name it. It is a small exercise in careful reading and inference.
The map layout game asks students to compose a map: colour the regions according to a legend and place the title, north arrow, legend, scale bar and grid. The colour plates game uses colour-vision-style plates to start a discussion about why map colours matter for people who see colour differently; it is voluntary and nothing is sent.
Mistakes are part of the design: the live map shows them, and the discussion turns them into learning. But a score is a signal for discussion, not a measure of geographic competence.` },
      { key: 'limits', title: 'Limitations and research opportunities',
        lead: 'No empirical evaluation has been carried out yet.',
        limTitle: 'Limitations',
        lims: ['Learning effects are not yet measured', 'Unequal access to devices', 'Dependence on internet connectivity', 'Teachers need preparation time', 'Speed-based scoring may reward haste over reasoning', 'No formal accessibility audit yet', 'Tasks must be matched to age (designed for grades 6–9)'],
        resTitle: 'Proposed research',
        res: ['Pre-test / post-test of spatial reasoning', 'Structured classroom observation', 'Teacher interviews', 'Student engagement analysis', 'Usability studies (e.g. SUS)', 'Comparison with other teaching methods', 'Longitudinal study of GIS skill development'],
        cite: 'Uttal et al., 2013; Baker et al., 2015',
        notes: `A scientific presentation must state its limitations. The most important one: GeoClass has not been evaluated empirically. I have no data on learning effects, and I will not present any.
There are also practical limits: not every student has a device, connectivity varies, teachers need time to prepare, and timed scoring can reward speed over careful thinking. An accessibility audit has not been done yet.
These limits define a research agenda. Meta-analytic work by Uttal and colleagues shows that spatial skills can be trained, which gives us a testable hypothesis. I propose pre- and post-tests of spatial reasoning, classroom observation, teacher interviews, usability studies and, in the longer term, a longitudinal study. I would welcome collaboration with colleagues in this room.` },
      { key: 'conclusion', title: 'Conclusion',
        lead: 'GeoClass shows how school geography can become:',
        words: ['more interactive', 'more spatially oriented', 'more accessible', 'more teacher-centred', 'more privacy-conscious', 'more connected to modern GIS'],
        closing: 'The first step into GIS is not software. It is curiosity about where things are, and why.',
        notes: `To conclude. GeoClass is an example of how interactive geographic games can become a first step toward GIS: they build map literacy, coordinate skills and spatial reasoning, while leaving the teacher in control and collecting as little data as possible.
It is open source and archived with a DOI, so colleagues can use it, adapt it and, most importantly, evaluate it.
I would like to finish with one thought, in the spirit of Alexander Aslanikashvili's view of the map as a means of knowing: the first step into GIS is not software. It is curiosity about where things are, and why.` },
      { key: 'refs', title: 'References',
        refs: [
          'Kapanadze, G. (2026). GeoClass: Interactive geography games for school students (Version 1.0.0) [Software]. Zenodo. https://doi.org/10.5281/zenodo.24144115 · github.com/GIS-GEORGIA/geoclass',
          'National Research Council. (2006). Learning to think spatially: GIS as a support system in the K-12 curriculum. National Academies Press.',
          'Bednarz, S. W. (2004). Geographic information systems: A tool to support geography and environmental education? GeoJournal, 60(2), 191–199.',
          'Kerski, J. J. (2003). The implementation and effectiveness of GIS technology and methods in secondary education. Journal of Geography, 102(3), 128–137.',
          'Baker, T. R., et al. (2015). A research agenda for geospatial technologies and learning. Journal of Geography, 114(3), 118–130.',
          'Uttal, D. H., et al. (2013). The malleability of spatial skills: A meta-analysis of training studies. Psychological Bulletin, 139(2), 352–402.',
          'Black, P., & Wiliam, D. (1998). Assessment and classroom learning. Assessment in Education, 5(1), 7–74.',
          'Freeman, S., et al. (2014). Active learning increases student performance in science, engineering, and mathematics. PNAS, 111(23), 8410–8415.',
          'Vuorikari, R., Kluzer, S., & Punie, Y. (2022). DigComp 2.2: The Digital Competence Framework for Citizens. Publications Office of the EU.',
          'Regulation (EU) 2016/679 (General Data Protection Regulation), Articles 5 and 25.',
          'Law of Georgia on Personal Data Protection (2023).',
          'Butler, H., et al. (2016). The GeoJSON Format. IETF RFC 7946. · EPSG:4326 (WGS 84), EPSG:32637/32638 (UTM 37N/38N).',
          'Map data © OpenStreetMap contributors (ODbL); OpenTopoMap (CC BY-SA); Natural Earth; GeoNames (CC BY 4.0); Copernicus DEM GLO-30 (WorldDEM-30 © DLR e.V. 2010–2014, © Airbus Defence and Space GmbH 2014–2018, provided under COPERNICUS by the EU and ESA).',
        ],
        notes: `The references are listed here and in the accompanying source file. The software itself can be cited through its Zenodo DOI.` },
      { key: 'questions', title: 'Questions and discussion',
        lead: 'Thank you for your attention.',
        q: ['How could GeoClass be evaluated in Georgian schools?', 'Which GIS concepts should come next?', 'How can privacy and assessment be balanced?'],
        qr1: 'Source code', qr2: 'DOI',
        notes: `Thank you. I would be glad to hear your questions, and especially your views on how such tools could be evaluated in Georgian schools.` },
    ],
  },

  ka: {
    font: 'Noto Sans Georgian',
    head: 'Noto Serif Georgian',
    conf: 'გეოგრაფიის თანამედროვე პრობლემები',
    confLine: 'სამეცნიერო კონფერენცია „გეოგრაფიის თანამედროვე პრობლემები“ · 19 დეკემბერი, 2026',
    footer: 'GeoClass · გეოგრაფიის თანამედროვე პრობლემები · 19.12.2026',
    title: 'GeoClass: გეოგრაფიული თამაშები, როგორც GIS-ის სწავლების პირველი ნაბიჯი',
    subtitle: 'სივრცითი აზროვნება, კარტოგრაფიული წიგნიერება და კონფიდენციალურობა დიზაინის ეტაპიდან სკოლის საკლასო ოთახში',
    orgs: 'ალექსანდრე ჯავახიშვილის სახელობის საქართველოს გეოგრაფიული საზოგადოება · ივანე ჯავახიშვილის სახელობის თბილისის სახელმწიფო უნივერსიტეტი',
    anniv: 'ეძღვნება ალექსანდრე ასლანიკაშვილის დაბადებიდან 110 წლისთავს',
    speaker: 'გიორგი კაპანაძე',
    aff: 'ასოცირებული პროფესორი, ბიზნესისა და ტექნოლოგიების უნივერსიტეტი (BTU)\nORCID 0009-0006-4193-5939',
    illus: 'კონცეპტუალური ილუსტრაცია',
    tags: { impl: 'რეალიზებულია', rationale: 'პედაგოგიური დასაბუთება', hyp: 'ჰიპოთეზა', plan: 'დაგეგმილია' },
    games: {
      travel: { n: 'სად გსურს მოგზაურობა?', a: 'წერტილი რუკაზე და მიზეზი', s: 'ონლაინ რუკა, მასშტაბი, ფენები', r: 'არჩევა, დასაბუთება, შედარება', u: 'გაკვეთილის დასაწყისი; კლასის რუკის განხილვა' },
      coords: { n: 'კოორდინატების თამაში', a: 'კოორდინატი → რუკა, რუკა → კოორდინატი', s: 'DD, DM, DMS, UTM; განედი/გრძედი', r: 'შეფასება, აცდენა მეტრებში', u: 'კოორდინატების ჩაწერის ვარჯიში' },
      aerial: { n: 'საჰაერო ფოტო', a: 'იპოვე, სადაა გადაღებული ფოტო', s: 'ლანდშაფტის წაკითხვა', r: 'ნიშნების ძიება, ვარაუდი', u: 'ლანდშაფტი და დასახლებები' },
      mapping: { n: 'დახატე შენი უბანი', a: 'წერტილი, ხაზი, პოლიგონი დროში', s: 'ვექტორული გეომეტრია', r: 'სწორი გეომეტრიის არჩევა', u: 'სკოლის მიდამოს რუკა' },
      cards: { n: 'ბარათები', a: 'ერთი ადგილის ბარათების წყვილები', s: 'მასშტაბი და ორიენტაცია', r: 'ფორმების შედარება', u: 'ვიზუალური მეხსიერება, ჩრდილოეთი' },
      detective: { n: 'კოორდინატების დეტექტივი', a: 'ამოიკითხე, გადაიყვანე, იპოვე', s: 'ფორმატების გარდაქმნა', r: 'ნაბიჯ-ნაბიჯ დასკვნა', u: 'დოკუმენტის ყურადღებით კითხვა' },
      plates: { n: 'ფერების წრეები', a: 'ფერად წერტილებში დამალული ფორმა', s: 'ფორმის ამოცნობა, ფერი', r: 'რატომ არის ფერი მნიშვნელოვანი', u: 'ფერის აღქმა და რუკები' },
      puzzle: { n: 'რუკის ფაზლი', a: 'რეგიონების ან მუნიციპალიტეტების აწყობა', s: 'ფორმები და მეზობლები', r: 'მოსაზღვრეობის გამოყენება', u: 'საქართველოს ადმინისტრაციული დაყოფა' },
      layout: { n: 'რუკის გაფორმება', a: 'ლეგენდით გაფერადება, ელემენტები', s: 'სათაური, ლეგენდა, მასშტაბი, ბადე', r: 'წაკითხვადი რუკის შექმნა', u: 'კარტოგრაფიული წესები, A4 PDF' },
    },
    s: [
      { key: 'title', notes: `მოგესალმებით. დიდი პატივია, ვისაუბრო კონფერენციაზე, რომელიც ალექსანდრე ასლანიკაშვილის დაბადებიდან 110 წლისთავს ეძღვნება. მისი შრომები გვახსენებს, რომ რუკა მხოლოდ გამოსახულება კი არა, სივრცეზე აზროვნების საშუალებაა.
ჩემი მოხსენება ეხება GeoClass-ს, ღია კოდის საკლასო გარემოს, რომელსაც სკოლის გეოგრაფიასა და გეოგრაფიულ ინფორმაციულ სისტემებს შორის მცირე, პრაქტიკულ ხიდად განვიხილავ.
ვისაუბრებ იმაზე, რა არის რეალიზებული, რატომ არის ასე აგებული და რა უნდა შემოწმდეს. ამ სამს ერთმანეთისგან მკაფიოდ გავმიჯნავ, რადგან პროექტს ჯერ ფორმალური კვლევა არ ჩატარებია.` },
      { key: 'challenge', title: 'საგანმანათლებლო გამოწვევა: ადგილის სახელებს მიღმა',
        lead: 'ადგილების ცოდნა აუცილებელია, მაგრამ გეოგრაფია მოსწავლისგან სივრცით მსჯელობას მოითხოვს.',
        tiles: [
          ['სივრცითი აზროვნება', 'სივრცის ცნებები, გამოსახვის საშუალებები და მსჯელობის პროცესები (NRC, 2006).'],
          ['კარტოგრაფიული წიგნიერება', 'პირობითი ნიშნების, მასშტაბის, ორიენტაციისა და კოორდინატების წაკითხვა; იმის გაგება, რას არ აჩვენებს რუკა.'],
          ['გეოგრაფიული მსჯელობა', 'ახსნა, რატომ არის მოვლენა იქ, სადაც არის; ადგილებისა და კანონზომიერებების შედარება.'],
          ['გეოგრაფიული ციფრული კომპეტენციები', 'ონლაინ რუკებთან, სივრცით მონაცემებთან და მათ ფორმატებთან თავისუფალი მუშაობა (შდრ. DigComp 2.2).'],
        ],
        note: 'ტიპური სირთულე: დაზეპირებული ფაქტი, რომლის გამოყენებაც მოსწავლეს ახალ რუკაზე არ შეუძლია.',
        cite: 'National Research Council, 2006; Vuorikari et al., 2022',
        notes: `დავიწყოთ პრობლემით. ბევრ კლასში გეოგრაფია ჯერ კიდევ ჩამონათვალების სწავლაა: დედაქალაქები, მდინარეები, განმარტებები. ეს საჭიროა, მაგრამ თავისთავად სივრცით მსჯელობის უნარს არ ქმნის.
აშშ-ის ეროვნული კვლევითი საბჭოს ანგარიში „Learning to Think Spatially“ სივრცით აზროვნებას სამი კომპონენტის ერთობლიობად აღწერს: სივრცის ცნებები, გამოსახვის საშუალებები, მაგალითად რუკა, და მსჯელობის პროცესები.
კარტოგრაფიული წიგნიერება და გეოგრაფიული მსჯელობა ამის პრაქტიკული გამოვლინებაა: მასშტაბისა და ორიენტაციის წაკითხვა და იმის ახსნა, რატომ არის მოვლენა სწორედ იქ. დღეს ამას ციფრული კომპეტენციებიც ემატება, რადგან მოსწავლე რუკას ძირითადად ეკრანზე ხედავს.
პრობლემა, რომელზეც ვმუშაობ, ცოდნის გადატანაა: მოსწავლემ შეიძლება ფაქტი იცოდეს, მაგრამ უცნობ რუკაზე ვერ გამოიყენოს.` },
      { key: 'ladder', title: 'რატომ უნდა დაიწყოს GIS-ის სწავლება სკოლაში',
        lead: 'GIS-ის უნარები ეტაპობრივად ყალიბდება, პროფესიულ პროგრამასთან შეხვედრამდე დიდი ხნით ადრე.',
        steps: [
          ['რუკის წაკითხვა', 'მასშტაბი, ფენები, ნიშნები', 'მოგზაურობა · ფოტო · ბარათები'],
          ['ზუსტი ლოკალიზაცია', 'კოორდინატები და დატუმი', 'კოორდინატები · დეტექტივი'],
          ['სივრცითი მონაცემის შექმნა', 'წერტილი, ხაზი, პოლიგონი', 'დახატე შენი უბანი'],
          ['გამოსახვა და დიზაინი', 'ლეგენდა, მასშტაბი, ფერი', 'გაფორმება · წრეები · ფაზლი'],
          ['ანალიზი', 'რელიეფი, თემატური მონაცემი', 'რელიეფისა და თემატური თამაშები*'],
          ['პროფესიული GIS', 'QGIS და სხვა დესკტოპ GIS', 'შემდეგი ნაბიჯი, GeoClass-ის გარეთ'],
        ],
        foot: '* დამატებითი თამაშები რეპოზიტორიის მიმდინარე ვერსიაში (რელიეფის პროფილი, ფერდობები, ხილვადობა, წყალშემკრები აუზი, თემატური რუკა).',
        cite: 'Bednarz, 2004; Kerski, 2003; Baker et al., 2015',
        notes: `რატომ სკოლაში? საშუალო სკოლაში GIS-ის გამოყენების კვლევები, მაგალითად კერსკის ნაშრომი და ბედნარზის მიმოხილვა, აჩვენებს როგორც შესაძლებლობებს, ისე ბარიერებს: პროგრამის სირთულეს, მასწავლებლის დროსა და აღჭურვილობას.
GeoClass ეტაპობრივ მიდგომას გვთავაზობს. სლაიდზე ნაჩვენები კიბე იწყება რუკის წაკითხვით, გრძელდება კოორდინატებით ლოკალიზაციით, მარტივი ვექტორული მონაცემის შექმნით, რუკის გაფორმებით და მარტივი ანალიზით. ყოველ საფეხურს თავისი თამაში შეესაბამება.
ზედა საფეხური, პროფესიული GIS, მაგალითად QGIS, შეგნებულად დარჩა აპის გარეთ. GeoClass GIS პროგრამას არ ცვლის; მისი მიზანია, GIS-ის ცნებებთან პირველი შეხება გაამარტივოს, რომ შემდეგ პროგრამამაც აზრი შეიძინოს.` },
      { key: 'workflow', title: 'GeoClass: კონცეფცია და არქიტექტურა',
        lead: 'მასწავლებლის მიერ მართული სესია, რომელიც მოსწავლეების საკუთარ მოწყობილობებზე მიმდინარეობს.',
        flow: ['მასწავლებელი ქმნის სესიას', 'QR კოდი ეკრანზე', 'მოსწავლეები ანგარიშის გარეშე შედიან', 'მოსწავლეები ხსნიან დავალებას', 'პასუხები მასწავლებლის რუკაზე', 'კლასში განხილვა'],
        tech: 'Flutter აპი (ერთი კოდი) → Cloudflare Worker (ვალიდაცია) → D1 / SQLite · განახლება ყოველ 3 წამში',
        cap1: 'მასწავლებელი: სესიის QR კოდი', cap2: 'მოსწავლის ტელეფონი: მოგზაურობის დავალება',
        cite: 'რეპოზიტორია: README.md, lib/, worker/src/index.ts',
        notes: `ასე მიმდინარეობს გაკვეთილი. მასწავლებელი ქმნის სესიას და ირჩევს თამაშს. აპი აჩვენებს QR კოდს. მოსწავლეები მას ტელეფონით ასკანერებენ, ანგარიშის შექმნის გარეშე, და ხსნიან დავალებას. პასუხები მასწავლებლის რუკაზე თითქმის მაშინვე ჩნდება და კლასი მათ განიხილავს.
ტექნიკურად, Flutter-ის ერთი კოდიდან იქმნება ვებ-, ანდროიდისა და დესკტოპის აპები. ყველა ჩანაწერი გადის პატარა სერვერზე, Cloudflare Worker-ზე, რომელიც თითოეულ პასუხს ბაზაში შენახვამდე ამოწმებს. ტელეფონები განახლებას ყოველ სამ წამში ითხოვენ, რაც ყველა პლატფორმაზე ერთნაირად მუშაობს.
მარჯვნივ ნაჩვენები სურათები ნამდვილი აპლიკაციიდანაა, ლოკალურ სატესტო სერვერზე, სადემონსტრაციო მონაცემებით.` },
      { key: 'games', title: 'ცხრა ძირითადი საგანმანათლებლო თამაში',
        lead: 'თითოეული თამაში მოსწავლის მოკლე აქტივობას გეოგრაფიულ უნართან აკავშირებს.',
        legend: ['მოსწავლის აქტივობა', 'ვარჯიშდება', 'მსჯელობა'],
        more: '1.0 ვერსიის შემდეგ რეპოზიტორიას ემატება კიდევ ცხრა: რელიეფის პროფილი, ციცაბო ფერდობები, ხილვადობა, წყალშემკრები აუზი, აუზი DEM-იდან, ყველაზე იოლი გზა, თემატური რუკა, 112: ადგილის შეტყობინება, თანამგზავრული ქრონიკა.',
        cite: 'README.md; lib/games/registry.dart',
        notes: `ეს არის ცხრა ძირითადი თამაში, რომლებიც პროექტის დოკუმენტაციაშია აღწერილი. ყველა ბარათს არ წავიკითხავ; ლოგიკას მივანიშნებ.
პირველი რიგი ლოკალიზაციას ეხება: ადგილის არჩევა, კოორდინატებთან მუშაობა და ადგილის ამოცნობა საჰაერო ფოტოთი. მეორე რიგი შექმნასა და შედარებას ეხება: წერტილების, ხაზებისა და პოლიგონების დახატვა, სხვადასხვა მასშტაბის ბარათების დაწყვილება და კოორდინატების დეტექტივი, სადაც მოსწავლე დოკუმენტიდან კოორდინატებს ამოიკითხავს, გადაიყვანს და ადგილს იპოვის. მესამე რიგი კარტოგრაფიულია: ფერი, რეგიონების ფორმები და რუკის გაფორმების ელემენტები.
ქვემოთ ჩანს, რომ მიმდინარე ვერსიაში უკვე კიდევ ცხრა თამაშია, მაგალითად რელიეფის პროფილი და წყალშემკრები აუზი საქართველოს ციფრულ სიმაღლეთა მოდელზე. ისინი ანალიტიკური GIS-ისკენ ბუნებრივი გაგრძელებაა, მაგრამ დღეს ცხრა ძირითად თამაშზე ვამახვილებ ყურადღებას.` },
      { key: 'matrix', title: 'თამაშის მექანიკიდან სივრცით აზროვნებამდე',
        lead: 'დიზაინის ჩანაფიქრი: სივრცითი აზროვნების რომელ ასპექტს ავითარებს თითოეული თამაში.',
        skills: { orientation: 'სივრცითი ორიენტაცია', coordinates: 'კოორდინატების ინტერპრეტაცია', scale: 'მასშტაბის აღქმა', patterns: 'კანონზომიერების ამოცნობა', relations: 'სივრცითი მიმართებები', interpretation: 'რუკის ინტერპრეტაცია', problem: 'პრობლემის გადაჭრა', hypothesis: 'ჰიპოთეზის ჩამოყალიბება' },
        short: { travel: 'მოგზ.', coords: 'კოორდ.', aerial: 'ფოტო', mapping: 'უბანი', cards: 'ბარათ.', detective: 'დეტექ.', plates: 'წრეები', puzzle: 'ფაზლი', layout: 'გაფორმ.' },
        key2: 'ძირითადი მიზანი', key1: 'დამატებითი მიზანი',
        cycle: ['კითხვა', 'სივრცითი გადაწყვეტილება', 'მყისიერი უკუკავშირი', 'რეფლექსია კლასში'],
        example: 'მაგალითი: „სად არის გადაღებული ეს ფოტო?“ → მოსწავლე რუკაზე მონიშნავს → აპი აცდენას კილომეტრებში აჩვენებს → კლასი ადარებს, რომელმა ნიშნებმა იმუშავა.',
        caveat: 'ეს მატრიცა ავტორის დიზაინის დასაბუთებაა და არა გაზომილი შედეგი.',
        notes: `როგორ უკავშირდება თამაშის მექანიკა სივრცით აზროვნებას? მატრიცა დიზაინის ჩანაფიქრს აჩვენებს: რომელ ასპექტს ავარჯიშებს თითოეული თამაში. შევსებული წრე ძირითადი მიზანია, რგოლი დამატებითი. ხაზგასმით ვიტყვი: ეს დასაბუთებაა და არა გაზომილი შედეგი.
უფრო მნიშვნელოვანია ციკლი მარჯვნივ. ყოველი დავალება იწყება კითხვით, მოითხოვს სივრცით გადაწყვეტილებას, იძლევა მყისიერ უკუკავშირს და ბრუნდება კლასში რეფლექსიისთვის. მაგალითად, საჰაერო ფოტოს თამაშში მოსწავლე რუკაზე მონიშნავს, ხედავს, რამდენით შეცდა, შემდეგ კი კლასი ადარებს, ლანდშაფტის რომელი ნიშნები იყო გამოსადეგი.
სწორედ გადაწყვეტილებიდან რეფლექსიამდე ეს მოძრაობა განასხვავებს მსჯელობას დაზეპირებისგან.` },
      { key: 'teacher', title: 'მასწავლებელი, როგორც სწავლის ფასილიტატორი',
        lead: 'GeoClass მასწავლებელს ეხმარება და არ ცვლის მას.',
        roles: ['ადგენს დავალებას', 'ირჩევს თამაშს', 'აწესებს სირთულესა და დროს', 'პასუხებს პირდაპირ ადევნებს თვალს', 'ავლენს მცდარ წარმოდგენებს', 'ითხოვს ახსნას', 'აძლევს განმავითარებელ უკუკავშირს', 'მორგებს შემდეგ აქტივობას'],
        lessonTitle: '45-წუთიანი გაკვეთილის ნიმუში',
        lesson: [['0–5', 'თემა, QR კოდი, მოსწავლეები შედიან'], ['5–15', 'კოორდინატები: DMS და UTM დავალებები'], ['15–22', 'ყველაზე დიდი აცდენების განხილვა რუკაზე'], ['22–37', 'დახატე შენი უბანი'], ['37–45', 'რეფლექსია; შედეგების ექსპორტი']],
        cap: 'მასწავლებლის ხედი: პასუხები რუკაზე; დამალვა ან წაშლა პროექტორზე ჩვენებამდე',
        cite: 'Black & Wiliam, 1998; README.md',
        notes: `ჩემთვის ეს ყველაზე მნიშვნელოვანი სლაიდია. ცენტრში მასწავლებელი რჩება. ის ადგენს დავალებას, ირჩევს თამაშს, აწესებს სირთულეს და დროს და ადევნებს თვალს, როგორ შემოდის პასუხები.
ცოცხალი რუკა მცდარ წარმოდგენებს ხილულს ხდის. თუ კლასის ნახევარი წერტილს სხვა ნახევარსფეროში სვამს, მასწავლებელი ამას მაშინვე ხედავს და შეუძლია იკითხოს: რატომ გადაწყვიტე ასე? ეს განმავითარებელი შეფასებაა ბლექისა და უილიამის გაგებით: ინფორმაცია, რომელიც სწავლების მორგებას სწავლის პროცესშივე ემსახურება.
მარცხნივ გაკვეთილის ნიმუშია და არა რეალური გაკვეთილის ანგარიში. მასწავლებელს შეუძლია პასუხი პროექტორზე ჩვენებამდე დამალოს ან წაშალოს, რაც მოსწავლეს უხერხულობისგან იცავს.` },
      { key: 'privacy', title: 'კონფიდენციალურობა დიზაინის ეტაპიდან და მოსწავლის დაცვა',
        lead: 'ტექნიკური ზომები, შემოწმებული პროგრამულ კოდში.',
        measures: [
          'მოსწავლის ანგარიში არ არსებობს; სახელს, ელფოსტას, ტელეფონს არ ვითხოვთ',
          'შემთხვევითი იდენტიფიკატორი იქმნება მოწყობილობაზე, ყოველ სესიაში ახალი',
          'პასუხები მხოლოდ ამ იდენტიფიკატორს უკავშირდება; ნიკი არასავალდებულოა',
          'მოსწავლეს შეუძლია საკუთარი პასუხების წაშლა ⓘ ფანჯრიდან',
          'მასწავლებელს შეუძლია ნებისმიერი პასუხის დამალვა ან წაშლა',
          'სესიები და პასუხები ავტომატურად იშლება 6 თვეში',
          'სერვერზე ინახება მხოლოდ QR ტოკენის ჰეში',
          'ყოველი პასუხი სერვერზე მოწმდება; უცნობი ველები იშლება',
          'არ გამოიყენება GPS, კამერა, cookie, რეკლამა ან ანალიტიკა',
        ],
        principles: ['მონაცემთა მინიმიზაცია', 'მიზნის შეზღუდვა', 'შენახვის ვადის შეზღუდვა', 'კონფიდენციალურობა დიზაინისა და ნაგულისხმევი პარამეტრების დონეზე', 'გამჭვირვალობა', 'მოსწავლის ღირსება'],
        pseudo: 'ფსევდონიმური და არა აბსოლუტურად ანონიმური: თავისუფალმა ტექსტმა ან არჩეულმა ნიკმა შეიძლება მოსწავლის ვინაობა გაამჟღავნოს. მოსწავლეებს ვთხოვთ, პირადი ინფორმაცია არ დაწერონ.',
        legal: 'შესაბამისი ჩარჩოები: GDPR (მუხ. 5, 25) და საქართველოს კანონი „პერსონალურ მონაცემთა დაცვის შესახებ“. ეს ტექნიკური ზომებია და არა სამართლებრივი შესაბამისობის სერტიფიკატი.',
        cap: 'კონფიდენციალურობის ფანჯარა მოსწავლის გვერდზე',
        cite: 'lib/queue.dart; worker/src/index.ts, validate.ts, retention.ts; web/privacy/',
        notes: `საგანმანათლებლო ტექნოლოგიები ხშირად ბევრად მეტ მონაცემს აგროვებს, ვიდრე სწავლებას სჭირდება. GeoClass პირიქით არის აგებული, და ამ სლაიდის თითოეული პუნქტი პროგრამულ კოდში შევამოწმე.
მოსწავლეს ანგარიში არ აქვს და სახელს ან საკონტაქტო მონაცემს არ ვთხოვთ. მოწყობილობა ქმნის შემთხვევით იდენტიფიკატორს, ყოველი სესიისთვის ახალს, ამიტომ ორი სესიის ერთმანეთთან დაკავშირება მისით შეუძლებელია. მოსწავლეს შეუძლია საკუთარი პასუხების წაშლა, მასწავლებელს პასუხის დამალვა ან წაშლა, ექვს თვეში კი ყველაფერი ავტომატურად იშლება. სერვერი ინახავს მხოლოდ QR ტოკენის ჰეშს, ამიტომ ბაზის გაჟონვაც კი მოქმედ ბმულებს არ გასცემს.
ტერმინოლოგიაში ზუსტი მინდა ვიყო: ეს ფსევდონიმურობაა და არა აბსოლუტური ანონიმურობა. ნიკმა ან თავისუფალმა ტექსტმა შეიძლება ადამიანის ვინაობა გაამჟღავნოს, ამიტომ მოსწავლეებს ვთხოვთ, პირადი მონაცემები არ დაწერონ.
ეს ზომები ეფუძნება GDPR-ის მე-5 და 25-ე მუხლების პრინციპებს და საქართველოს კანონს პერსონალურ მონაცემთა დაცვის შესახებ. თუმცა ტექნიკური ზომები სამართლებრივ შეფასებას არ ცვლის და სერტიფიცირებულ შესაბამისობას არ ვამტკიცებ.` },
      { key: 'standards', title: 'სტანდარტები, თავსებადობა და ღია გეოსივრცითი პრინციპები',
        lead: 'ერთი ადგილი, ჩაწერის ოთხი ფორმა: ყველა მათგანს იყენებს კოორდინატების თამაში და დეტექტივი.',
        place: 'თბილისი, WGS 84 (EPSG:4326)',
        formats: [['DD', '41.6938° N, 44.8015° E'], ['DM', '41°41.628′ N, 44°48.090′ E'], ['DMS', '41°41′38″ N, 44°48′05″ E'], ['UTM 38N', 'E 483 482 მ, N 4 615 799 მ (EPSG:32638)']],
        rows: [
          ['დატუმი და პროექცია', 'WGS 84; UTM-ის 37N/38N ზონები proj4-ით; Web Mercator საბაზო რუკები'],
          ['მონაცემთა ფორმატები', 'GeoJSON (RFC 7946), CSV და JSON ექსპორტი; აღდგენა სარეზერვო ასლიდან'],
          ['ღია მონაცემები', 'OpenStreetMap (ODbL), OpenTopoMap, Natural Earth, GeoNames, Copernicus DEM GLO-30'],
          ['ღია კოდი', 'MIT ლიცენზია; დაარქივებულია Zenodo-ზე, DOI-ით'],
        ],
        caveat: 'ფორმალურ OGC სერტიფიკაციას არ ვამტკიცებთ. ღია ფორმატები იმისთვისაა, რომ საკლასო მონაცემი პროფესიულ GIS-ში გაიხსნას.',
        cite: 'lib/coords.dart; lib/export.dart; README.md; RFC 7946; EPSG რეესტრი',
        notes: `GeoClass პატარაა, მაგრამ იმავე სტანდარტებს ეყრდნობა, რასაც პროფესიული GIS. ყველა კოორდინატი WGS 84 დატუმზეა. აპი ჩაწერის ოთხ ფორმას ასწავლის: ათობით გრადუსებს, გრადუსებსა და ათობით წუთებს, გრადუს-წუთ-წამებს და მართკუთხა UTM კოორდინატებს 37-ე და 38-ე ჩრდილოეთ ზონებში, რომლებიც საქართველოს ფარავს.
მაგალითში თბილისის ერთი და იგივე წერტილი ოთხივე ფორმითაა ჩაწერილი. მოსწავლე სწავლობს, რომ ეს სხვადასხვა ადგილი კი არა, ერთი ადგილის ჩაწერის სხვადასხვა გზაა. ეს საბაზისო, მაგრამ ხშირად გაუგებარი იდეაა.
„დახატე შენი უბანი“ თამაშში დახატული ობიექტები GeoJSON-ად ექსპორტდება და პირდაპირ QGIS-ში იხსნება. საბაზო რუკები და საზღვრები ღია მონაცემებიდანაა, მაგალითად OpenStreetMap-იდან, და წყარო ყოველთვის ჩანს. ფორმალურ OGC სერტიფიკაციას არ ვამტკიცებ; მთავარი თავსებადობა და პროფესიულ ინსტრუმენტებზე შეუფერხებელი გადასვლაა.` },
      { key: 'platforms', title: 'მრავალპლატფორმული ხელმისაწვდომობა',
        lead: 'Flutter-ის ერთი კოდი, ოთხი პლატფორმა: აღჭურვილობას სკოლა ირჩევს და არა აპი.',
        plats: [['ვები / PWA', 'ნებისმიერი ტელეფონი ან ლეპტოპი ბრაუზერით'], ['Android', 'ნატიური აპი; App Links ხსნის QR სესიას'], ['Windows', 'მასწავლებლის საკლასო კომპიუტერი'], ['Linux', 'სკოლის კომპიუტერული ლაბორატორია']],
        why: ['სკოლის განსხვავებული აღჭურვილობა', 'მოსწავლეების საკუთარი მოწყობილობები', 'მასწავლებლის საკლასო კომპიუტერი', 'ნაკლები დამოკიდებულება ერთ ოპერაციულ სისტემაზე'],
        conn: [
          'ვებაპის გარსს service worker ინახავს და ის ინტერნეტის გარეშეც იხსნება',
          'კავშირის გაწყვეტისას პასუხი მოწყობილობაზე ელოდება და მოგვიანებით, დუბლიკატის გარეშე იგზავნება',
          'ცოცხალ შედეგებს, რუკის ფილებს და სერვერს კავშირი სჭირდება',
        ],
        connTitle: 'ინტერნეტთან კავშირი: რა არის რეალიზებული',
        cite: 'pubspec.yaml; web/sw.js; lib/queue.dart; README.md',
        notes: `საქართველოს სკოლებს, ისევე როგორც სხვაგან, ძალიან განსხვავებული აღჭურვილობა აქვთ. ზოგ კლასში პლანშეტებია, ბევრგან მოსწავლეების საკუთარ ტელეფონებს ეყრდნობიან, მასწავლებელს კი ხშირად ერთი საკლასო კომპიუტერი აქვს.
GeoClass ერთი კოდიდან იქმნება ვებისთვის, როგორც პროგრესული ვებაპი, ანდროიდისთვის, Windows-ისა და Linux-ისთვის. მოსწავლეს შეუძლია უბრალოდ ბმული გახსნას ბრაუზერში; ინსტალაცია საჭირო არ არის.
ინტერნეტთან კავშირი რეალური შეზღუდვაა, ამიტომ ზუსტად აღვწერ. აპის გარსი შენახულია და ქსელის გარეშეც იხსნება. თუ პასუხის გაგზავნისას კავშირი გაწყდა, პასუხი მოწყობილობაზე ელოდება და მოგვიანებით იგზავნება, სერვერი კი დუბლიკატს უგულებელყოფს. მაგრამ ცოცხალ შედეგებსა და რუკის ფილებს ინტერნეტი სჭირდება; GeoClass სრულად ოფლაინ აპლიკაცია არ არის.` },
      { key: 'innovation', title: 'საგანმანათლებლო ინოვაცია: არასტანდარტული თამაშები',
        lead: 'დავალებები, რომლებიც ინტერპრეტაციას მოითხოვს და არა მხოლოდ გახსენებას.',
        cards: [
          ['კოორდინატების დეტექტივი', 'ამოიკითხე კოორდინატები სასწავლო დოკუმენტიდან, გადაიყვანე, იპოვე და დაასახელე', 'detective'],
          ['დახატე შენი უბანი', 'შექმენი წერტილები, ხაზები და პოლიგონები; GeoJSON ექსპორტი', null],
          ['რუკის ფაზლი', 'ააწყე საქართველო რეგიონებით ან მუნიციპალიტეტებით', 'puzzle'],
          ['საჰაერო ფოტო', 'დაუკავშირე ლანდშაფტის ნიშნები რუკაზე მდებარეობას', null],
          ['რუკის გაფორმება', 'ლეგენდა, სათაური, ჩრდილოეთის ისარი, მასშტაბი და ბადე A4-ზე', 'layout'],
          ['ფერების წრეები', 'ნებაყოფლობითი; კლასი ხმამაღლა პასუხობს და არაფერი იგზავნება', 'plates'],
        ],
        ped: ['კვლევაზე დაფუძნებული სწავლა', 'აქტიური სწავლა', 'განმავითარებელი შეფასება', 'ერთობლივი განხილვა', 'შეცდომებზე სწავლა'],
        caveat: 'ქულა განხილვის უკუკავშირია და არა გეოგრაფიული კომპეტენციის სრული საზომი.',
        cite: 'README.md; Freeman et al., 2014',
        notes: `ზოგიერთი თამაში, ვფიქრობ, სასკოლო გეოგრაფიისთვის უჩვეულოა. კოორდინატების დეტექტივში მოსწავლე იღებს აშკარად მონიშნულ სასწავლო დოკუმენტს, ჯარიმის ქვითარს ან ვიდეორეგისტრატორის კადრს, რომელზეც კოორდინატები ერთ ფორმატშია. მან ისინი უნდა გადაიყვანოს, ადგილი იპოვოს და დაასახელოს. ეს ყურადღებით კითხვისა და დასკვნის მცირე ვარჯიშია.
რუკის გაფორმების თამაში მოსწავლეს რუკის აწყობას სთხოვს: რეგიონების გაფერადებას ლეგენდის მიხედვით და სათაურის, ჩრდილოეთის ისრის, ლეგენდის, მასშტაბისა და ბადის განთავსებას. ფერების წრეები ფერის აღქმის ტესტების მსგავს ფირფიტებს იყენებს, რომ განვიხილოთ, რატომ არის რუკის ფერები მნიშვნელოვანი მათთვის, ვინც ფერს განსხვავებულად აღიქვამს; თამაში ნებაყოფლობითია და არაფერი იგზავნება.
შეცდომა დიზაინის ნაწილია: ცოცხალი რუკა მას აჩენს, განხილვა კი სწავლად აქცევს. მაგრამ ქულა განხილვის სიგნალია და არა გეოგრაფიული კომპეტენციის საზომი.` },
      { key: 'limits', title: 'შეზღუდვები და კვლევის შესაძლებლობები',
        lead: 'ემპირიული შეფასება ჯერ არ ჩატარებულა.',
        limTitle: 'შეზღუდვები',
        lims: ['სწავლის ეფექტი ჯერ არ არის გაზომილი', 'მოწყობილობებზე არათანაბარი წვდომა', 'დამოკიდებულება ინტერნეტზე', 'მასწავლებელს მომზადების დრო სჭირდება', 'სიჩქარეზე დაფუძნებულმა ქულამ შეიძლება აჩქარება დააჯილდოოს', 'ხელმისაწვდომობის ფორმალური აუდიტი ჯერ არ ჩატარებულა', 'დავალება ასაკს უნდა შეესაბამებოდეს (VI–IX კლასები)'],
        resTitle: 'შემოთავაზებული კვლევა',
        res: ['სივრცითი მსჯელობის წინასწარი და შემდგომი ტესტი', 'სტრუქტურირებული დაკვირვება გაკვეთილზე', 'ინტერვიუები მასწავლებლებთან', 'მოსწავლის ჩართულობის ანალიზი', 'გამოყენებადობის კვლევა (მაგ. SUS)', 'შედარება სწავლების სხვა მეთოდებთან', 'GIS-ის უნარების გრძელვადიანი კვლევა'],
        cite: 'Uttal et al., 2013; Baker et al., 2015',
        notes: `სამეცნიერო მოხსენებამ შეზღუდვებიც უნდა აღიაროს. მთავარი: GeoClass ემპირიულად შეფასებული არ არის. სწავლის ეფექტზე მონაცემი არ მაქვს და არც წარმოგიდგენთ.
პრაქტიკული შეზღუდვებიც არსებობს: ყველა მოსწავლეს მოწყობილობა არ აქვს, კავშირი არასტაბილურია, მასწავლებელს მომზადების დრო სჭირდება, დროზე დაფუძნებულმა ქულამ კი შეიძლება სიჩქარე ფრთხილ ფიქრზე მაღლა დააყენოს. ხელმისაწვდომობის აუდიტი ჯერ არ ჩატარებულა.
ეს შეზღუდვები კვლევის დღის წესრიგს განსაზღვრავს. ატალისა და კოლეგების მეტაანალიზი აჩვენებს, რომ სივრცითი უნარები ვარჯიშით ვითარდება, რაც შესამოწმებელ ჰიპოთეზას გვაძლევს. ვთავაზობ სივრცითი მსჯელობის წინასწარ და შემდგომ ტესტებს, გაკვეთილებზე დაკვირვებას, ინტერვიუებს მასწავლებლებთან, გამოყენებადობის კვლევას და, გრძელვადიან პერსპექტივაში, ლონგიტუდურ კვლევას. სიამოვნებით ვითანამშრომლებდი ამ დარბაზში მყოფ კოლეგებთან.` },
      { key: 'conclusion', title: 'დასკვნა',
        lead: 'GeoClass აჩვენებს, როგორ შეიძლება სასკოლო გეოგრაფია გახდეს:',
        words: ['უფრო ინტერაქციული', 'უფრო სივრცით ორიენტირებული', 'უფრო ხელმისაწვდომი', 'უფრო მასწავლებელზე ორიენტირებული', 'უფრო კონფიდენციალურობის მიმართ ყურადღებიანი', 'უფრო დაკავშირებული თანამედროვე GIS-თან'],
        closing: 'GIS-ში პირველი ნაბიჯი პროგრამა არ არის. ეს ცნობისმოყვარეობაა: სად არის რაიმე და რატომ.',
        notes: `შევაჯამებ. GeoClass იმის მაგალითია, როგორ შეიძლება ინტერაქციული გეოგრაფიული თამაშები GIS-ში პირველ ნაბიჯად იქცეს: ისინი ავითარებს კარტოგრაფიულ წიგნიერებას, კოორდინატებთან მუშაობისა და სივრცითი მსჯელობის უნარებს, ამავდროულად მასწავლებელს მართვას უტოვებს და რაც შეიძლება ნაკლებ მონაცემს აგროვებს.
პროექტი ღია კოდისაა და DOI-ით არის დაარქივებული, ამიტომ კოლეგებს შეუძლიათ მისი გამოყენება, მორგება და, რაც მთავარია, შეფასება.
დავასრულებ ერთი აზრით, ალექსანდრე ასლანიკაშვილის სულისკვეთებით, რომლისთვისაც რუკა შემეცნების საშუალება იყო: GIS-ში პირველი ნაბიჯი პროგრამა არ არის. ეს ცნობისმოყვარეობაა: სად არის რაიმე და რატომ.` },
      { key: 'refs', title: 'ლიტერატურა და წყაროები',
        refs: null, // same list as English: bibliographic entries stay in their original language
        notes: `წყაროები ჩამოთვლილია აქ და თანდართულ ფაილში. თავად პროგრამის ციტირება Zenodo-ს DOI-ით შეიძლება.` },
      { key: 'questions', title: 'კითხვები და დისკუსია',
        lead: 'გმადლობთ ყურადღებისთვის.',
        q: ['როგორ შევაფასოთ GeoClass საქართველოს სკოლებში?', 'GIS-ის რომელი ცნებები უნდა მოჰყვეს შემდეგ?', 'როგორ დავაბალანსოთ კონფიდენციალურობა და შეფასება?'],
        qr1: 'პროგრამული კოდი', qr2: 'DOI',
        notes: `გმადლობთ. სიამოვნებით მოვისმენ თქვენს კითხვებს, განსაკუთრებით მოსაზრებებს იმაზე, როგორ შეიძლება ასეთი ინსტრუმენტების შეფასება საქართველოს სკოლებში.` },
    ],
  },
};
T.ka.s.find((x) => x.key === 'refs').refs = T.en.s.find((x) => x.key === 'refs').refs;
