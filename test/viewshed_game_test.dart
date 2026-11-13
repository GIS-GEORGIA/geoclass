import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/games/viewshed.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/slope_game.dart';
import 'package:geoclass/terrain/viewshed.dart';
import 'package:geoclass/terrain/viewshed_game.dart';
import 'package:geoclass/terrain/viewshed_play.dart';
import 'package:geoclass/terrain/viewshed_session_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  const s = S('ka');
  // The first observer of the GDAL fixture: 10 m up at row 15, column 10.
  final gdal = (jsonDecode(File('$dir/viewshed.json').readAsStringSync()) as List).first as Map<String, dynamic>;
  const observer = GridCell(15, 10);
  final seen = viewshed(grid, observer.row, observer.col, observer: 10)!;
  bool gdalSeen(GridCell c) => (gdal['seen'] as String)[c.row * grid.width + c.col] == '1';
  // Two seen and two hidden cells, as gdal_viewshed has them.
  final seenCells = <GridCell>[], hiddenCells = <GridCell>[];
  for (var r = 2; r < grid.height - 2 && (seenCells.length < 2 || hiddenCells.length < 2); r += 3) {
    for (var c = 20; c < grid.width - 2; c += 5) {
      final cell = GridCell(r, c);
      if (gdalSeen(cell) && seenCells.length < 2) seenCells.add(cell);
      if (!gdalSeen(cell) && hiddenCells.length < 2) hiddenCells.add(cell);
    }
  }
  final targets = [seenCells[0], hiddenCells[0], seenCells[1], hiddenCells[1]];

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

  test('the game is a registered module the teacher can pick', () {
    expect(gameModule('viewshed'), isA<ViewshedGame>());
    expect(pickableGames(), contains('viewshed'));
    expect(s['game_viewshed'], 'ხილვადობა');
  });

  test('targets and squares are judged from the viewshed, as gdal_viewshed sees them', () {
    expect(targetsSeen(grid, seen, targets), [true, false, true, false]);
    // A target on the empty cell can't be judged.
    expect(targetsSeen(grid, seen, [...targets, const GridCell(12, 20)]), isNull);

    const box = SlopeBox(0, 24, 3, 4);
    final squares = squaresSeen(grid, seen, box)!;
    for (var k = 0; k < 16; k++) {
      final r0 = box.row + (k ~/ 4) * 3, c0 = box.col + (k % 4) * 3;
      var n = 0;
      for (var r = r0; r < r0 + 3; r++) {
        for (var c = c0; c < c0 + 3; c++) {
          if (gdalSeen(GridCell(r, c))) n++;
        }
      }
      expect(squares[k], n >= 5, reason: 'square $k');
    }
    expect(squaresSeen(grid, seen, const SlopeBox(10, 18, 3, 2)), isNull); // over the empty cell
    expect(squaresSeen(grid, seen, const SlopeBox(25, 0, 3, 4)), isNull); // past the grid's edge
  });

  test('scores as the server does', () {
    expect(targetScore([true, true, true, false], [true, false, true, false]), 75);
    expect(targetScore([false, true, false, true], [true, false, true, false]), 0);
    expect(viewMetres(1.7), '1.7');
    expect(viewMetres(10), '10');
  });

  test('settings go to the server and come back the same; students get no answer', () {
    final byTargets = ViewshedGameSettings(
      'fixture',
      1,
      observer,
      10,
      targets: targets,
      answer: [true, false, true, false],
    );
    final back = ViewshedGameSettings.fromJson(jsonDecode(jsonEncode(byTargets.toJson())) as Map<String, dynamic>);
    expect(back.targets, targets);
    expect(back.answer, byTargets.answer);
    expect(back.count, 4);
    expect(byTargets.toJson().containsKey('box'), isFalse);

    const box = SlopeBox(2, 2, 3, 4);
    final bySquares = ViewshedGameSettings('fixture', 1, observer, 1.7, kind: 'squares', box: box);
    final student = ViewshedGameSettings.fromJson(jsonDecode(jsonEncode(bySquares.toJson())) as Map<String, dynamic>);
    expect(student.box!.toJson(), box.toJson());
    expect(student.answer, isNull);
    expect(student.count, 16);
    expect(student.toJson().containsKey('targets'), isFalse);

    expect(() => ViewshedGameSettings.fromJson({'kind': 1}), throwsFormatException);
    expect(() => ViewshedGameSettings.fromJson({...bySquares.toJson(), 'kind': 'lines'}), throwsFormatException);
  });

  testWidgets('setup: the observer, then the targets, and the session carries what is seen', (tester) async {
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
                builder: (_) => ViewshedSetupPage(s: s, loader: loader(), n: 4, sizes: const [3]),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    void touch(GridCell c) => map().onTap!(c.centre(grid), grid.heightAt(c.centre(grid)));

    // The empty cell has no height to stand on.
    map().onTap!(const GridCell(12, 20).centre(grid), null);
    await tester.pump();
    expect(find.text(s['view_need_data']), findsOneWidget);
    expect(find.byKey(const Key('view_observer')), findsNothing);

    touch(observer);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('view_observer')), findsOneWidget);
    for (final t in targets.take(2)) {
      touch(t);
      await tester.pump();
    }
    await tester.tap(find.text(s['create']));
    await tester.pump();
    expect(find.text(s['view_need_targets']), findsOneWidget);
    expect(made, isNull);

    // A touch by a target takes it away; then the four are placed.
    touch(targets[1]);
    await tester.pump();
    expect(find.byKey(const Key('view_target_1')), findsNothing);
    for (final t in targets.skip(1)) {
      touch(t);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text(s.f('view_targets_seen', [2, 4])), findsOneWidget);
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    final settings = ViewshedGameSettings.fromJson(made!['viewshed'] as Map<String, dynamic>);
    expect(settings.kind, 'targets');
    expect(settings.observer, observer);
    expect(settings.height, 10);
    expect(settings.targets, targets);
    expect(settings.answer, [true, false, true, false]);
  });

  testWidgets('setup: the box, of which some squares must be seen', (tester) async {
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
                builder: (_) => ViewshedSetupPage(s: s, loader: loader(), n: 4, sizes: const [3]),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['view_kind_squares']));
    await tester.pump();
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    final at = observer.centre(grid);
    map().onTap!(at, grid.heightAt(at));
    await tester.pump();
    await tester.tap(find.text(s.f('view_metres', ['1.7'])));
    await tester.pump();
    final centre = const GridCell(21, 12).centre(grid); // round the observer, where it sees
    map().onTap!(centre, grid.heightAt(centre));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('view_seen_count')), findsOneWidget);
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    final settings = ViewshedGameSettings.fromJson(made!['viewshed'] as Map<String, dynamic>);
    expect(settings.kind, 'squares');
    expect(settings.height, 1.7);
    final want = squaresSeen(grid, viewshed(grid, observer.row, observer.col, observer: 1.7)!, settings.box!);
    expect(settings.answer, want);
    expect(settings.answer, contains(true));
  });

  PlayContext context(Api api, Map<String, dynamic> settings) => PlayContext(
    s: s,
    lang: 'ka',
    token: 'token-1',
    settings: settings,
    now: 0,
    resetAt: 0,
    api: api,
    onStopped: (_) {},
  );

  int overlays(WidgetTester tester) => tester.widgetList(find.byType(OverlayImageLayer)).length;

  testWidgets('play, targets: judge each, nothing seen shown until the answer, then the score', (tester) async {
    SharedPreferences.setMockInitialValues({});
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'ok': true, 'duplicate': false, 'score': 75, 'answer': '1010'}), 201);
      }),
    );
    final settings = ViewshedGameSettings('fixture', 1, observer, 10, targets: targets).toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ViewshedPlay(ctx: context(api, settings), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = overlays(tester);
    expect(find.text(s.f('view_question_targets', ['10'])), findsOneWidget);
    ButtonStyleButton answer() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['play_answer']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(answer().onPressed, isNull); // not all judged

    // One touch says seen, a second not seen: targets 1, 3 and 4 seen, 2 not.
    await tester.tap(find.byKey(const Key('view_chip_0')));
    await tester.tap(find.byKey(const Key('view_chip_1')));
    await tester.tap(find.byKey(const Key('view_chip_1')));
    await tester.tap(find.byKey(const Key('view_chip_2')));
    await tester.tap(find.byKey(const Key('view_target_3'))); // the marker on the map works too
    await tester.pump();
    expect(find.text(s.f('view_judged', [4, 4])), findsOneWidget);
    expect(answer().onPressed, isNotNull);

    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['answer'], {'seen': '1011'});
    expect(sent.single['round'], 0);
    expect(find.text(s.f('result_score', [75])), findsOneWidget);
    expect(overlays(tester), before + 1); // the seen ground
    expect(find.byIcon(Icons.cancel), findsOneWidget); // target 4 judged wrong
    expect(find.text(s['play_answer']), findsNothing);
  });

  testWidgets('play, squares: touches mark them, and one answer goes', (tester) async {
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
    const box = SlopeBox(2, 2, 3, 4);
    final settings = const ViewshedGameSettings('fixture', 1, observer, 1.7, kind: 'squares', box: box).toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ViewshedPlay(ctx: context(api, settings), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    LatLng centre(int k) {
      final c = box.square(grid, k);
      return LatLng(
        c.map((p) => p.latitude).reduce((a, b) => a + b) / 4,
        c.map((p) => p.longitude).reduce((a, b) => a + b) / 4,
      );
    }

    for (final k in [0, 5]) {
      map().onTap!(centre(k), null);
      await tester.pump();
    }
    expect(find.text(s.f('slope_marked', [2, 16])), findsOneWidget);
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['answer'], {'seen': '1000010000000000'});
    expect(find.text(s.f('result_score', [50])), findsOneWidget);
  });

  test('the teacher’s counts and export', () {
    final answers = [
      ViewshedAnswer('p1', marksFromString('1100'), 50, 0),
      ViewshedAnswer('p2', marksFromString('1000'), 75, 0),
    ];
    expect(seenCounts(answers, 4), [2, 1, 0, 0]);
    final rows = viewshedAnswersToCsv(answers, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[1], contains('"1 2",50,'));
    final settings = ViewshedGameSettings(
      'fixture',
      1,
      observer,
      10,
      targets: targets,
      answer: [true, false, true, false],
    );
    final geo = jsonDecode(viewshedToGeoJson(grid, settings, [2, 1, 0, 0])) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(features, hasLength(5));
    expect(features.first['properties'], {'observer': true, 'height_m': 10.0});
    expect(features[1]['properties'], {'target': 1, 'seen': true, 'said_seen_by': 2});
  });
}
