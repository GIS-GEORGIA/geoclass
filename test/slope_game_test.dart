import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/games/slope.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/slope.dart';
import 'package:geoclass/terrain/slope_game.dart';
import 'package:geoclass/terrain/slope_play.dart';
import 'package:geoclass/terrain/slope_session_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  final degrees = slopeOf(grid);
  const s = S('ka');
  // 4 × 4 squares of 3 × 3 cells, clear of the grid's edge and of the empty cell at row 12, column 20.
  const box = SlopeBox(2, 2, 3, 4);

  DemLoader loader() => DemLoader(
    base: 'https://x.test',
    client: MockClient(
      (req) async => switch (req.url.path) {
        '/areas/catalog.json' => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'areas': [
                {
                  'id': 'fixture',
                  'version': 1,
                  'ka': 'ნიმუში',
                  'en': 'Sample',
                  'bbox': metaJson['bbox'],
                  'min': 1,
                  'max': 2,
                },
              ],
            }),
          ),
          200,
        ),
        '/areas/fixture/1/area.json' => http.Response.bytes(utf8.encode(jsonEncode(metaJson)), 200),
        '/areas/fixture/1/dem.u16.gz' => http.Response.bytes(bytes, 200),
        _ => http.Response('', 404),
      },
    ),
  );

  void mockTileCache(WidgetTester tester) {
    final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
  }

  LatLng centreOf(List<LatLng> corners) => LatLng(
    corners.map((p) => p.latitude).reduce((a, b) => a + b) / corners.length,
    corners.map((p) => p.longitude).reduce((a, b) => a + b) / corners.length,
  );

  test('the game is a registered module the teacher can pick', () {
    expect(gameModule('slope'), isA<SlopeGame>());
    expect(pickableGames(), contains('slope'));
    expect(s['game_slope'], 'ციცაბო ფერდობები');
  });

  test('each square is found again by a touch at its centre, and nothing outside the box', () {
    for (var k = 0; k < 16; k++) {
      expect(box.squareAt(grid, centreOf(box.square(grid, k))), k);
    }
    final o = box.outline(grid);
    expect(box.squareAt(grid, LatLng(o[0].latitude + 0.001, o[0].longitude)), isNull);
  });

  test('a square is steep when more than half of its cells are steeper than the threshold', () {
    final steep = box.steep(grid, degrees, 15)!;
    for (var k = 0; k < 16; k++) {
      final r0 = box.row + (k ~/ 4) * 3, c0 = box.col + (k % 4) * 3;
      var over = 0;
      for (var r = r0; r < r0 + 3; r++) {
        for (var c = c0; c < c0 + 3; c++) {
          if (degrees[r * grid.width + c] > 15) over++;
        }
      }
      expect(steep[k], over >= 5, reason: 'square $k');
    }
    expect(box.steep(grid, degrees, 5)!.where((x) => x).length, greaterThanOrEqualTo(steep.where((x) => x).length));
    // Next to the empty cell, or on the grid's edge, there is no slope to judge.
    expect(const SlopeBox(8, 16, 3, 3).steep(grid, degrees, 15), isNull);
    expect(const SlopeBox(0, 2, 3, 4).steep(grid, degrees, 15), isNull);
  });

  test('a box placed by a touch stays a cell inside the grid', () {
    final b = SlopeBox.around(grid, grid.outline[0], cells: 3, n: 4)!;
    expect([b.row, b.col], [grid.height - 1 - 12, 1]);
    expect(SlopeBox.around(grid, grid.outline[0], cells: 10, n: 10), isNull); // bigger than the grid
  });

  test('scores the overlap as the server does', () {
    final answer = marksFromString('0110011000000001');
    expect(overlapScore(marksFromString('0110010000000011'), answer), 67);
    expect(overlapScore(answer, answer), 100);
    expect(overlapScore(List.filled(16, false), answer), 0);
    expect(overlapScore(List.filled(4, false), List.filled(4, false)), 100);
    expect(marksToString(answer), '0110011000000001');
  });

  test('settings go to the server and come back the same; students get no answer', () {
    final settings = SlopeGameSettings('fixture', 1, box, 15, answer: marksFromString('1000000000000000'));
    final back = SlopeGameSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
    expect(back.box.toJson(), box.toJson());
    expect(back.answer, settings.answer);
    final student = SlopeGameSettings.fromJson({
      'area': {'id': 'fixture', 'version': 1},
      'box': box.toJson(),
      'threshold': 15,
    });
    expect(student.answer, isNull);
    expect(() => SlopeGameSettings.fromJson({'box': 1}), throwsFormatException);
  });

  testWidgets('setup: a touch places the box, and the session carries the right squares', (tester) async {
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Map<String, dynamic>? made;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => made = await Navigator.of(context).push<Map<String, dynamic>>(
              MaterialPageRoute(
                builder: (_) => SlopeSetupPage(s: s, loader: loader(), n: 4, sizes: const [3]),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The teacher may look at the slope classes.
    expect(tester.widget<MapWorkspace>(find.byType(MapWorkspace)).slope, isFalse);
    // A box over the empty cell can't be judged.
    final hole = centreOf(const SlopeBox(11, 19, 1, 1).square(grid, 0));
    final map = tester.getRect(find.byType(MapWorkspace));
    final mapWidget = tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    mapWidget.onTap!(hole, null);
    await tester.pump();
    await tester.tap(find.text(s['create']));
    await tester.pump();
    expect(find.text(s['slope_need_inside']), findsOneWidget);
    expect(made, isNull);

    await tester.tapAt(map.topLeft + Offset(map.width * 0.25, map.height * 0.3));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('slope_steep_count')), findsOneWidget);
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    final settings = SlopeGameSettings.fromJson(made!['slope'] as Map<String, dynamic>);
    expect(settings.threshold, 15);
    expect(settings.box.n, 4);
    expect(settings.answer, settings.box.steep(grid, degrees, 15));
    expect(settings.answer, contains(true));
  });

  testWidgets('play: touches mark squares, no slope layer until the answer, then the score', (tester) async {
    SharedPreferences.setMockInitialValues({});
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'ok': true, 'duplicate': false, 'score': 50, 'answer': '1100000000000000'}),
          201,
        );
      }),
    );
    final ctx = PlayContext(
      s: s,
      lang: 'ka',
      token: 'token-1',
      settings: {
        'area': {'id': 'fixture', 'version': 1},
        'box': box.toJson(),
        'threshold': 15,
      },
      now: 0,
      resetAt: 0,
      api: api,
      onStopped: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlopePlay(ctx: ctx, loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    expect(map().slope, isNull);
    expect(find.text(s.f('slope_question', [15])), findsOneWidget);

    map().onTap!(centreOf(box.square(grid, 0)), null);
    await tester.pump();
    map().onTap!(centreOf(box.square(grid, 5)), null);
    await tester.pump();
    map().onTap!(centreOf(box.square(grid, 5)), null); // and off again
    await tester.pump();
    expect(find.text(s.f('slope_marked', [1, 16])), findsOneWidget);

    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['answer'], {'marks': '1000000000000000'});
    expect(sent.single['round'], 0);
    expect(find.text(s.f('result_score', [50])), findsOneWidget);
    expect(map().slope, isTrue);
    // Sent: touches change nothing.
    map().onTap!(centreOf(box.square(grid, 3)), null);
    await tester.pump();
    expect(find.text(s['play_answer']), findsNothing);
  });

  test('the teacher’s counts and export', () {
    final answers = [
      SlopeAnswer('p1', marksFromString('1100'), 50, 0),
      SlopeAnswer('p2', marksFromString('1000'), 100, 0),
    ];
    expect(markCounts(answers, 4), [2, 1, 0, 0]);
    final rows = slopeAnswersToCsv(answers, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[1], contains('"1 2",50,'));
  });
}
