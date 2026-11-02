import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'dart:math';

import 'package:geoclass/aerial_setup_page.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/coordinates_setup_page.dart';
import 'package:geoclass/coords.dart';
import 'package:geoclass/export.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/main.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/photos.dart';
import 'package:geoclass/nicknames.dart';
import 'package:geoclass/places.dart';
import 'package:geoclass/queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

TravelAnswer answer({
  String place = 'Paris',
  String country = 'FR',
  String reason = 'Art',
  String transport = 'plane',
  bool hidden = false,
}) =>
    TravelAnswer(
      id: 'id-$place',
      place: place,
      country: country,
      reason: reason,
      transport: transport,
      company: 'friends',
      lat: 48.85,
      lon: 2.35,
      hidden: hidden,
      createdAt: 1790000000,
    );

void main() {
  group('translations', () {
    test('both languages have the same keys', () {
      final ka = S.keys['ka']!.keys.toSet();
      final en = S.keys['en']!.keys.toSet();
      expect(ka.difference(en), isEmpty);
      expect(en.difference(ka), isEmpty);
    });

    test('every transport and company has a label', () {
      for (final lang in ['ka', 'en']) {
        for (final t in transports) {
          expect(S.keys[lang]!.containsKey('transport_$t'), isTrue);
        }
        for (final c in companies) {
          expect(S.keys[lang]!.containsKey('company_$c'), isTrue);
        }
      }
    });
  });

  group('join link', () {
    test('finds the token', () {
      expect(joinToken('/join/abc_DEF-123'), 'abc_DEF-123');
    });
    test('finds the token in a link opened by Android', () {
      expect(joinToken('/#/join/abc_DEF-123'), 'abc_DEF-123');
    });
    test('ignores other routes', () {
      expect(joinToken('/'), isNull);
      expect(joinToken(null), isNull);
      expect(joinToken('/join/'), isNull);
      expect(joinToken('/join/a/b'), isNull);
    });
  });

  group('export', () {
    test('CSV keeps Georgian, quotes and new lines, with a BOM', () {
      final csv = answersToCsv([answer(place: 'თბილისი', reason: 'say "hi"\nnow')]);
      expect(csv.startsWith('﻿place,'), isTrue);
      expect(csv, contains('"თბილისი"'));
      expect(csv, contains('"say ""hi""\nnow"'));
    });

    test('CSV cannot carry a spreadsheet formula', () {
      for (final bad in ['=1+1', '+1', '-1', '@x']) {
        expect(answersToCsv([answer(reason: bad)]), contains('"\'$bad"'));
      }
    });

    test('GeoJSON is lon, lat', () {
      final data = jsonDecode(answersToGeoJson([answer()])) as Map<String, dynamic>;
      expect(data['type'], 'FeatureCollection');
      final feature = (data['features'] as List).single as Map<String, dynamic>;
      expect(feature['geometry']['coordinates'], [2.35, 48.85]);
      expect(feature['properties']['place'], 'Paris');
    });

    test('counts skip hidden answers and sort by size', () {
      final counts = countBy([
        answer(place: 'Rome'),
        answer(place: 'Paris'),
        answer(place: 'Paris'),
        answer(place: 'Oslo', hidden: true),
      ], (a) => a.place);
      expect(counts.map((e) => e.key), ['Paris', 'Rome']);
      expect(counts.first.value, 2);
    });
  });

  group('places', () {
    final index = PlaceIndex.parse(
      'Tokyo\tტოკიო\tJP\t35.690\t139.692\n'
      'Paris\tპარიზი\tFR\t48.853\t2.349\n'
      'São Paulo\t\tBR\t-23.548\t-46.636\n'
      'Comparis\t\tFR\t45.000\t3.000\n',
      {
        'FR': ['France', 'საფრანგეთი'],
      },
    );

    test('finds Latin and Georgian names', () {
      expect(index.search('par').first.name, 'Paris');
      expect(index.search('პარიზ').single.name, 'Paris');
    });

    test('ignores accents', () {
      expect(index.search('sao paulo').single.name, 'São Paulo');
    });

    test('names that start with the query come first', () {
      expect(index.search('paris').map((p) => p.name), ['Paris', 'Comparis']);
    });

    test('ignores one letter', () {
      expect(index.search('p'), isEmpty);
    });

    test('finds the nearest place, across the date line too', () {
      expect(index.nearest(48, 3)!.name, 'Paris');
      expect(index.nearest(35, -179)!.name, 'Tokyo');
    });

    test('names follow the language', () {
      final paris = index.search('paris').first;
      expect(paris.label('ka'), 'პარიზი');
      expect(paris.label('en'), 'Paris');
      expect(index.countryName('FR', 'ka'), 'საფრანგეთი');
      expect(index.countryName('XX', 'en'), 'XX');
    });
  });

  group('offline queue', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps answers while offline and sends them in order later', () async {
      final sent = <String>[];
      var online = false;
      final queue = SubmissionQueue((item) async {
        if (!online) throw NoConnection();
        sent.add(item['submissionId'] as String);
      });
      await queue.add({'submissionId': 'a'});
      await queue.add({'submissionId': 'b'});

      expect(await queue.flush(), isNull);
      expect(await queue.pending(), 2);
      expect(sent, isEmpty);

      online = true;
      await queue.flush();
      expect(sent, ['a', 'b']);
      expect(await queue.pending(), 0);
    });

    test('survives a restart', () async {
      final first = SubmissionQueue((_) async => throw NoConnection());
      await first.add({'submissionId': 'a'});
      await first.flush();
      final second = SubmissionQueue((_) async {});
      expect(await second.pending(), 1);
    });

    test('drops an answer the server refuses, and reports why', () async {
      final queue = SubmissionQueue((_) async => throw ApiError(409, 'session_closed'));
      await queue.add({'submissionId': 'a'});
      expect(await queue.flush(), 'session_closed');
      expect(await queue.pending(), 0);
    });

    test('keeps an answer on a server failure or rate limit', () async {
      for (final status in [429, 500, 503]) {
        SharedPreferences.setMockInitialValues({});
        final queue = SubmissionQueue((_) async => throw ApiError(status, 'x'));
        await queue.add({'submissionId': 'a'});
        await queue.flush();
        expect(await queue.pending(), 1);
      }
    });

    test('participant id stays the same on one device', () async {
      final a = await participantId();
      expect(await participantId(), a);
      expect(a.length, greaterThanOrEqualTo(8));
      expect(RegExp(r'^[A-Za-z0-9_-]+=*$').hasMatch(a), isTrue);
    });
  });

  group('coordinates', () {
    // Reference values from pyproj 3.6.1.
    const known = [
      ('Tbilisi', 41.6938, 44.8015, 38, 483482.123, 4615799.131),
      ('Batumi', 41.6168, 41.6367, 37, 719679.697, 4610589.733),
      ('Kazbegi', 42.6569, 44.6433, 38, 470764.711, 4722776.936),
      ('On the zone edge', 42.0, 42.0, 38, 251535.079, 4654130.892),
      ('Mestia', 43.0453, 42.7294, 38, 315059.773, 4768347.314),
    ];

    test('UTM matches pyproj to within a centimetre or so', () {
      for (final (name, lat, lon, zone, e, n) in known) {
        final u = toUtm(lat, lon);
        expect(u.zone, zone, reason: name);
        expect(u.easting, closeTo(e, 0.05), reason: name);
        expect(u.northing, closeTo(n, 0.05), reason: name);
      }
    });

    test('UTM goes there and back', () {
      for (final (_, lat, lon, zone, e, n) in known) {
        final p = fromUtm(zone, e, n);
        expect(p.latitude, closeTo(lat, 1e-5));
        expect(p.longitude, closeTo(lon, 1e-5));
      }
    });

    test('every written format can be read back', () {
      for (final (name, lat, lon, _, _, _) in known) {
        final dd = parseDd(formatDd(lat, lon))!;
        expect(dd.latitude, closeTo(lat, 1e-4), reason: name);
        final dms = parseDms(formatDms(lat, lon))!;
        expect(dms.latitude, closeTo(lat, 3e-4), reason: name);
        expect(dms.longitude, closeTo(lon, 3e-4), reason: name);
        final utm = parseUtm(formatUtm(lat, lon))!;
        expect(utm.latitude, closeTo(lat, 1e-4), reason: name);
        expect(utm.longitude, closeTo(lon, 1e-4), reason: name);
      }
    });

    test('DMS rounding never shows 60 seconds', () {
      expect(formatDms(41.99999, 44.99999), '42°00′00″ N, 45°00′00″ E');
    });

    test('negative coordinates are written with S and W', () {
      expect(formatDms(-23.5, -46.25), '23°30′00″ S, 46°15′00″ W');
      expect(dmsTick(41), '41°');
      expect(dmsTick(41 + 5 / 60), '41°05′');
      expect(dmsTick(41 + 40 / 60 + 30 / 3600), '41°40′30″');
      expect(dmsTick(-23.5), '-23°30′');
      expect(dmTick(41), '41°');
      expect(dmTick(41 + 40 / 60), '41°40′');
      expect(dmTick(41 + 5.5 / 60), '41°05.5′');
      expect(dmTick(41 + 40.25 / 60), '41°40.25′');
      expect(formatDm(41.5, 44.75), '41°30.000′ N, 44°45.000′ E');
      final dm = parseAs('dm', formatDm(-23.5125, -46.25))!;
      expect(dm.latitude, closeTo(-23.5125, 1e-6));
      expect(dm.longitude, closeTo(-46.25, 1e-6));
    });

    test('the answer frame makes an answer the parser reads', () {
      final joined = joinBoxes('dms', ['41', '7', '', '44', '48', '5']);
      expect(joined, '41°07′00″ N, 44°48′05″ E');
      expect(parseAs('dms', joined)!.latitude, closeTo(41 + 7 / 60, 1e-9));
      expect(parseAs('dms', joinBoxes('dms', ['23', '30', '', '46', '', ''], south: true, west: true))!.longitude, closeTo(-46, 1e-9));
      expect(parseAs('dms', joinBoxes('dms', ['41', '75', '', '44', '', ''])), isNull);
      expect(joinBoxes('dms', ['', '30', '', '44', '', '']), '');
      final dm = parseAs('dm', joinBoxes('dm', ['41', '7,5', '44', '48']))!;
      expect(dm.latitude, closeTo(41 + 7.5 / 60, 1e-9));
      expect(dm.longitude, closeTo(44.8, 1e-9));
      final dd = parseAs('dd', joinBoxes('dd', ['41,69', '44.8'], west: true))!;
      expect(dd.latitude, closeTo(41.69, 1e-9));
      expect(dd.longitude, closeTo(-44.8, 1e-9));
      final utm = toUtm(41.69, 44.8);
      final back = parseAs('utm', joinBoxes('utm', ['${utm.easting.round()}', '${utm.northing.round()}'], zone: utm.zone))!;
      expect(back.latitude, closeTo(41.69, 1e-4));
      expect(joinBoxes('utm', ['483482', ''], zone: 38), '');
    });

    test('DD accepts common ways of typing', () {
      for (final text in ['41.69, 44.8', '41.69 44.8', '41.69;44.8', '41,69 44,8', '41.69° 44.8°', '41.69 N 44.8 E', '41.69N, 44.8E']) {
        final p = parseDd(text);
        expect(p, isNotNull, reason: text);
        expect(p!.latitude, closeTo(41.69, 1e-9), reason: text);
        expect(p.longitude, closeTo(44.8, 1e-9), reason: text);
      }
      expect(parseDd('-23.5 -46.25')!.longitude, -46.25);
    });

    test('DMS accepts common ways of typing', () {
      for (final text in ['41 41 24 44 48 0', '41°41\'24"N 44°48\'00"E', '41° 41′ 24″, 44° 48′ 0″', '41 41.4 44 48']) {
        final p = parseDms(text);
        expect(p, isNotNull, reason: text);
        expect(p!.latitude, closeTo(41.69, 1e-6), reason: text);
        expect(p.longitude, closeTo(44.8, 1e-6), reason: text);
      }
    });

    test('UTM accepts a zone, or takes it from the task', () {
      for (final text in ['38N 483482 4615799', '38 483482 4615799', '38T 483482 4615799', '38N, 483482, 4615799']) {
        expect(parseUtm(text)!.latitude, closeTo(41.6938, 1e-4), reason: text);
      }
      expect(parseUtm('483482 4615799', zone: 38)!.longitude, closeTo(44.8015, 1e-4));
      expect(parseUtm('483482 4615799'), isNull);
    });

    test('nonsense is refused', () {
      for (final text in ['', 'abc', '41', '95 44', '41 190', '1 2 3']) {
        expect(parseDd(text), isNull, reason: text);
      }
      for (final text in ['', 'abc', '41 75 0 44 0 0', '41 0 75 44 0 0', '1 2 3', '95 0 0 44 0 0']) {
        expect(parseDms(text), isNull, reason: text);
      }
      for (final text in ['', 'abc', '99N 483482 4615799', '38N 5 4615799', '38N 483482 99999999']) {
        expect(parseUtm(text), isNull, reason: text);
      }
    });

    test('the teacher box reads any format', () {
      expect(parseAny('41.69, 44.8')!.latitude, closeTo(41.69, 1e-9));
      expect(parseAny('38N 483482 4615799')!.latitude, closeTo(41.6938, 1e-4));
      expect(parseAny('41°41′24″ N, 44°48′00″ E')!.latitude, closeTo(41.69, 1e-6));
      expect(parseAny('nonsense'), isNull);
    });

    test('distance and score match the server', () {
      // The same cases are in worker/test/api.test.ts.
      expect(distanceM(41.7, 44.8, 41.7, 44.8), 0);
      expect(scoreFor(distanceM(41.79, 44.8, 41.7, 44.8)), 50);
      expect(scoreFor(distanceM(43, 44.8, 41.7, 44.8)), 0);
      expect(scoreFor(999), 100);
      expect(scoreFor(1000), 100);
      expect(scoreFor(100000), 0);
      expect(distanceM(41.7, 44.8, 42.27, 42.7), closeTo(183000, 2000));
    });

    test('distances read naturally', () {
      expect(formatDistance(350), '350 m');
      expect(formatDistance(1500), '1.50 km');
      expect(formatDistance(25000), '25.0 km');
    });

    test('links open the right point', () {
      expect(googleMapsUrl(41.5, 44.5).toString(), contains('query=41.5,44.5'));
      expect(osmUrl(41.5, 44.5).toString(), contains('mlat=41.5&mlon=44.5'));
    });

    test('nicknames stay the same and follow the language', () {
      expect(nickname('abc-123', 'ka'), nickname('abc-123', 'ka'));
      expect(nickname('abc-123', 'ka'), isNot(nickname('abc-123', 'en')));
      final names = {for (var i = 0; i < 200; i++) nickname('participant-$i', 'en')};
      expect(names.length, greaterThan(100));
    });

    test('random tasks use named Georgian places and the chosen settings', () {
      final index = PlaceIndex.parse(
        'Tbilisi\tთბილისი\tGE\t41.7\t44.8\n'
        'Batumi\tბათუმი\tGE\t41.6\t41.6\n'
        'Unnamed\t\tGE\t42\t43\n'
        'Paris\tპარიზი\tFR\t48\t2\n',
        const {},
      );
      final mixed = randomTasks(index, 5, 'mix', 'mix', random: Random(1));
      expect(mixed, hasLength(2));
      expect(mixed.map((t) => t.label).toSet(), {'თბილისი', 'ბათუმი'});
      expect(mixed.map((t) => t.mode).toSet(), {'to_map', 'read'});
      final fixed = randomTasks(index, 1, 'read', 'utm', random: Random(1)).single;
      expect(fixed.mode, 'read');
      expect(fixed.format, 'utm');
    });

    final tasks = [const CoordTask(lat: 41.7, lon: 44.8, mode: 'to_map', format: 'dd')];
    CoordAnswer coordAnswer(String who, int score, {int round = 0, String raw = ''}) => CoordAnswer(
          id: '$who-$round',
          participantId: who,
          raw: raw,
          round: round,
          score: score,
          lat: 41.71,
          lon: 44.81,
          distanceM: 1234.5,
          createdAt: 1790000000,
        );

    test('leaderboard adds up each student', () {
      final rows = leaderboard([
        coordAnswer('a', 50),
        coordAnswer('b', 90),
        coordAnswer('a', 60, round: 1),
      ]);
      expect(rows.map((r) => r.participantId), ['a', 'b']);
      expect(rows.first.score, 110);
      expect(rows.first.answered, 2);
    });

    test('equal totals rank the one with fewer tries first', () {
      final rows = leaderboard([
        coordAnswer('a', 50),
        coordAnswer('a', 50, round: 1),
        coordAnswer('b', 100),
      ]);
      expect(rows.first.participantId, 'b');
    });

    test('exports keep the typed text safe and include distance', () {
      final csv = coordAnswersToCsv([coordAnswer('a', 80, raw: '=1+1')], tasks, 'en');
      expect(csv, contains('"\'=1+1"'));
      expect(csv, contains(',1235,80,41.7,44.8,'));
      final data = jsonDecode(coordAnswersToGeoJson([coordAnswer('a', 80)], tasks, 'en')) as Map<String, dynamic>;
      final feature = (data['features'] as List).single as Map<String, dynamic>;
      expect(feature['geometry']['coordinates'], [44.81, 41.71]);
      expect(feature['properties']['score'], 80);
    });
  });

  group('aerial photos', () {
    test('the list reads good entries and leaves out mistakes', () {
      final photos = parsePhotos('''[
        {"file": "p01.jpg", "ka": "თბილისი", "en": "Tbilisi", "lat": 41.7, "lon": 44.8},
        {"file": "p02.webp", "ka": "ქუთაისი", "lat": 42, "lon": 42},
        {"file": "../p03.jpg", "ka": "x", "lat": 1, "lon": 1},
        {"file": "p04.jpg", "ka": "", "lat": 1, "lon": 1},
        {"file": "p05.jpg", "ka": "x", "lat": 95, "lon": 1},
        {"file": "p06.jpg", "ka": "x", "lon": 1},
        "nonsense"
      ]''');
      expect(photos.map((p) => p.file), ['p01.jpg', 'p02.webp']);
      expect(photos[0].en, 'Tbilisi');
      expect(photos[1].lat, 42.0);
    });

    test('a task keeps its photo and uses the right language', () {
      const photo = Photo(file: 'p.jpg', ka: 'თბილისი', en: 'Tbilisi', lat: 41.7, lon: 44.8);
      final task = CoordTask.fromJson(taskFromPhoto(photo).toJson());
      expect(task.photo, 'p.jpg');
      expect(task.mode, 'photo');
      expect(task.labelFor('ka'), 'თბილისი');
      expect(task.labelFor('en'), 'Tbilisi');
      expect(const CoordTask(lat: 1, lon: 1, mode: 'photo', format: 'dd', label: 'ბათუმი').labelFor('en'), 'ბათუმი');
    });

    // Fails with a clear message when a photo is added with a mistake.
    test('every entry in web/aerial/index.json is valid and its file exists', () {
      final raw = File('web/aerial/index.json').readAsStringSync();
      expect(parsePhotos(raw).length, (jsonDecode(raw) as List).length, reason: 'an entry has a mistake');
      for (final p in parsePhotos(raw)) {
        expect(File('web/aerial/${p.file}').existsSync(), isTrue, reason: '${p.file} is listed but missing');
      }
    });
  });
}
