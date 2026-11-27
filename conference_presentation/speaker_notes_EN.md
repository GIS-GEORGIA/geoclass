# Speaker notes: GeoClass: Geography Games as a First Step toward GIS Education

## 1. GeoClass: Geography Games as a First Step toward GIS Education

Good afternoon. It is an honour to speak at a conference that commemorates the 110th anniversary of Alexander Aslanikashvili, whose work reminds us that a map is not only a picture but a way of thinking about space.
My talk is about GeoClass, an open-source classroom environment that I see as a small, practical bridge between school geography and geographic information systems.
I will describe what is implemented, why it is designed this way, and what still has to be tested. I will be careful to separate these three things, because the project has not yet been evaluated in a formal study.

## 2. The educational challenge: beyond place names

Let me start with the problem. In many classrooms geography is still learned as lists: capitals, rivers, definitions. These are useful, but they do not automatically build the ability to reason with space.
The National Research Council's report "Learning to Think Spatially" describes spatial thinking as three things working together: concepts of space, tools of representation such as maps, and processes of reasoning.
Map literacy and geographic reasoning are the practical forms of this: reading scale and orientation, and explaining why a phenomenon is located where it is. Today we also have to add digital competencies, because students meet maps mostly on screens.
The difficulty I want to address is transfer: a student may know a fact, yet be unable to use it on an unfamiliar map.

## 3. Why GIS education should begin at school

Why at school? Research on GIS in secondary education, for example Kerski's work and Bednarz's review, shows both the promise and the barriers: software complexity, teacher time and hardware.
GeoClass takes a stepwise approach. The ladder on the slide starts with reading a map, then locating with coordinates, then creating simple vector data, then designing a map, then simple analysis. Each step has a game behind it.
The top step, professional GIS such as QGIS, is deliberately outside the app. GeoClass is not a replacement for GIS software; it is meant to make the first contact with GIS concepts easier, so that later the software makes sense.

## 4. GeoClass: concept and architecture

This is how a lesson works. The teacher creates a session and chooses a game. The app shows a QR code. Students scan it with their phones, without creating accounts, and solve the task. Their answers appear on the teacher's map almost immediately, and the class discusses them.
Technically, one Flutter codebase produces the web, Android and desktop apps. All writes go through a small server, a Cloudflare Worker, which validates every answer before storing it in a database. Phones ask for updates every three seconds, which works the same way on every platform.
The screenshots on the right are from the real application, running on a local test server with demonstration data.

## 5. Nine core educational games

These are the nine core games described in the project documentation. I will not read every card; let me point out the logic.
The first row is about locating: choosing a place, working with coordinates, and recognising a place from an aerial photo. The second row is about creating and comparing: drawing points, lines and polygons, matching map cards at different scales, and the coordinate detective, which asks students to read coordinates from a document, convert them and find the place. The third row is cartographic: colour, the shapes of regions, and the elements of a map layout.
At the bottom you see that the current version already contains nine further games, for example terrain profiles and drainage basins on a digital elevation model of Georgia. They are a natural continuation towards analytical GIS, but today I focus on the nine core games.

## 6. From game mechanics to spatial thinking

How do game mechanics relate to spatial thinking? The matrix shows the design intent: which aspects each game is meant to exercise. A filled circle is a primary aim, a ring a secondary one. I want to be clear that this is a rationale, not a measured result.
More important is the cycle on the right. Each task starts with a question, requires a spatial decision, gives immediate feedback, and then returns to the class for reflection. In the aerial photo game, for example, the student taps the map, sees how far off the guess was, and then the class compares which clues in the landscape were useful.
This movement from decision to reflection is what distinguishes reasoning from memorisation.

## 7. The teacher as a learning facilitator

This is, for me, the most important slide. The teacher remains at the centre. The teacher designs the task, selects the game, sets the difficulty and the clock, and watches the answers arrive.
The live map makes misconceptions visible. If half of the class puts a point in the wrong hemisphere, the teacher sees it immediately and can ask: why did you decide this? This is formative assessment in the sense of Black and Wiliam: information used to adapt teaching while learning is still happening.
On the left is an illustrative lesson plan, not a report from a real lesson. Note that the teacher can hide or delete an answer before projecting the map, which protects students from embarrassment.

## 8. Privacy by design and student confidentiality

Educational technology often collects far more data than teaching requires. GeoClass was designed the other way round, and I verified each point on this slide in the source code.
Students have no accounts and are not asked for a name or contact. The device creates a random identifier, a new one for every session, so two sessions cannot be linked through it. A student can erase their own answers; the teacher can hide or delete answers; and everything is deleted automatically after six months. The server stores only a hash of the QR token, so a leaked database would not reveal working links.
I want to be precise about terminology. This is pseudonymity, not absolute anonymity. A nickname or a free-text answer could still identify someone, which is why students are asked not to write personal details.
These measures follow principles of the GDPR, Articles 5 and 25, and the Georgian law on personal data protection. But technical measures are not the same as a legal assessment, and I do not claim certified compliance.

## 9. Standards, interoperability and open geospatial principles

GeoClass is small, but it is built on the same standards as professional GIS. All coordinates are on the WGS 84 datum. The app teaches four notations: decimal degrees, degrees and decimal minutes, degrees-minutes-seconds, and rectangular UTM coordinates in zones 37 and 38 North, which cover Georgia.
The example shows the same point in Tbilisi in all four notations. Students learn that these are not different places but different ways of writing one place, which is a basic but often misunderstood idea.
Drawings from the mapping race can be exported as GeoJSON and opened directly in QGIS. The base maps and boundaries come from open data such as OpenStreetMap, with attribution always visible. I do not claim formal OGC certification; the point is interoperability and a smooth transition to professional tools.

## 10. Multiplatform accessibility

Schools in Georgia, as elsewhere, have very different equipment. Some classes have tablets, many rely on students' own phones, and the teacher often has one classroom computer.
GeoClass is built from one codebase for the web as a progressive web app, for Android, Windows and Linux. A student can simply open a link in a browser; no installation is required.
Connectivity is a real constraint, so I want to describe it accurately. The application shell is cached and opens without a network. If the connection drops while a student answers, the answer waits on the device and is sent later, and the server ignores duplicates. But live results and map tiles need the internet; GeoClass is not a fully offline application.

## 11. Educational innovation: non-standard games

Some of the games are, I think, unusual for school geography. The coordinate detective gives students a clearly marked training document, a fine receipt or a dashcam frame, with coordinates in one format. They must convert them, find the place and name it. It is a small exercise in careful reading and inference.
The map layout game asks students to compose a map: colour the regions according to a legend and place the title, north arrow, legend, scale bar and grid. The colour plates game uses colour-vision-style plates to start a discussion about why map colours matter for people who see colour differently; it is voluntary and nothing is sent.
Mistakes are part of the design: the live map shows them, and the discussion turns them into learning. But a score is a signal for discussion, not a measure of geographic competence.

## 12. Limitations and research opportunities

A scientific presentation must state its limitations. The most important one: GeoClass has not been evaluated empirically. I have no data on learning effects, and I will not present any.
There are also practical limits: not every student has a device, connectivity varies, teachers need time to prepare, and timed scoring can reward speed over careful thinking. An accessibility audit has not been done yet.
These limits define a research agenda. Meta-analytic work by Uttal and colleagues shows that spatial skills can be trained, which gives us a testable hypothesis. I propose pre- and post-tests of spatial reasoning, classroom observation, teacher interviews, usability studies and, in the longer term, a longitudinal study. I would welcome collaboration with colleagues in this room.

## 13. Conclusion

To conclude. GeoClass is an example of how interactive geographic games can become a first step toward GIS: they build map literacy, coordinate skills and spatial reasoning, while leaving the teacher in control and collecting as little data as possible.
It is open source and archived with a DOI, so colleagues can use it, adapt it and, most importantly, evaluate it.
I would like to finish with one thought, in the spirit of Alexander Aslanikashvili's view of the map as a means of knowing: the first step into GIS is not software. It is curiosity about where things are, and why.

## 14. References

The references are listed here and in the accompanying source file. The software itself can be cited through its Zenodo DOI.

## 15. Questions and discussion

Thank you. I would be glad to hear your questions, and especially your views on how such tools could be evaluated in Georgian schools.

---

1666 words in total, about 12 minutes at 135 words per minute.
