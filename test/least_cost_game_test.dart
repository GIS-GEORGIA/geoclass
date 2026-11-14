import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/least_cost.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/least_cost.dart';
import 'package:geoclass/terrain/least_cost_game.dart';
import 'package:geoclass/terrain/least_cost_play.dart';
import 'package:geoclass/terrain/least_cost_session_page.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/viewshed_game.dart' show GridCell;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const dir = 'test/fixtures/least_cost';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  final routes = jsonDecode(File('$dir/routes.json').readAsStringSync()) as Map<String, dynamic>;
  final slopeRoutes = (routes['models'] as List).first as Map<String, dynamic>;
  final a = GridCell((routes['start'] as List)[0] as int, (routes['start'] as List)[1] as int);
  final b = GridCell((routes['end'] as List)[0] as int, (routes['end'] as List)[1] as int);
  const model = CostModel.slope(15);
  final surface = CostSurface(grid, model);
  const s = S('ka');

  DemLoader loader() => DemLoader(
    base: 'https://x.test',
    client: MockClient(
      (req) async => switch (req.url.path) {
        '/areas/catalog.json' => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'areas': [
                {
                  'id': 'least-cost-fixture',
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
        '/areas/least-cost-fixture/1/area.json' => http.Response.bytes(utf8.encode(jsonEncode(metaJson)), 200),
        '/areas/least-cost-fixture/1/dem.u16.gz' => http.Response.bytes(bytes, 200),
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
    expect(gameModule('least-cost'), isA<LeastCostGame>());
    expect(pickableGames(), contains('least-cost'));
    expect(s['game_least-cost'], 'ყველაზე იოლი გზა');
  });

  test('settings: the teacher sends the area, the model, A, B and the best route; the cost comes back', () {
    final sent = LeastCostGameSettings('least-cost-fixture', 1, model, a, b, steps: '0123').toJson();
    expect(sent, {
      'area': {'id': 'least-cost-fixture', 'version': 1},
      'model': {'kind': 'slope', 'theta': 15.0},
      'start': {'row': a.row, 'col': a.col},
      'end': {'row': b.row, 'col': b.col},
      'steps': '0123',
    });
    final back = LeastCostGameSettings.fromJson({...sent, 'best': 1234.5});
    expect(back.best, 1234.5);
    expect(back.model, model);
    final student = LeastCostGameSettings.fromJson({...sent}..remove('steps'));
    expect(student.steps, isNull);
    expect(student.toJson().containsKey('steps'), isFalse);
    expect(() => LeastCostGameSettings.fromJson({'area': 1}), throwsFormatException);
    expect(
      () => LeastCostGameSettings.fromJson({
        ...sent,
        'model': {'kind': 'x'},
      }),
      throwsFormatException,
    );
    expect(costText(s, model, 15426.39), s.f('route_cost_slope', ['15.4']));
    expect(costText(s, const CostModel.tobler(), 127.36), s.f('route_cost_tobler', [127]));
  });

  testWidgets('setup: A then B by touches, the best route as the fixture has it, and the session carries it', (
    tester,
  ) async {
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
                builder: (_) => LeastCostSetupPage(s: s, loader: loader()),
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
    Future<void> touch(GridCell c) async {
      map().onTap!(c.centre(grid), grid.heightAt(c.centre(grid)));
      await tester.pump();
    }

    ButtonStyleButton create() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['create']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(find.text(s['route_need_a']), findsOneWidget);
    // The grid's edge has no slope: no route may stand there.
    await touch(const GridCell(0, 0));
    expect(find.text(s['route_need_ground']), findsOneWidget);
    expect(find.byKey(const Key('route_A')), findsNothing);

    await touch(a);
    expect(find.byKey(const Key('route_A')), findsOneWidget);
    expect(find.text(s['route_need_b']), findsOneWidget);
    // B too close to A.
    await touch(GridCell(a.row + 3, a.col + 3));
    expect(find.text(s['route_too_close']), findsOneWidget);
    expect(create().onPressed, isNull);
    // A touch after both starts again at A.
    await touch(a);
    await touch(b);
    expect(find.byKey(const Key('route_B')), findsOneWidget);
    final best = leastCostRoute(surface, cellIndex(grid, a), cellIndex(grid, b))!;
    expect(best.cost, closeTo(slopeRoutes['best'] as double, 1e-6));
    expect(find.text(routeSummary(s, surface, best.cells, best.cost)), findsOneWidget);

    // The model changes the route.
    await tester.tap(find.text(s['route_model_tobler']));
    await tester.pump();
    final tobler = leastCostRoute(CostSurface(grid, const CostModel.tobler()), cellIndex(grid, a), cellIndex(grid, b))!;
    expect(find.textContaining(s.f('route_cost_tobler', [tobler.cost.round()])), findsOneWidget);
    await tester.tap(find.text(s.f('route_model_slope', [15])));
    await tester.pump();

    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(made, {
      'leastCost': {
        'area': {'id': 'least-cost-fixture', 'version': 1},
        'model': {'kind': 'slope', 'theta': 15.0},
        'start': {'row': a.row, 'col': a.col},
        'end': {'row': b.row, 'col': b.col},
        'steps': slopeRoutes['steps'],
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

  testWidgets('play: corners by touches, undo and clear, no blocked route; the best route shows after the answer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final steps = slopeRoutes['steps'] as String;
    final best = slopeRoutes['best'] as double;
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'ok': true, 'duplicate': false, 'score': 68, 'steps': steps, 'best': best}),
          201,
        );
      }),
    );
    // As the student gets it: no best route.
    final settings = LeastCostGameSettings('least-cost-fixture', 1, model, a, b).toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LeastCostPlay(ctx: context(api, settings), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(s['route_question']), findsOneWidget);
    expect(find.byKey(const Key('route_A')), findsOneWidget);
    expect(find.byKey(const Key('route_B')), findsOneWidget);
    MapWorkspace map() => tester.widget<MapWorkspace>(find.byType(MapWorkspace));
    expect(map().doubleTapZoom, isFalse);
    ButtonStyleButton answer() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['play_answer']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    Future<void> touch(GridCell c) async {
      map().onTap!(c.centre(grid), null);
      await tester.pump();
    }

    // The straight line A–B is already a route.
    final straight = routeThrough([cellIndex(grid, a), cellIndex(grid, b)], grid.width);
    final straightCost = routeCost(surface, straight)!;
    expect(
      find.text('${s.f('route_corners', [0])} · ${routeSummary(s, surface, straight, straightCost)}'),
      findsOneWidget,
    );
    expect(answer().onPressed, isNotNull);
    // A corner on the edge, where there is no slope: the route can't be sent.
    await touch(const GridCell(0, 80));
    expect(find.byKey(const Key('route_blocked')), findsOneWidget);
    expect(answer().onPressed, isNull);
    await tester.tap(find.byKey(const Key('route_undo')));
    await tester.pump();
    expect(find.byKey(const Key('route_blocked')), findsNothing);
    await touch(const GridCell(60, 40));
    await touch(const GridCell(30, 100));
    expect(find.textContaining(s.f('route_corners', [2])), findsOneWidget);
    await tester.tap(find.byKey(const Key('route_clear')));
    await tester.pump();
    expect(find.textContaining(s.f('route_corners', [0])), findsOneWidget);

    // The fourth route of routes.json: the server scores it 68.
    const via = [GridCell(50, 80), GridCell(55, 85), GridCell(20, 120)];
    for (final c in via) {
      await touch(c);
    }
    final mine = routeThrough([
      for (final c in [a, ...via, b]) cellIndex(grid, c),
    ], grid.width);
    final mineCost = routeCost(surface, mine)!;
    final four = (slopeRoutes['routes'] as List)[3] as Map<String, dynamic>;
    expect(mineCost, closeTo(four['cost'] as double, 1e-6));
    expect(find.text(s['route_result_hint']), findsNothing);
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['round'], 0);
    expect(sent.single['answer'], {
      'via': [
        for (final c in via) [c.row, c.col],
      ],
    });
    expect(find.text(s.f('result_score', [68])), findsOneWidget);
    expect(find.text(s.f('route_result_mine', [routeSummary(s, surface, mine, mineCost)])), findsOneWidget);
    final bestCells = cellsOf(cellIndex(grid, a), steps, grid.width);
    expect(find.text(s.f('route_result_best', [routeSummary(s, surface, bestCells, best)])), findsOneWidget);
    expect(find.text(s['play_answer']), findsNothing);
    // Touches after the answer change nothing.
    await touch(const GridCell(70, 70));
    expect(find.textContaining(s.f('route_corners', [4])), findsNothing);
    expect(sent, hasLength(1));
  });

  testWidgets('play: reopening the link shows the answer already given', (tester) async {
    final steps = slopeRoutes['steps'] as String;
    SharedPreferences.setMockInitialValues({
      'progress_token-1': jsonEncode({
        'via': [
          [60, 40],
        ],
        'sent': true,
        'score': 55,
        'steps': steps,
        'best': slopeRoutes['best'],
        'resetAt': 0,
      }),
    });
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api(client: MockClient((_) async => http.Response('', 500)));
    final settings = LeastCostGameSettings('least-cost-fixture', 1, model, a, b).toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LeastCostPlay(ctx: context(api, settings), loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(s.f('result_score', [55])), findsOneWidget);
    expect(find.text(s['play_answer']), findsNothing);
  });

  test('the teacher’s export: a row per student, and A, B, the best route and every route as GeoJSON', () {
    final settings = LeastCostGameSettings(
      'least-cost-fixture',
      1,
      model,
      a,
      b,
      steps: slopeRoutes['steps'] as String,
      best: slopeRoutes['best'] as double,
    );
    final answers = [
      const RouteAnswer('p1', [GridCell(50, 80), GridCell(55, 85), GridCell(20, 120)], 68, 0),
      const RouteAnswer('p2', [], 68, 0),
    ];
    final rows = routeAnswersToCsv(surface, settings, answers, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[0], endsWith('nickname,corners,cost_m,length_km,climb_m,score,created_at'));
    final four = (slopeRoutes['routes'] as List)[3] as Map<String, dynamic>;
    expect(rows[1], contains(',3,${(four['cost'] as double).toStringAsFixed(1)},'));
    expect(rows[1], endsWith(',68,1970-01-01T00:00:00.000Z'));
    expect(rows[2], contains(',0,'));

    final geo = jsonDecode(routesToGeoJson(grid, settings, answers, 'en')) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(features, hasLength(5));
    expect(features[0]['properties'], {'point': 'A'});
    expect(features[1]['properties'], {'point': 'B'});
    final bestLine = (features[2]['geometry'] as Map)['coordinates'] as List;
    expect(bestLine, hasLength((slopeRoutes['steps'] as String).length + 1));
    expect((features[2]['properties'] as Map)['cost'], slopeRoutes['best']);
    expect(bestLine.first, (features[0]['geometry'] as Map)['coordinates']);
    expect(bestLine.last, (features[1]['geometry'] as Map)['coordinates']);
    expect((features[4]['properties'] as Map)['score'], 68);
    expect(((features[4]['geometry'] as Map)['coordinates'] as List), hasLength(four['cells'] as int));
  });
}
