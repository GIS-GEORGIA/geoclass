# Publishing GeoClass on Google Play

The owner publishes by hand. Nothing here uploads automatically.

## Build

The upload key is outside the repository in `~/.android-keys/geoclass/`, and `android/key.properties` points to it. Keep an offline copy of both.

```bash
flutter build appbundle --release
```

Upload `build/app/outputs/bundle/release/app-release.aab`. Raise the number after `+` in `pubspec.yaml` for every upload.

## Listing

**App name:** GeoClass

**Short description (ka):** გეოგრაფიული თამაშები კლასისთვის: QR კოდი, პასუხები პირდაპირ რუკაზე.

**Short description (en):** Geography games for the classroom: scan a QR code, see answers on a live map.

**Full description (ka):**

> GeoClass საკლასო გეოგრაფიული თამაშების აპია. მასწავლებელი აჩვენებს QR კოდს, მოსწავლეები ტელეფონიდან ანონიმურად პასუხობენ და პასუხები პირდაპირ რუკაზე ჩნდება.
>
> რუკა და კოორდინატები:
> • სად გსურს მოგზაურობა? — მოსწავლეების არჩეული ადგილები ერთ რუკაზე.
> • კოორდინატების თამაში — გეოგრაფიული (DD, DM, DMS) და მართკუთხა (UTM) კოორდინატები, ქულა და რეიტინგი.
> • კოორდინატების დეტექტივი — ამოიკითხე კოორდინატები სასწავლო ჯარიმის ქვითრიდან ან ვიდეორეგისტრატორის კადრიდან, გადაიყვანე და იპოვე ადგილი.
> • 112: ადგილის შეტყობინება — სავარჯიშო ზარი: ამოიკითხე შენი ადგილი რუკიდან საჭირო ფორმატში, თქვი, რა მოხდა, და აირჩიე ყველაზე გამოსადეგი ფოტო.
> • გამოიცანი საჰაერო ფოტოდან — იპოვე ფოტოზე ნაჩვენები ადგილი რუკაზე.
> • თანამგზავრული ქრონიკა — შეადარე ორი წლის თანამგზავრული სურათი და შემოხაზე, რა შეიცვალა.
> • დახატე შენი უბანი — წერტილებით, ხაზებითა და პოლიგონებით დახატე რაც შეიძლება მეტი ობიექტი.
> • იპოვე ერთი და იგივე ადგილი — რუკის ბარათების წყვილები, სხვადასხვა მასშტაბითა და მობრუნებული.
>
> რელიეფი და წყალი (საქართველოს ციფრული რელიეფის მოდელზე):
> • რელიეფის პროფილი — წაიკითხე ჭრილი: ყველაზე მაღალი და დაბალი წერტილი, სიგრძე, ციცაბო მონაკვეთი.
> • ციცაბო ფერდობები — მონიშნე, სად არის ფერდობი არჩეულ კუთხეზე ციცაბო.
> • ხილვადობა — გამოიცანი, რას დაინახავს დამკვირვებელი მწვერვალიდან ან კოშკიდან.
> • წყალშემკრები აუზი — შემოხაზე მდინარის აუზი.
> • აუზი DEM-იდან (Level 2) — ნაბიჯ-ნაბიჯ: დინების მიმართულება, დაგროვება, ჩამონადენის წერტილი.
> • ყველაზე იოლი გზა — გაიყვანე ყველაზე ნაკლებად დამღლელი მარშრუტი მთაში.
>
> კარტოგრაფია:
> • თემატური რუკა — მასწავლებლის მონაცემებით შეარჩიე კლასები და ფერები.
> • რუკის გაფორმება — გააფორმე საქართველოს რუკა A4-ზე: სათაური, ლეგენდა, ჩრდილოეთის ისარი, მასშტაბი, ბადე და PDF.
> • რუკის ფაზლი — ააწყე საქართველოს რეგიონები ან მუნიციპალიტეტები.
> • ფერების წრეები — ნებაყოფლობითი თამაში: ფერადი წერტილებიდან ამოიცანი რეგიონი, კონტინენტი ან ქვეყანა. პასუხს მოსწავლეები ერთად, ხმამაღლა ამბობენ და არაფერი იგზავნება.
>
> მოსწავლეს არ სჭირდება ანგარიში, სახელი ან ელფოსტა, და აპი ტელეფონის მდებარეობას არ იყენებს. სესიები პასუხებიანად 6 თვეში იშლება. აპს აქვს ქართული და ინგლისური ენა, ღია და მუქი თემა. კოდი ღიაა: github.com/GIS-GEORGIA/geoclass

**Full description (en):**

> GeoClass runs geography games in the classroom. The teacher shows a QR code, students answer anonymously on their phones, and the answers appear live on a map.
>
> Maps and coordinates:
> • Where would you travel? — everyone's chosen places on one map.
> • Coordinates game — geographic (DD, DM, DMS) and rectangular (UTM) coordinates, with scores and a leaderboard.
> • Coordinate detective — read the coordinates off a sample fine receipt or a dashcam frame, convert them and find the place.
> • 112: reporting your location — a practice emergency call: read your place off the map in the format asked for, say what happened and pick the most useful photo.
> • Guess from aerial photos — find the place in the photo on the map.
> • Satellite time-lapse — compare satellite images from two years and outline what changed.
> • Map your neighbourhood — draw as many places as you can with points, lines and polygons.
> • Find the same place — match pairs of map cards shown at different scales and turned.
>
> Terrain and water (on a digital elevation model of Georgia):
> • Terrain profile — read a cross-section: highest and lowest point, length, steepest part.
> • Steep slopes — mark where the ground is steeper than a chosen angle.
> • What can be seen — guess what an observer on a summit or a tower can see.
> • Drainage basin — outline a river's basin.
> • Basin from the DEM (level 2) — step by step: flow direction, accumulation, pour point.
> • The easiest way — plan the least tiring route through the mountains.
>
> Cartography:
> • Thematic map — choose classes and colours for the teacher's data.
> • Map layout — lay out a map of Georgia on A4: title, legend, north arrow, scale bar, grid, PDF.
> • Map puzzle — put Georgia's regions or municipalities together.
> • Colour plates — a voluntary game: spot a region, continent or country in coloured dots. Students say the answer aloud together, and nothing is sent.
>
> Students need no account, name or email, and the app does not use the phone's location. Sessions and their answers are deleted after six months. Georgian and English, light and dark themes. Open source: github.com/GIS-GEORGIA/geoclass

**Category:** Education

**Privacy policy:** https://geoclass.qgis.ge/privacy/

**Graphics:** app icon `web/icons/Icon-maskable-512.png`, feature graphic `docs/play/feature-graphic.png`. Phone screenshots still need to be taken on a real phone.

## Console answers to check

These describe how the app works. The answers are the owner's to confirm.

**Ads:** none.

**App access:** teacher functions need a teacher key, so Play's reviewers need one under "App access". Don't give them the owner key: make a teacher account for them in the app (Settings → Teachers, a month is enough) and turn it off after the review. Students need no login, and a QR link works without one.

**Data safety:**

| Question | Answer |
|---|---|
| Collected | App activity: answers typed or chosen, including free text. Location is not collected: points are placed by hand. Device or other IDs: a random id made by the app. |
| Shared with third parties | No. Cloudflare only processes data on our behalf. |
| Encrypted in transit | Yes, HTTPS. |
| Can users ask for deletion | Yes, through the teacher or by email. There are no accounts to delete. |

**Target audience:** this needs a decision. Students may be under 13, and choosing an age group under 13 brings Google Play's Families policy into effect. Read that policy before answering. The app has no ads, accounts or analytics, which helps, but the free text field and the OpenStreetMap requests still need to be judged against it.

## After the first upload: opening QR links in the app

Play re-signs the app with its own key, and Android only opens links in the app when that key is listed on the site. Until then QR links open in the browser, which works fine.

1. In Play Console, open Test and release > App integrity > App signing and copy the SHA-256 of the app signing key.
2. Add it to `sha256_cert_fingerprints` in `web/.well-known/assetlinks.json`, next to the upload key.
3. Build the web app and deploy.
