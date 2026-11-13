import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/profile.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:geoclass/terrain/profile.dart';
import 'package:geoclass/terrain/profile_chart.dart';
import 'package:geoclass/terrain/profile_game.dart';
import 'package:geoclass/terrain/profile_play.dart';
import 'package:geoclass/terrain/profile_session_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  final ref = jsonDecode(File('$dir/profile.json').readAsStringSync()) as Map<String, dynamic>;
  // The fixture's line, without its last vertex: the reference line crosses the grid's one empty cell.
  final line = [
    for (final v in (ref['vertices'] as List).take(2))
      LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
  ];
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
    expect(gameModule('profile'), isA<ProfileGame>());
    expect(pickableGames(), contains('profile'));
    expect(s['game_profile'], 'რელიეფის პროფილი');
    for (final k in profileKinds) {
      expect(s['profile_q_$k'], isNot('profile_q_$k'));
      expect(const S('en')['profile_q_$k'], isNot('profile_q_$k'));
    }
  });

  test('right answers come from the profile, rounded as sent', () {
    final p = TerrainProfile.along(grid, line);
    expect(profileAnswer(p, 'max'), closeTo(p.highest!.height!, 0.05));
    expect(profileAnswer(p, 'min'), closeTo(p.lowest!.height!, 0.05));
    expect(profileAnswer(p, 'length'), closeTo(p.length, 0.005));
    expect(profileAnswer(p, 'where_max'), closeTo(p.highest!.distance, 0.005));
    expect(profileAnswer(p, 'steepest'), isNull); // one section: nothing to choose
    final three = TerrainProfile.along(grid, [...line, line.first]);
    expect(profileAnswer(three, 'steepest'), three.steepest!.index.toDouble());
  });

  test('settings go to the server and come back the same; students get no answers', () {
    final settings = ProfileGameSettings('fixture', 1, line, const [
      ProfileQuestion('max', answer: 1902.5, tolerance: 50),
      ProfileQuestion('length', answer: 738.2),
    ], length: 738.2);
    final json = settings.toJson();
    expect(json['line'], [
      [line[0].latitude, line[0].longitude],
      [line[1].latitude, line[1].longitude],
    ]);
    expect((json['questions'] as List)[1], {'kind': 'length', 'answer': 738.2});
    final back = ProfileGameSettings.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
    expect(back.line, line);
    expect(back.questions.first.tolerance, 50);
    // As join gives it: kinds and tolerances only.
    final student = ProfileGameSettings.fromJson({
      'area': {'id': 'fixture', 'version': 1},
      'line': json['line'],
      'questions': [
        {'kind': 'max', 'tolerance': 50},
      ],
    });
    expect(student.questions.single.answer, isNull);
    expect(() => ProfileGameSettings.fromJson({'area': 'x'}), throwsFormatException);
  });

  test('answer values read as metres, kilometres or a section', () {
    expect(profileValue('max', 1902.46, s), '1902 მ');
    expect(profileValue('length', 13300, s), '13.3 კმ');
    expect(profileValue('where_max', 450, s), '450 მ');
    expect(profileValue('steepest', 1, s), 'მონაკვეთი 2');
  });

  testWidgets('setup: draw a line, and the session carries the questions with their right answers', (tester) async {
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
                builder: (_) => ProfileSetupPage(s: s, loader: loader()),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final map = tester.getRect(find.byType(MapWorkspace));
    await tester.tapAt(map.center - const Offset(120, 60));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(map.center + const Offset(120, 60));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProfileChart), findsOneWidget);
    // One section: "steepest" can't be asked.
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('profile_kind_steepest'))).onChanged, isNull);
    await tester.tap(find.byKey(const Key('profile_kind_min')));
    await tester.pump();

    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    final settings = ProfileGameSettings.fromJson(made!['profile'] as Map<String, dynamic>);
    expect(settings.areaId, 'fixture');
    expect(settings.line, hasLength(2));
    expect(settings.questions.map((q) => q.kind), ['max', 'length', 'where_max']);
    final p = TerrainProfile.along(grid, settings.line);
    expect(settings.questions[0].answer, profileAnswer(p, 'max'));
    expect(settings.questions[0].tolerance, 50);
    expect(settings.length, profileAnswer(p, 'length'));
  });

  testWidgets('play: the chart has no numbers; an answer goes to the server and its result shows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    mockTileCache(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent.add(body);
        final kind = (body['answer'] as Map)['kind'];
        return http.Response(
          jsonEncode({
            'ok': true,
            'duplicate': false,
            'score': 50,
            'kind': kind,
            'answer': kind == 'max' ? 1900.0 : 700.0,
          }),
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
        'line': [
          for (final p in line) [p.latitude, p.longitude],
        ],
        'questions': [
          {'kind': 'max', 'tolerance': 50},
          {'kind': 'where_max'},
        ],
      },
      now: 0,
      resetAt: 0,
      api: api,
      onStopped: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePlay(ctx: ctx, loader: loader()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfileChart), findsOneWidget);
    expect(tester.widget<ProfileChart>(find.byType(ProfileChart)).marks, isFalse);
    expect(find.byType(ProfileSummary), findsNothing);
    final label = tester.getSemantics(find.byType(ProfileChart)).label;
    expect(label, isNot(contains(s['profile_max'])));
    expect(label, isNot(contains(s['profile_min'])));
    expect(find.text(s['profile_q_max']), findsOneWidget);
    expect(find.text(s.f('profile_within', [50])), findsOneWidget);

    await tester.tap(find.text(s['play_answer']));
    await tester.pump();
    expect(find.text(s['profile_need_number']), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile_input')), '1880,5');
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.single['round'], 0);
    expect(sent.single['answer'], {'kind': 'max', 'value': 1880.5});
    expect(find.text(s.f('result_score', [50])), findsOneWidget);
    expect(find.text(s.f('profile_right', ['1900 მ'])), findsOneWidget);

    await tester.tap(find.text(s['next']));
    await tester.pumpAndSettle();
    expect(find.text(s['profile_q_where_max']), findsOneWidget);
    final chart = tester.getRect(find.byType(ProfileChart));
    await tester.tapAt(Offset(chart.left + ProfilePainter.left + 40, chart.center.dy));
    await tester.pump();
    expect(find.byKey(const Key('profile_at')), findsOneWidget);
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();
    expect(sent.last['answer']['kind'], 'where_max');
    expect(sent.last['answer']['value'], greaterThan(0));

    await tester.tap(find.text(s['next']));
    await tester.pumpAndSettle();
    expect(find.text(s['done_title']), findsOneWidget);
    expect(find.textContaining(s.f('done_total', [100, 200])), findsOneWidget);
  });

  test('the teacher’s export and leaderboard', () {
    final answers = [
      const ProfileAnswer('p1', 0, 'max', 1880, 60, 0),
      const ProfileAnswer('p2', 0, 'max', 1900, 100, 0),
      const ProfileAnswer('p1', 1, 'steepest', 1, 0, 0),
    ];
    final board = profileLeaderboard(answers);
    expect(board.map((r) => (r.participantId, r.score, r.answered)), [('p2', 100, 1), ('p1', 60, 2)]);
    final csv = profileAnswersToCsv(answers, const [
      ProfileQuestion('max', answer: 1902.5),
      ProfileQuestion('steepest', answer: 0),
    ], 'en');
    final rows = csv.trim().split('\r\n');
    expect(rows, hasLength(4));
    expect(rows[3], contains(',2,steepest,2,1,0,')); // sections counted from 1
  });
}
