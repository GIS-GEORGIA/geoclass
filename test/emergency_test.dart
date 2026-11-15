import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/coords.dart';
import 'package:geoclass/emergency/emergency.dart';
import 'package:geoclass/emergency/emergency_play.dart';
import 'package:geoclass/emergency/emergency_session_page.dart';
import 'package:geoclass/emergency/emergency_setup.dart';
import 'package:geoclass/games/emergency.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/l10n.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const s = S('ka');
  final cases = jsonDecode(File('test/fixtures/emergency/formats.json').readAsStringSync()) as Map<String, dynamic>;

  const truth = (lat: 41.7151, lon: 44.8271);
  const facts = Facts(kind: 'injury', people: 2, injured: true, landmark: 'TV tower');
  EmergencyAnswer answer({
    String coords = '41°42.906′ N, 44°49.626′ E',
    ({double lat, double lon})? at = truth,
    String kind = 'injury',
    int people = 2,
    bool injured = true,
    String landmark = 'below the TV tower',
    String photo = 'b',
  }) => EmergencyAnswer(
    coords: coords,
    at: at,
    kind: kind,
    people: people,
    injured: injured,
    landmark: landmark,
    photo: photo,
  );

  group('rules shared with the server', () {
    test('formats are classified as the Worker does (test/fixtures/emergency/formats.json)', () {
      for (final c in cases['formats'] as List) {
        expect(classifyCoords(c[0] as String), c[1], reason: c[0] as String);
      }
    });

    test('what the app itself writes in each format is classified as that format, and reads back', () {
      // Both UTM zones of Georgia, and both sides of the 42° meridian.
      for (final (lat, lon) in [(41.7151, 44.8271), (42.6576, 44.6419), (41.6168, 41.6367), (43.0453, 42.7294)]) {
        for (final f in emergencyFormats) {
          final text = formatAs(f, lat, lon);
          expect(classifyCoords(text), f, reason: text);
          final back = readCoords(text)!;
          // DMS is written to the whole second (about 31 m of latitude), the rest more finely.
          expect(distanceM(back.lat, back.lon, lat, lon), lessThan(f == 'dms' ? 25 : 3), reason: text);
        }
      }
    });

    test('distance points: 40 within 50 m, a log scale to 0 at 5 km', () {
      for (final c in cases['distance'] as List) {
        expect(distancePoints((c[0] as num?)?.toDouble()), c[1], reason: '${c[0]}');
      }
    });

    test('the distances scored are PROJ geod’s (WGS84) to within 0.3%, and give the same points', () {
      // geod +ellps=WGS84 -I +units=m: 41.7151 44.8271 to 41.7196 44.8271, and to 41.7160 44.8290.
      for (final (lat, lon, geod) in [(41.7196, 44.8271, 499.805), (41.7160, 44.8290, 187.063)]) {
        final d = distanceM(truth.lat, truth.lon, lat, lon);
        expect(d, closeTo(geod, geod * 0.003));
        expect(distancePoints(d), distancePoints(geod));
      }
    });

    test('the true place in UTM is PROJ’s (cs2cs EPSG:4326 to EPSG:32638)', () {
      expect(formatUtm(41.7151, 44.8271), '38N 485617 4618159');
      expect(formatUtm(42.6576, 44.6419), '38N 470650 4722855');
    });

    test('a score’s parts, as the Worker test scores the same answers', () {
      final full = scoreParts(truth, 'dm', facts, 'b', answer());
      expect((full.place, full.format, full.message, full.photo, full.total), (40, 20, 20, 20, 100));
      // 500 m north, in dd instead of dm, one person wrong, no landmark, the wrong photo: 20 + 0 + 10 + 0.
      final poor = scoreParts(
        truth,
        'dm',
        facts,
        'b',
        answer(coords: '41.71960, 44.82710', at: (lat: 41.7196, lon: 44.8271), people: 1, landmark: '', photo: 'a'),
      );
      expect(poor.total, 30);
      expect(scoreParts(truth, 'dm', facts, 'b', answer(coords: 'by the tower', at: null)).total, 40);
    });
  });

  test('photos are made small, turned upright, and lose their EXIF (GPS, phone)', () {
    final r = Random(1);
    // A photo-like picture: smooth shading with a little grain.
    final image = img.Image(width: 3000, height: 2000);
    for (final p in image) {
      final g = r.nextInt(12);
      p.setRgb(p.x * 200 ~/ 3000 + g, p.y * 200 ~/ 2000 + g, 120 + g);
    }
    image.exif.imageIfd.orientation = 6; // the phone was held upright
    image.exif.imageIfd['Make'] = img.IfdValueAscii('TestPhone');
    image.exif.gpsIfd.setGpsLocation(latitude: 41.7151, longitude: 44.8271);
    final original = img.encodeJpg(image, quality: 95);
    expect(img.decodeJpg(original)!.exif.gpsIfd.gpsLatitude, closeTo(41.7151, 1e-3));

    final out = preparePhoto(original)!;
    expect(out.length, lessThanOrEqualTo(photoMaxBytes));
    expect(out.sublist(0, 3), [0xff, 0xd8, 0xff]);
    final back = img.decodeJpg(out)!;
    expect((back.width, back.height), (853, 1280));
    expect(back.exif.isEmpty, isTrue);
    expect(latin1.decode(out, allowInvalid: true), isNot(contains('Exif')));
    expect(latin1.decode(out, allowInvalid: true), isNot(contains('TestPhone')));
    expect(preparePhoto(Uint8List.fromList(utf8.encode('not a picture'))), isNull);

    // Pure noise doesn't fit in 300 KB at 1280 px: it is made smaller still.
    final noise = img.Image(width: 1600, height: 1200);
    for (final p in noise) {
      p.setRgb(r.nextInt(256), r.nextInt(256), r.nextInt(256));
    }
    final small = preparePhoto(img.encodeJpg(noise, quality: 95));
    if (small != null) {
      expect(small.length, lessThanOrEqualTo(photoMaxBytes));
      expect(img.decodeJpg(small)!.width, 960);
    }
  });

  test('the game is registered and pickable, after the thematic map', () {
    expect(gameModule('emergency'), isA<EmergencyGame>());
    final games = pickableGames();
    expect(games.indexOf('emergency'), games.indexOf('thematic') + 1);
  });

  group('student', () {
    final settings = {
      'template': '11111111-2222-3333-4444-555555555555',
      'name': 'Walks',
      'points': [
        {
          'lat': truth.lat,
          'lon': truth.lon,
          'format': 'dm',
          'title': 'Mtatsminda',
          'text': 'Your friend twisted an ankle.',
          'photos': ['a', 'b', 'c'],
        },
        {
          'lat': 42.6576,
          'lon': 44.6419,
          'format': 'utm',
          'title': 'Kazbegi',
          'text': 'Lost in fog.',
          'photos': ['d', 'e'],
        },
      ],
    };

    Future<List<Map<String, dynamic>>> start(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
      SharedPreferences.setMockInitialValues(prefs);
      final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
      addTearDown(() => cache.deleteSync(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cache.path,
      );
      await tester.binding.setSurfaceSize(const Size(1000, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final sent = <Map<String, dynamic>>[];
      final api = Api(
        client: MockClient((req) async {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'ok': true,
              'duplicate': false,
              'score': 70,
              'truth': [truth.lat, truth.lon],
              'facts': facts.toJson(),
              'best': 'b',
              'notes': {'a': 'Only trees', 'b': 'The TV tower behind', 'c': 'A car park anywhere'},
            }),
            201,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmergencyPlay(
              ctx: PlayContext(
                s: s,
                lang: 'ka',
                token: 'token-112',
                settings: settings,
                now: 0,
                resetAt: 0,
                api: api,
                onStopped: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    Future<void> tap(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('a call: coordinates, message and photo; then the right answers and the photo notes', (tester) async {
      final sent = await start(tester);
      expect(find.text(s['emergency_exercise']), findsOneWidget);
      expect(find.text('Mtatsminda'), findsOneWidget);
      expect(find.text(s['emergency_you_are_here']), findsOneWidget);

      // Nothing goes until the call is complete.
      await tap(tester, find.byKey(const Key('emergency_call')));
      expect(find.text(s['emergency_need_coords']), findsOneWidget);
      expect(sent, isEmpty);

      await tester.enterText(find.byKey(const Key('emergency_coords')), '41°42.906′ N, 44°49.626′ E');
      await tap(tester, find.byKey(const Key('emergency_call_kind')));
      await tap(tester, find.text(s['emergency_kind_injury']).last);
      await tap(tester, find.byKey(const Key('emergency_call_people_plus')));
      await tap(tester, find.byKey(const Key('emergency_call_people_plus')));
      await tap(tester, find.text(s['yes']));
      await tester.enterText(find.byKey(const Key('emergency_call_landmark')), 'TV tower');
      await tap(tester, find.byKey(const Key('emergency_call')));
      expect(find.text(s['emergency_need_photo']), findsOneWidget);
      await tap(tester, find.byKey(const Key('emergency_photo_b')));
      await tap(tester, find.byKey(const Key('emergency_call')));

      expect(sent, hasLength(1));
      final a = sent.single;
      expect(a['round'], 0);
      expect(a['answer'], {
        'coords': '41°42.906′ N, 44°49.626′ E',
        'at': [closeTo(41.7151, 1e-4), closeTo(44.8271, 1e-4)],
        'kind': 'injury',
        'people': 2,
        'injured': true,
        'landmark': 'TV tower',
        'photo': 'b',
      });
      expect(find.text(s.f('points', [70])), findsOneWidget);
      expect(find.text(s.f('emergency_part_format', [20, s['format_dm'], s['format_dm']])), findsOneWidget);
      expect(find.text('${s['format_utm']}: 38N 485617 4618159'), findsOneWidget);
      expect(find.text('The TV tower behind'), findsOneWidget);
      expect(find.text(s['emergency_best_photo']), findsOneWidget);

      // The next call is the second point, in UTM.
      await tap(tester, find.byKey(const Key('emergency_next')));
      expect(find.text('Kazbegi'), findsOneWidget);
      expect(find.text(s.f('emergency_operator_asks', [s['format_utm']])), findsOneWidget);
    });

    testWidgets('an answered point shows its result again after a reload', (tester) async {
      final result = PointResult(55, truth, facts, 'b', const {'b': 'The TV tower behind'}, answer());
      await start(
        tester,
        prefs: {
          'progress_token-112': jsonEncode({
            'results': {'0': result.toJson()},
            'resetAt': 0,
          }),
        },
      );
      // The first open point is the second.
      expect(find.text('Kazbegi'), findsOneWidget);
      await tap(tester, find.byKey(const Key('emergency_tab_0')));
      expect(find.text(s.f('points', [55])), findsOneWidget);
    });
  });

  group('teacher', () {
    final points = [
      EmergencyPoint(
        lat: truth.lat,
        lon: truth.lon,
        format: 'dm',
        title: 'Mtatsminda',
        text: 'x',
        facts: facts,
        photos: const [PointPhoto('a', 'n'), PointPhoto('b', 'n')],
        best: 1,
      ),
    ];
    final calls = [
      CallRow('p1', 0, 100, 0, answer()),
      CallRow('p2', 0, 40, 0, answer(coords: 'by the tower', at: null)),
    ];

    test('CSV: one row per call with the parts of its score', () {
      final rows = callsToCsv(points, calls, 'en').trimRight().split('\r\n');
      expect(rows, hasLength(3));
      expect(rows[0], startsWith('﻿nickname,point,title,coords,format_asked,format_written,lat,lon,distance_m'));
      expect(
        rows[1],
        contains(',1,"Mtatsminda","41°42.906′ N, 44°49.626′ E",dm,dm,41.715100,44.827100,0,injury,2,true,'),
      );
      expect(rows[1], contains(',true,40,20,20,20,100,1970-01-01T00:00:00.000Z'));
      expect(rows[2], contains(',"by the tower",dm,,,,,injury,'));
      expect(rows[2], contains(',0,0,20,20,40,'));
    });

    test('GeoJSON: the true points, and each readable call with a line to its point', () {
      final geo = jsonDecode(callsToGeoJson(points, calls, 'en')) as Map<String, dynamic>;
      final f = (geo['features'] as List).cast<Map<String, dynamic>>();
      expect(f, hasLength(3));
      expect(f[0]['properties'], containsPair('truth', true));
      expect(f[1]['properties'], containsPair('distance_m', 0));
      expect(f[2]['geometry']['type'], 'LineString');
    });

    test('a stored row reads back', () {
      final r = CallRow.fromJson({
        'participantId': 'x',
        'round': 1,
        'score': 7,
        'createdAt': 9,
        'answer': answer().toJson(),
      });
      expect((r.round, r.score, r.answer.photo, r.answer.at?.lat), (1, 7, 'b', truth.lat));
    });
  });

  group('templates', () {
    testWidgets('the teacher makes a template, adds a point with photos, saves it and uses it', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
      addTearDown(() => cache.deleteSync(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cache.path,
      );
      const id = '11111111-2222-3333-4444-555555555555';
      var stored = <String, dynamic>{'points': []};
      final calls = <String>[];
      var photo = 0;
      final api = Api(
        teacherKey: 'k',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          final template = {'id': id, 'game': 'emergency', 'name': 'Walks', 'updatedAt': 1, 'data': stored};
          return switch ('${req.method} ${req.url.path}') {
            'GET /api/templates' => http.Response(
              jsonEncode({
                'templates': stored['points'] == null ? [] : [template],
              }),
              200,
            ),
            'POST /api/templates' => http.Response(jsonEncode({'template': template}), 201),
            'GET /api/templates/$id' => http.Response(jsonEncode({'template': template}), 200),
            'PATCH /api/templates/$id' => () {
              stored = (jsonDecode(req.body) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
              return http.Response(jsonEncode({'template': template}), 200);
            }(),
            'POST /api/templates/$id/photos' => () {
              expect(req.headers['Content-Type'], 'image/jpeg');
              expect(req.bodyBytes.sublist(0, 3), [0xff, 0xd8, 0xff]);
              return http.Response(jsonEncode({'id': '${photo++}'.padLeft(16, '0')}), 201);
            }(),
            _ => http.Response('{"error":"not_found"}', 404),
          };
        }),
      );
      final picture = img.encodePng(img.Image(width: 40, height: 30));
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await Navigator.of(context).push<Map<String, dynamic>>(
                MaterialPageRoute(
                  builder: (_) => EmergencySetupPage(s: s, api: api, pick: () async => picture),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      // An empty template can't make a session.
      await tap(find.byKey(const Key('emergency_use')));
      expect(find.text(s['emergency_unfinished_points']), findsOneWidget);

      await tap(find.byKey(const Key('emergency_template_$id')).first);
      await tap(find.byIcon(Icons.edit).first);
      await tap(find.byKey(const Key('emergency_add_point')));
      await tester.enterText(find.byKey(const Key('emergency_point_coords')), '41.7151, 44.8271');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('emergency_point_title')), 'Mtatsminda');
      await tester.enterText(find.byKey(const Key('emergency_point_text')), 'Your friend twisted an ankle.');
      await tester.enterText(find.byKey(const Key('emergency_landmark')), 'TV tower');
      await tap(find.byKey(const Key('emergency_add_photo')));
      await tap(find.byKey(const Key('emergency_add_photo')));
      await tester.enterText(find.byKey(const Key('emergency_note_1')), 'The tower behind');
      await tap(find.byKey(const Key('emergency_best_1')));
      await tap(find.byKey(const Key('emergency_point_done')));
      await tap(find.byKey(const Key('emergency_save')));

      final p = (stored['points'] as List).single as Map<String, dynamic>;
      expect(p, {
        'lat': 41.7151,
        'lon': 44.8271,
        'format': 'dd',
        'title': 'Mtatsminda',
        'text': 'Your friend twisted an ankle.',
        'facts': {'kind': 'injury', 'people': 1, 'injured': true, 'landmark': 'TV tower'},
        'photos': [
          {'id': '0000000000000000', 'note': ''},
          {'id': '0000000000000001', 'note': 'The tower behind'},
        ],
        'best': 1,
      });
      expect(calls.where((c) => c.endsWith('/photos')), hasLength(2));

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(find.byKey(const Key('emergency_use')));
      expect(result, {
        'emergency': {'template': id},
      });
    });
  });
}
