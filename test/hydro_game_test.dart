import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/games/hydro.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/viewshed_game.dart' show GridCell;
import 'package:geoclass/terrain/watershed.dart';
import 'package:geoclass/terrain/watershed_game.dart';
import 'package:geoclass/terrain/hydro_play.dart';
import 'package:geoclass/terrain/hydro_session_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const dir = 'test/fixtures/watershed';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final flowBytes = File('$dir/flow.u8').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;
  const s = S('ka');
  // Streams from 200 upstream cells: a fixture this small has few of 1 km².
  final flow = FlowGrid(grid.width, grid.height, flowBytes, streamCells: 200);
  final acc = accumulation(flow);
  final second = (expected['basins'] as List)[1] as Map<String, dynamic>;
  final outlet = GridCell((second['outlet'] as List)[0] as int, (second['outlet'] as List)[1] as int);
  final basin = runsFromJson(second['runs'] as List);
  DemLoader loader({Uint8List? flowFile}) => DemLoader(
    base: 'https://x.test',
    client: MockClient(
      (req) async => switch (req.url.path) {
        '/areas/catalog.json' => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'areas': [
                {
                  'id': 'watershed-fixture',
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
        '/areas/watershed-fixture/1/area.json' => http.Response.bytes(utf8.encode(jsonEncode(metaJson)), 200),
        '/areas/watershed-fixture/1/dem.u16.gz' => http.Response.bytes(bytes, 200),
        '/areas/watershed-fixture/1/watershed.json' => http.Response.bytes(
          utf8.encode(jsonEncode({'sha256': sha256.convert(flowBytes).toString(), 'stream_cells': 200})),
          200,
        ),
        '/areas/watershed-fixture/1/flow.u8.gz' => http.Response.bytes(flowFile ?? flowBytes, 200),
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

  test('level 2 is a registered module the teacher can pick, after level 1', () {
    expect(gameModule('hydro'), isA<HydroGame>());
    final games = pickableGames();
    expect(games.indexOf('hydro'), games.indexOf('watershed') + 1);
    expect(s['game_hydro'], 'აუზი DEM-იდან (Level 2)');
  });

  test('a drop’s way: its cells, its length on the ground and the height it loses', () {
    const start = GridCell(60, 75);
    final p = FlowPathInfo.of(grid, flow, start);
    expect(p.cells, flowPath(flow, 60, 75));
    expect(p.cells, hasLength(100)); // as GRASS r.drain in test/fixtures/watershed/paths.json
    // Between 30 m (straight) and 42.4 m (diagonal) a step, a little less on the ground than on the grid.
    expect(p.length / (p.cells.length - 1), inInclusiveRange(29.9, 42.5));
    expect(p.drop, grid.heightAt(cellCentre(grid, p.cells.first))! - grid.heightAt(cellCentre(grid, p.cells.last))!);
    expect(p.drop, greaterThan(0));
  });

  testWidgets('setup for level 2 sends the same settings under its own name', (tester) async {
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
                builder: (_) => WatershedSetupPage(s: s, loader: loader(), game: 'hydro'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(s['game_hydro']), findsOneWidget);
    expect(find.text(s['hydro_scoring']), findsOneWidget);
    final map = tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    map.onTap!(outlet.centre(grid), null);
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(made, {
      'hydro': {
        'area': {'id': 'watershed-fixture', 'version': 1},
        'outlet': {'row': outlet.row, 'col': outlet.col},
      },
    });
  });

  PlayContext context(Api api) => PlayContext(
    s: s,
    lang: 'ka',
    token: 'token-2',
    settings: WatershedGameSettings('watershed-fixture', 1, outlet).toJson(),
    now: 0,
    resetAt: 0,
    api: api,
    onStopped: (_) {},
  );

  Future<List<Map<String, dynamic>>> start(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'ok': true, 'duplicate': false, 'score': 100, 'basin': second['runs']}), 201);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HydroPlay(ctx: context(api), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sent;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('play: the five steps, from the DEM to the pour point’s basin against the level-1 drawing', (
    tester,
  ) async {
    // Round the basin, roughly: the level-1 test's drawing, which the server scores 64.
    const level1 = <GridPoint>[
      (row: 33.17, col: 4.62),
      (row: 36.5, col: 30.25),
      (row: 52.91, col: 44.08),
      (row: 82.33, col: 40.5),
      (row: 79.0, col: 12.75),
      (row: 60.25, col: 3.4),
    ];
    final key = drawingKey(WatershedGameSettings('watershed-fixture', 1, outlet));
    expect(key, 'shed_drawing_watershed-fixture_1_${outlet.row}_${outlet.col}');
    final sent = await start(tester, prefs: {key: jsonEncode(polyToJson(level1))});
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    Future<void> touch(GridCell c) async {
      map().onTap!(c.centre(grid), null);
      await tester.pumpAndSettle();
    }

    // 1. The DEM: heights on touch.
    expect(find.text(s['hydro_title_dem']), findsOneWidget);
    expect(map().showHeight, isTrue);
    expect(find.byKey(const Key('hydro_dem_info')), findsOneWidget);

    // 2. A drop's way down.
    await tapKey(tester, 'hydro_next');
    expect(find.text(s['hydro_path_none']), findsOneWidget);
    await touch(const GridCell(60, 75));
    final p = FlowPathInfo.of(grid, flow, const GridCell(60, 75));
    expect(find.text(s.f('hydro_path_info', [100, km(p.length), p.drop.round()])), findsOneWidget);
    final lines = [
      for (final l in tester.widgetList<PolylineLayer>(find.byType(PolylineLayer)))
        for (final q in l.polylines)
          if (q.color == const Color(pathColour)) q,
    ];
    expect(lines.single.points, hasLength(100));

    // 3. The accumulation and the threshold: the area's 200 cells, then the slider's 1000.
    await tapKey(tester, 'hydro_next');
    expect(find.text(s.f('hydro_threshold', [200, km2(cellsArea(grid, 200, outlet.centre(grid)))])), findsOneWidget);
    tester.widget<Slider>(find.byKey(const Key('hydro_slider'))).onChangeEnd!(0.5);
    await tester.pumpAndSettle();
    expect(find.text(s.f('hydro_threshold', [1000, km2(cellsArea(grid, 1000, outlet.centre(grid)))])), findsOneWidget);

    // 4. The pour point. Snapping off, a cell beside the river: a hillside's basin.
    await tapKey(tester, 'hydro_next');
    expect(find.text(s['hydro_pour_none']), findsOneWidget);
    await tapKey(tester, 'hydro_snap');
    final beside = Iterable.generate(
      9,
      (k) => GridCell(outlet.row + k ~/ 3 - 1, outlet.col + k % 3 - 1),
    ).firstWhere((c) => acc[c.row * flow.width + c.col] < 50);
    await touch(beside);
    final small = runCells(maskRuns(basinMask(flow, beside.row, beside.col), flow.width));
    expect(small, lessThan(50));
    expect(
      find.text(
        s.f('hydro_pour_info', [
          km2(cellsArea(grid, small, beside.centre(grid))),
          acc[beside.row * flow.width + beside.col],
        ]),
      ),
      findsOneWidget,
    );
    // Snapping on, the same touch goes to the river within 10 cells, with the slider's threshold.
    await tapKey(tester, 'hydro_snap');
    await touch(beside);
    final snapped = snapToStream(flow, acc, beside.row, beside.col, radius: hydroSnapCells, minCells: 1000)!;
    expect(snapped, (row: outlet.row, col: outlet.col));
    expect(find.text(s.f('hydro_pour_info', [km2(cellsArea(grid, 1205, outlet.centre(grid))), 1205])), findsOneWidget);
    expect(find.byKey(const Key('hydro_pour')), findsOneWidget);

    // 5. Against the level-1 drawing, kept on this device; then the answer.
    await tapKey(tester, 'hydro_next');
    expect(find.text(s['hydro_from_level1']), findsOneWidget);
    final c = BasinComparison.of(grid, level1, basin, outlet);
    expect(find.text(s.f('hydro_cmp_basin', [km2(c.basinArea), km(c.basinPerimeter)])), findsOneWidget);
    // The level-1 game scored this drawing 64 against the same basin (worker scores.json).
    final error = '${c.areaError >= 0 ? '+' : '-'}${c.areaError.abs().round()}';
    expect(find.text(s.f('hydro_cmp_overlap', [64, error])), findsOneWidget);
    expect(find.byKey(const Key('hydro_undo')), findsNothing); // the level-1 drawing stays as it was
    await tapKey(tester, 'hydro_answer');
    expect(sent.single['answer'], {
      'pour': {'row': outlet.row, 'col': outlet.col},
      'threshold': 1000,
      'poly': polyToJson(level1),
    });
    expect(find.text(s.f('result_score', [100])), findsOneWidget);
    expect(find.text(s.f('hydro_outlet_basin', [km2(cellsArea(grid, 1205, outlet.centre(grid)))])), findsOneWidget);
    // After the answer the pour point stays where it is.
    await tapKey(tester, 'hydro_step_pour');
    await touch(beside);
    expect(find.text(s.f('hydro_pour_info', [km2(cellsArea(grid, 1205, outlet.centre(grid))), 1205])), findsOneWidget);
    expect(sent, hasLength(1));

    // Reopened, the page is where it was left.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HydroPlay(
            ctx: context(Api(client: MockClient((_) async => http.Response('{}', 500)))),
            loader: loader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(s['hydro_title_pour']), findsOneWidget);
    expect(find.text(s.f('result_score', [100])), findsNothing); // the score is on step 5
    await tapKey(tester, 'hydro_step_compare');
    expect(find.text(s.f('result_score', [100])), findsOneWidget);
  });

  testWidgets('play: with no level-1 drawing on the device, the basin is drawn on step 5; answers without one', (
    tester,
  ) async {
    final sent = await start(tester);
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    Future<void> touch(GridPoint p) async {
      map().onTap!(latLngOf(grid, p), null);
      await tester.pumpAndSettle();
    }

    await tapKey(tester, 'hydro_step_compare');
    expect(find.text(s['hydro_pour_none']), findsOneWidget);
    ButtonStyleButton answer() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['hydro_hand_in']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(answer().onPressed, isNull); // no pour point yet
    expect(map().doubleTapZoom, isFalse);
    await touch((row: 10, col: 10));
    await touch((row: 10, col: 20));
    // Without a pour point there is nothing to compare: the corners still go down.
    await tapKey(tester, 'hydro_step_pour');
    map().onTap!(outlet.centre(grid), null);
    await tester.pumpAndSettle();
    await tapKey(tester, 'hydro_step_compare');
    expect(find.text(s.f('hydro_draw_hint', [2])), findsOneWidget);
    await touch((row: 20, col: 15));
    expect(find.text(s['hydro_drawn_here']), findsOneWidget);
    await tapKey(tester, 'hydro_undo');
    expect(find.text(s.f('hydro_draw_hint', [2])), findsOneWidget);
    await tapKey(tester, 'hydro_clear');
    await tapKey(tester, 'hydro_answer');
    // No drawing: the answer is the pour point and the area's threshold.
    expect(sent.single['answer'], {
      'pour': {'row': outlet.row, 'col': outlet.col},
      'threshold': 200,
    });
  });

  test('the teacher’s export: pour points with their basins, thresholds and scores', () {
    const drawn2 = <GridPoint>[(row: 40, col: 10), (row: 40, col: 30), (row: 70, col: 20)];
    final a = [
      HydroAnswer('p1', outlet, 1000, const [], 100, 0),
      HydroAnswer('p2', GridCell(outlet.row, outlet.col - 1), 200, drawn2, 3, 0),
    ];
    final rows = hydroAnswersToCsv(grid, flow, a, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[1], contains(',${outlet.row},${outlet.col},'));
    expect(rows[1], contains(',1000,${(cellsArea(grid, 1205, outlet.centre(grid)) / 1e6).toStringAsFixed(3)},,100,'));
    expect(rows[2], endsWith(',3,1970-01-01T00:00:00.000Z'));
    final settings = WatershedGameSettings('watershed-fixture', 1, outlet, runs: basin);
    final geo = jsonDecode(hydroToGeoJson(grid, settings, a, 'en')) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    // The outlet, the basin, p2's drawing, and the two pour points.
    expect(features, hasLength(5));
    expect(features[2]['properties'], {'nickname': isA<String>(), 'score': 3});
    expect(features[3]['properties'], containsPair('threshold_cells', 1000));
    expect(features[4]['properties'], containsPair('pour_point', true));
    final r = HydroAnswer.fromJson({
      'participantId': 'x',
      'answer': {
        'pour': {'row': 3, 'col': 4},
        'threshold': 50,
      },
      'score': 7,
      'createdAt': 9,
    });
    expect((r.pour, r.threshold, r.poly.length, r.score), (const GridCell(3, 4), 50, 0, 7));
  });
}
