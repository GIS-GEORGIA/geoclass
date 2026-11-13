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
import 'package:geoclass/games/watershed.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/viewshed_game.dart' show GridCell;
import 'package:geoclass/terrain/watershed.dart';
import 'package:geoclass/terrain/watershed_game.dart';
import 'package:geoclass/terrain/watershed_play.dart';
import 'package:geoclass/terrain/watershed_session_page.dart';
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
  // Round the second basin, roughly, as in scores.json: the server scores it 64.
  const drawn = <GridPoint>[
    (row: 33.17, col: 4.62),
    (row: 36.5, col: 30.25),
    (row: 52.91, col: 44.08),
    (row: 82.33, col: 40.5),
    (row: 79.0, col: 12.75),
    (row: 60.25, col: 3.4),
  ];

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

  test('the game is a registered module the teacher can pick', () {
    expect(gameModule('watershed'), isA<WatershedGame>());
    expect(pickableGames(), contains('watershed'));
    expect(s['game_watershed'], 'წყალშემკრები აუზი');
  });

  test('the loader checks the flow directions against watershed.json', () async {
    final f = await loader().loadFlow('watershed-fixture', 1);
    expect(f.dirs, flowBytes);
    expect(f.streamCells, 200);
    final damaged = Uint8List.fromList(flowBytes)..[10] ^= 1;
    for (final bad in [damaged, Uint8List.sublistView(flowBytes, 1)]) {
      await expectLater(
        loader(flowFile: bad).loadFlow('watershed-fixture', 1),
        throwsA(isA<DemError>().having((e) => e.key, 'key', 'dem_bad_data')),
      );
    }
    await expectLater(loader().loadFlow('mestia', 1), throwsA(isA<DemError>()));
  });

  test('a basin is playable when big enough and clear of the edge, as the server checks it', () {
    expect(basinProblem(basinMask(flow, outlet.row, outlet.col), flow), isNull);
    // The cell with the most water drains the piece's edge.
    var most = 0;
    for (var i = 1; i < acc.length; i++) {
      if (acc[i] > acc[most]) most = i;
    }
    expect(basinProblem(basinMask(flow, most ~/ flow.width, most % flow.width), flow), 'shed_basin_edge');
    // A cell no other cell drains into.
    final lone = Iterable.generate(acc.length).firstWhere((i) => acc[i] == 1);
    expect(basinProblem(basinMask(flow, lone ~/ flow.width, lone % flow.width), flow), 'shed_basin_small');
  });

  test('drawn against the basin: the areas, the outlines, the error and the share outside', () {
    // The basin drawn round its own cells, row by row, is the basin: no error, nothing outside.
    final c = BasinComparison.of(grid, drawn, basin, outlet);
    expect(c.basinArea, closeTo(cellsArea(grid, 1205, outlet.centre(grid)), 1e-6));
    expect(c.basinArea / 1e6, closeTo(1205 * 0.0009, 0.002)); // 30 m cells, a little smaller on the ground
    final cells = runCells(polygonRuns(drawn, maxRow: grid.height));
    expect(c.outside, closeTo(100 * (cells - 1084) / cells, 1e-9));
    expect(c.areaError, closeTo(100 * (c.drawnArea - c.basinArea) / c.basinArea, 1e-9));
    expect(c.drawnArea, closeTo(cellsArea(grid, cells, outlet.centre(grid)), 0.02 * c.drawnArea));
    // A single cell's outline is its four sides.
    final one = basinOutline(grid, const [
      [5, 5, 6],
    ], outlet.centre(grid));
    expect(one, closeTo(4 * grid.cell / utmScale(42.25, 42.7, 38), 0.5));
    expect(km2(1234567), '1.23');
    expect(km2(23456789), '23.5');
  });

  test('settings: the teacher sends the area and the outlet; the basin comes back from the server', () {
    final sentJson = WatershedGameSettings('watershed-fixture', 1, outlet).toJson();
    expect(sentJson, {
      'area': {'id': 'watershed-fixture', 'version': 1},
      'outlet': {'row': outlet.row, 'col': outlet.col},
    });
    final teacher = WatershedGameSettings.fromJson({...sentJson, 'runs': second['runs'], 'cells': 1205});
    expect(teacher.runs, basin);
    expect(WatershedGameSettings.fromJson(sentJson).runs, isNull);
    expect(() => WatershedGameSettings.fromJson({'area': 1}), throwsFormatException);
    expect(roundPoint((row: 1.23456, col: 7.005)), (row: 1.23, col: 7.01));
  });

  testWidgets('setup: a touch finds the stream, the basin shows, and the session carries the outlet', (tester) async {
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
                builder: (_) => WatershedSetupPage(s: s, loader: loader()),
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

    // Far from any stream: nothing to put the outlet on.
    final dry = Iterable.generate(
      acc.length,
    ).firstWhere((i) => snapToStream(flow, acc, i ~/ flow.width, i % flow.width) == null);
    touch(GridCell(dry ~/ flow.width, dry % flow.width));
    await tester.pump();
    expect(find.text(s['shed_need_stream']), findsOneWidget);
    expect(find.byKey(const Key('shed_outlet')), findsNothing);

    // Next to the second basin's outlet: the touch goes to the strongest stream cell near it.
    touch(GridCell(outlet.row, outlet.col + 1));
    await tester.pumpAndSettle();
    final snapped = snapToStream(flow, acc, outlet.row, outlet.col + 1)!;
    final mask = basinMask(flow, snapped.row, snapped.col);
    expect(basinProblem(mask, flow), isNull);
    expect(find.byKey(const Key('shed_outlet')), findsOneWidget);
    final area = km2(
      cellsArea(grid, runCells(maskRuns(mask, flow.width)), GridCell(snapped.row, snapped.col).centre(grid)),
    );
    expect(find.text(s.f('shed_basin_area', [area])), findsOneWidget);
    expect(find.text(s['shed_need_stream']), findsNothing);
    // A touch that misses says so, but keeps the outlet: the session can still be made.
    touch(GridCell(dry ~/ flow.width, dry % flow.width));
    await tester.pump();
    expect(find.text(s['shed_need_stream']), findsOneWidget);
    expect(find.byKey(const Key('shed_outlet')), findsOneWidget);
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(made, {
      'watershed': {
        'area': {'id': 'watershed-fixture', 'version': 1},
        'outlet': {'row': snapped.row, 'col': snapped.col},
      },
    });
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

  testWidgets('play: corners by touches, undo and clear, no crossing; the basin shows after the answer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'ok': true, 'duplicate': false, 'score': 64, 'basin': second['runs']}), 201);
      }),
    );
    final settings = WatershedGameSettings('watershed-fixture', 1, outlet).toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatershedPlay(ctx: context(api, settings), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = overlays(tester);
    expect(find.text(s['shed_question']), findsOneWidget);
    expect(find.byKey(const Key('shed_outlet')), findsOneWidget);
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    expect(map().doubleTapZoom, isFalse);
    ButtonStyleButton answer() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['play_answer']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    Future<void> touch(GridPoint p) async {
      map().onTap!(latLngOf(grid, p), null);
      await tester.pump();
    }

    // A bow tie: its sides cross, so it can't be sent; undo and clear take it away.
    for (final p in const <GridPoint>[(row: 10, col: 10), (row: 10, col: 20), (row: 20, col: 10), (row: 20, col: 20)]) {
      await touch(p);
    }
    expect(find.byKey(const Key('shed_crossing')), findsOneWidget);
    expect(answer().onPressed, isNull);
    await tester.tap(find.byKey(const Key('shed_undo')));
    await tester.pump();
    expect(find.byKey(const Key('shed_crossing')), findsNothing);
    expect(answer().onPressed, isNotNull); // a triangle
    await tester.tap(find.byKey(const Key('shed_clear')));
    await tester.pump();
    expect(find.text(s.f('shed_vertices', [0])), findsOneWidget);
    expect(answer().onPressed, isNull);

    for (final p in drawn) {
      await touch(p);
    }
    final pts = [for (final p in drawn) latLngOf(grid, p)];
    expect(find.text(s.f('shed_drawn', [6, km2(geodesicArea(pts)), km(geodesicPerimeter(pts))])), findsOneWidget);
    expect(overlays(tester), before); // no basin yet
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['round'], 0);
    expect(sent.single['answer'], {'poly': polyToJson(drawn)});
    expect(find.text(s.f('result_score', [64])), findsOneWidget);
    expect(overlays(tester), before + 1); // the basin
    final c = BasinComparison.of(grid, drawn, basin, outlet);
    expect(find.text(s.f('shed_result_drawn', [km2(c.drawnArea), km(c.drawnPerimeter)])), findsOneWidget);
    expect(find.text(s.f('shed_result_basin', [km2(c.basinArea), km(c.basinPerimeter)])), findsOneWidget);
    expect(find.byKey(const Key('shed_result_error')), findsOneWidget);
    expect(find.text(s['play_answer']), findsNothing);
    // Touches after the answer change nothing.
    await touch((row: 5, col: 5));
    expect(sent, hasLength(1));
  });

  test('the teacher’s export: every polygon with its score, the basin, the outlet', () {
    final answers = [
      WatershedAnswer('p1', drawn, 64, 0),
      const WatershedAnswer('p2', [(row: 40, col: 10), (row: 40, col: 30), (row: 70, col: 20)], 20, 0),
    ];
    final rows = watershedAnswersToCsv(grid, answers, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[1], contains(',6,'));
    expect(rows[1], endsWith(',64,1970-01-01T00:00:00.000Z'));
    final settings = WatershedGameSettings('watershed-fixture', 1, outlet, runs: basin);
    final geo = jsonDecode(watershedToGeoJson(grid, settings, answers, 'en')) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(features, hasLength(4));
    expect(features[0]['properties'], {'outlet': true});
    expect((features[1]['geometry'] as Map)['type'], 'MultiPolygon');
    expect(((features[1]['geometry'] as Map)['coordinates'] as List), hasLength(basin.length));
    expect((features[1]['properties'] as Map)['area_km2'], closeTo(1205 * 0.0009, 0.002));
    final ring = (((features[2]['geometry'] as Map)['coordinates'] as List).first as List);
    expect(ring, hasLength(7)); // closed
    expect(ring.first, ring.last);
    expect((features[3]['properties'] as Map)['score'], 20);
  });
}
