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
> თამაშები:
> • სად გსურს მოგზაურობა? — მოსწავლეების არჩეული ადგილები ერთ რუკაზე.
> • კოორდინატების თამაში — გეოგრაფიული (DD, DM, DMS) და მართკუთხა (UTM) კოორდინატები, ქულა და რეიტინგი.
> • გამოიცანი საჰაერო ფოტოდან — იპოვე ფოტოზე ნაჩვენები ადგილი რუკაზე.
> • კოორდინატების დეტექტივი — ამოიკითხე კოორდინატები სასწავლო ჯარიმის ქვითრიდან ან ვიდეორეგისტრატორის კადრიდან, გადაიყვანე სხვა ფორმატში, იპოვე რუკაზე და დაასახელე ობიექტი.
> • დახატე შენი უბანი — წერტილებით, ხაზებითა და პოლიგონებით დახატე რაც შეიძლება მეტი ობიექტი მასწავლებლის დათქმულ დროში.
> • იპოვე ერთი და იგივე ადგილი — იპოვე რუკის ბარათების წყვილები, სხვადასხვა მასშტაბითა და მობრუნებული.
> • ფერების წრეები — ნებაყოფლობითი თამაში: ფერადი წერტილებიდან ამოიცანი საქართველოს რეგიონი, მუნიციპალიტეტი, კონტინენტი ან ქვეყანა. წრეს მასწავლებელი ცვლის, მოსწავლეები მას ტელეფონზეც ხედავენ და პასუხს ერთად, ხმამაღლა ამბობენ. პასუხი არ იგზავნება.
>
> მოსწავლეს არ სჭირდება ანგარიში, სახელი ან ელფოსტა. აპს აქვს ქართული და ინგლისური ენა, ღია და მუქი თემა. კოდი ღიაა: github.com/GIS-GEORGIA/geoclass

**Full description (en):**

> GeoClass runs geography games in the classroom. The teacher shows a QR code, students answer anonymously on their phones, and the answers appear live on a map.
>
> Games:
> • Where would you travel? — everyone's chosen places on one map.
> • Coordinates game — geographic (DD, DM, DMS) and rectangular (UTM) coordinates, with scores and a leaderboard.
> • Guess from aerial photos — find the place in the photo on the map.
> • Coordinate detective — read the coordinates off a sample fine receipt or a dashcam frame, convert them, find the place on the map and name it.
> • Map your neighbourhood — draw as many places as you can with points, lines and polygons, within the time the teacher sets.
> • Find the same place — match pairs of map cards shown at different scales and turned.
> • Colour plates — a voluntary game: spot a region or municipality of Georgia, a continent or a country in coloured dots. The teacher moves the plates, students see them on their phones too and say the answer aloud together. No answer is sent.
>
> Students need no account, name or email. Georgian and English, light and dark themes. Open source: github.com/GIS-GEORGIA/geoclass

**Category:** Education

**Privacy policy:** https://geoclass.qgis.ge/privacy/

**Graphics:** app icon `web/icons/Icon-maskable-512.png`, feature graphic `docs/play/feature-graphic.png`. Phone screenshots still need to be taken on a real phone.

## Console answers to check

These describe how the app works. The answers are the owner's to confirm.

**Ads:** none.

**App access:** teacher functions need the teacher key, so Play's reviewers need it under "App access". Students need no login, and a QR link works without one. Treat a key given to reviewers as shared, and replace it with `npm run key` in `worker/` if needed.

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
