import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/timelapse/frame_map.dart';
import 'package:geoclass/timelapse/timelapse.dart';
import 'package:geoclass/timelapse/timelapse_play.dart';
import 'package:geoclass/timelapse/timelapse_session_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GDAL/OGR's IoU and PROJ's geodesic areas (tool/timelapse/make_iou_fixture.py); the Worker checks against the
/// same file.
final fixture = jsonDecode(File('test/fixtures/timelapse/iou.json').readAsStringSync()) as Map<String, dynamic>;
final cases = [for (final c in fixture['cases'] as List) c as Map<String, dynamic>];

Map<String, dynamic> caseNamed(String name) => cases.firstWhere((c) => c['name'] == name);

void main() {
  final s = S('ka');

  group('IoU, against GDAL/OGR', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final got = iou(outlineFromJson(c['truth']), outlineFromJson(c['answer']));
        expect((got - (c['iou'] as num)).abs(), lessThan(0.002));
      });
    }
    test('is 0 without an outline; the score is the mean of both years × 100', () {
      expect(iou(outlineFromJson(caseNamed('same')['truth']), const []), 0);
      expect(iou(const [], outlineFromJson(caseNamed('same')['truth'])), 0);
      expect(scoreOf(1, 0.4045), 70);
      expect(scoreOf(0, 0), 0);
      expect(scoreOf(1, 1), 100);
    });
  });

  group('areas, against PROJ geodesic', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        for (final (key, area) in [('truth', 'truth_km2'), ('answer', 'answer_km2')]) {
          final want = (c[area] as num).toDouble() * 1e6;
          // Overlapping rings once, as OGR's union; within 0.1 % of the geodesic area.
          expect((outlineArea(outlineFromJson(c[key])) - want).abs() / want, lessThan(0.001), reason: key);
        }
      });
    }
    test('writes the change with its per cent', () {
      expect(changeText(1e6, 1.5e6), '+0.50 km² (+50 %)');
      expect(changeText(2e6, 1.5e6), '−0.50 km² (−25 %)');
      expect(changeText(0, 1.5e6), '+1.50 km²');
    });
  });

  group('drawing an outline', () {
    const p = [LatLng(41.37, 44.45), LatLng(41.37, 44.46), LatLng(41.38, 44.46), LatLng(41.38, 44.45)];
    test('adds points, closes a ring, undoes and keeps to the limits', () {
      var d = const OutlineDraft([], [], maxRings: 2, maxVertices: 7);
      expect(d.canClose, isFalse);
      for (final x in p.take(3)) {
        d = d.tap(x);
      }
      expect(d.outline, hasLength(1)); // a ring being drawn counts once it has three points
      d = d.tap(p[0], near: true); // the first point again closes it
      expect(d.rings, hasLength(1));
      expect(d.draft, isEmpty);
      d = d.undo(); // opens it again
      expect(d.rings, isEmpty);
      expect(d.draft, hasLength(3));
      d = d.close();
      for (final x in p) {
        d = d.tap(x);
      }
      expect(d.vertices, 7);
      expect(d.full, isTrue);
      expect(d.tap(p[0]).vertices, 7);
      expect(d.clear().isEmpty, isTrue);
    });
    test('outlines go to the server with six decimals and come back the same', () {
      final o = [
        [const LatLng(41.123456789, 44.987654321), ...p.skip(1)],
      ];
      final json = outlineToJson(o);
      expect(json[0][0], [41.123457, 44.987654]);
      expect(outlineToJson(outlineFromJson(jsonDecode(jsonEncode(json)))), json);
    });
  });

  group('the teacher page', () {
    final c = caseNamed('concave');
    final d = TimelapseData(
      'madneuli',
      1,
      1990,
      2020,
      outlineFromJson(c['truth']),
      outlineFromJson(caseNamed('overlapping_rings')['truth']),
    );
    final row = OutlineRow.of({
      'participantId': 'timelapse-player-1',
      'score': 70,
      'createdAt': 0,
      'answer': {'a': c['answer'], 'b': outlineToJson(d.truthB)},
    }, d);

    test('works out each answer\'s areas and matches', () {
      expect((row.iouA - (c['iou'] as num)).abs(), lessThan(0.002));
      expect(row.iouB, closeTo(1, 1e-9));
      expect(row.areaA / 1e6, closeTo((c['answer_km2'] as num).toDouble(), 0.002));
    });

    test('exports a row per student after the teacher\'s, and the outlines as GeoJSON', () {
      final csv = outlinesToCsv(d, [row], 'en').trimRight().split('\r\n');
      expect(csv[0], startsWith('﻿nickname,year_a,year_b,area_a_km2'));
      expect(csv[1], startsWith('"teacher",1990,2020,'));
      expect(csv[2], contains(',0.405,1.000,70,'));
      final geo = jsonDecode(outlinesToGeoJson(d, [row], 'en')) as Map<String, dynamic>;
      final features = geo['features'] as List;
      expect(features, hasLength(4));
      final first = features.first as Map<String, dynamic>;
      expect(first['properties'], containsPair('truth', true));
      final ring = ((first['geometry'] as Map)['coordinates'] as List)[0][0] as List;
      expect(ring.first, ring.last); // closed, lon before lat
      expect((ring.first as List)[0], closeTo(44.45, 1e-9));
    });
  });

  test('the game is registered with its strings', () {
    final g = gameModule('timelapse')!;
    expect(g.hasSetup, isTrue);
    expect(pickableGames().last, 'timelapse');
    for (final lang in ['ka', 'en']) {
      final t = S(lang);
      for (final k in ['game_timelapse', 'timelapse_task', 'timelapse_row', 'no_site', 'timelapse_unavailable']) {
        expect(t[k], isNot(k), reason: '$lang $k');
      }
    }
  });

  group('the student', () {
    final site = {
      'id': 'madneuli',
      'version': 1,
      'corners': [
        [41.42, 44.37],
        [41.42, 44.49],
        [41.34, 44.49],
        [41.34, 44.37],
      ],
      // No pictures here, so the test reads nothing from the network.
      'frames': <Object>[],
      'attribution': ['Landsat imagery courtesy of the U.S. Geological Survey'],
    };
    final truth = outlineToJson(outlineFromJson(caseNamed('same')['truth']));

    testWidgets('watches, draws on both years, sees the areas and the change, sends, then sees the truth', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
      addTearDown(() => cache.deleteSync(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cache.path,
      );
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final sent = <Map<String, dynamic>>[];
      final api = Api(
        client: MockClient((req) async {
          sent.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'ok': true,
              'duplicate': false,
              'score': 42,
              'truth': [truth, truth],
            }),
            201,
          );
        }),
      );
      final loader = FrameLoader(MockClient((req) async => http.Response(jsonEncode(site), 200)));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelapsePlay(
              loader: loader,
              ctx: PlayContext(
                s: s,
                lang: 'ka',
                token: 'token-timelapse',
                settings: {
                  'template': 't',
                  'name': 'Madneuli',
                  'site': 'madneuli',
                  'version': 1,
                  'years': [1990, 2020],
                },
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
      expect(find.text(s.f('timelapse_task', [1990, 2020])), findsOneWidget);

      // Nothing goes before both years have an outline.
      await tester.ensureVisible(find.byKey(const Key('timelapse_send')));
      await tester.tap(find.byKey(const Key('timelapse_send')));
      await tester.pumpAndSettle();
      expect(find.text(s['timelapse_need_both']), findsOneWidget);
      expect(sent, isEmpty);

      Future<void> draw(String year, List<Offset> at) async {
        await tester.tap(find.text(year));
        await tester.pumpAndSettle();
        for (final o in at) {
          await tester.tapAt(o);
          // Past the map's double-tap wait, so each touch is its own.
          await tester.pump(const Duration(milliseconds: 400));
        }
        await tester.tap(find.byKey(const Key('timelapse_close')));
        await tester.pumpAndSettle();
      }

      await draw('1990', const [Offset(300, 200), Offset(500, 200), Offset(400, 350)]);
      await draw('2020', const [Offset(250, 150), Offset(550, 150), Offset(550, 400), Offset(250, 400)]);
      final areaA = find.byKey(const Key('timelapse_area_a'));
      expect((tester.widget(areaA) as Text).data, isNot('1990: 0.00 km²'));
      expect((tester.widget(find.byKey(const Key('timelapse_change'))) as Text).data, contains('%'));

      await tester.ensureVisible(find.byKey(const Key('timelapse_send')));
      await tester.tap(find.byKey(const Key('timelapse_send')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      final answer = sent.single['answer'] as Map<String, dynamic>;
      expect(sent.single['round'], 0);
      expect((answer['a'] as List).single, hasLength(3));
      expect((answer['b'] as List).single, hasLength(4));
      expect(find.byKey(const Key('timelapse_score')), findsOneWidget);
      expect(find.text(s.f('points', [42])), findsOneWidget);
      expect(find.byKey(const Key('timelapse_send')), findsNothing);
    });
  });
}
