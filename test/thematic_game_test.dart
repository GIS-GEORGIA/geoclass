import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/games/thematic.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/puzzle.dart';
import 'package:geoclass/thematic/thematic.dart';
import 'package:geoclass/thematic/thematic_map.dart';
import 'package:geoclass/thematic/thematic_play.dart';
import 'package:geoclass/thematic/thematic_session_page.dart';
import 'package:geoclass/thematic/thematic_setup.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Taps a widget after scrolling it into view: the setup's form and the play panel scroll.
Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

void main() {
  final all = parseGeoUnits(File('assets/ge_units.json').readAsStringSync());
  const s = S('ka');
  // Four regions: two counts and a rate; Guria has no people figure.
  const settings = ThematicSettings(
    level: 'regions',
    title: 'მოსახლეობა',
    mode: 'target',
    units: ['ge_guria', 'ge_adjara', 'ge_imereti', 'ge_kakheti', 'ge_tbilisi'],
    fields: [
      ThematicField('people', 'count', [null, 350000, 480000, 300000, 1200000]),
      ThematicField('share', 'rate', [1.5, 2, 3, 4.5, 9]),
    ],
    target: ThematicChoice(field: 0, normalise: 'area', method: 'quantile', classes: 3, ramp: 'Greens'),
  );

  test('the game is a registered module the teacher can pick', () {
    expect(gameModule('thematic'), isA<ThematicGame>());
    expect(pickableGames(), contains('thematic'));
    expect(s['game_thematic'], 'თემატური რუკა');
  });

  test('a view: the fills, the legend and the caption; the regions without a row are grey', () {
    final base = ThematicBase.of(all, settings);
    expect(base.others.map((u) => u.id), isNot(contains('ge_guria')));
    expect(base.others, hasLength(all.regions.length - 5));
    final v = ThematicView.of(base, settings, settings.target!);
    expect(v.classified!.values[0], isNull);
    expect(v.fillOf(0), thematicNoData);
    expect(v.classified!.values[4], closeTo(1200000 / base.areas[4], 1e-6));
    expect(v.fillOf(4), const Color(0xff31a354)); // Tbilisi, the densest: the darkest of three greens
    final legend = v.legend(s);
    expect(legend, hasLength(4));
    expect(legend.last.label, '${s['thematic_no_data']} (1)');
    expect(v.caption(s), s.f('thematic_per_area', ['people']));
    // The page paints without a screen.
    final rec = ui.PictureRecorder();
    paintThematicPage(Canvas(rec), const Size(1000, 707), v, s, settings.title);
    rec.endRecording();
  });

  testWidgets('the A4 PDF is made', (tester) async {
    final v = ThematicView.of(ThematicBase.of(all, settings), settings, settings.target!);
    final bytes = (await tester.runAsync(() => thematicPdf(v, s, settings.title)))!;
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(10000));
  });

  testWidgets('setup: the sample, matched; a target chosen; the session carries the data and the target', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Map<String, dynamic>? made;
    Future<(String, Uint8List)?> pick() async => (
      'people.csv',
      Uint8List.fromList(utf8.encode('region;people\nGuria;100\nAdjara;350\nImereti;480\nSomewhere;5\n')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => made = await Navigator.of(context).push<Map<String, dynamic>>(
              MaterialPageRoute(
                builder: (_) => ThematicSetupPage(s: s, lang: 'ka', units: all, pick: pick),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    ButtonStyleButton create() => tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(s['create']), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(create().onPressed, isNull);

    // The teacher's file: one row matches no region, and is picked by hand... or left out.
    await tapKey(tester, 'thematic_file');
    await tester.pumpAndSettle();
    expect(find.text(s.f('thematic_matched', [3, 4, all.regions.length])), findsOneWidget);
    expect(find.text('Somewhere'), findsOneWidget);
    expect(find.byKey(const Key('thematic_warn_counts')), findsOneWidget); // the default target: people as it is
    await tapKey(tester, 'thematic_normalise_area');
    await tester.pump();
    expect(find.byKey(const Key('thematic_warn_counts')), findsNothing);
    expect(find.byKey(const Key('thematic_method_manual')), findsNothing); // not for a target
    await tapKey(tester, 'thematic_method_jenks');
    await tapKey(tester, 'thematic_classes_3');
    await tester.pump();
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(made, {
      'thematic': {
        'level': 'regions',
        'title': 'people',
        'mode': 'target',
        'units': ['ge_guria', 'ge_adjara', 'ge_imereti'],
        'fields': [
          {
            'name': 'people',
            'kind': 'count',
            'values': [100.0, 350.0, 480.0],
          },
        ],
        'target': {'field': 0, 'normalise': 'area', 'method': 'jenks', 'classes': 3, 'ramp': 'Blues'},
      },
    });
  });

  testWidgets('setup: the sample of areas, free mode, municipalities', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Map<String, dynamic>? made;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => made = await Navigator.of(context).push<Map<String, dynamic>>(
              MaterialPageRoute(
                builder: (_) => ThematicSetupPage(s: s, lang: 'ka', units: all),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'thematic_level_municipalities');
    await tester.pump();
    await tapKey(tester, 'thematic_sample');
    await tester.pumpAndSettle();
    final n = all.municipalities.length;
    expect(find.text(s.f('thematic_matched', [n, n, n])), findsOneWidget);
    await tapKey(tester, 'thematic_mode_free');
    await tester.pump();
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    final t = made!['thematic'] as Map<String, dynamic>;
    expect(t['mode'], 'free');
    expect(t.containsKey('target'), isFalse);
    expect((t['units'] as List), hasLength(n));
    expect(((t['fields'] as List).single as Map)['kind'], 'rate');
    expect(utf8.encode(jsonEncode(t)).length, lessThan(thematicSettingsMax));
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

  Map<String, dynamic> studentView(ThematicSettings st) => st.toJson()..remove('target');

  testWidgets('play: choices change the legend; manual breaks; handed in, the score and the target show', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((req) async {
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({'ok': true, 'duplicate': false, 'score': 50, 'target': settings.target!.toJson()}),
          201,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThematicPlay(ctx: context(api, studentView(settings)), units: all),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(s['thematic_question_target']), findsOneWidget);
    expect(find.text('people'), findsWidgets);
    // The default: people as they are, quantile, 5 classes. A count as it is: the warning.
    expect(find.byKey(const Key('thematic_warn_counts')), findsOneWidget);
    expect(find.text(s.f('thematic_method_line', [s['thematic_method_quantile'], 5])), findsOneWidget);
    await tapKey(tester, 'thematic_classes_4');
    await tester.pump();
    await tapKey(tester, 'thematic_method_manual');
    await tester.pump();
    expect(find.byKey(const Key('thematic_break_2')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('thematic_break_0')), '400000');
    await tester.enterText(find.byKey(const Key('thematic_break_1')), '300000');
    await tester.pump();
    expect(find.text(s['thematic_breaks_bad']), findsOneWidget);
    await tester.enterText(find.byKey(const Key('thematic_break_0')), '320000');
    await tester.enterText(find.byKey(const Key('thematic_break_1')), '400000');
    await tester.enterText(find.byKey(const Key('thematic_break_2')), '500000');
    await tester.pump();
    expect(find.text(s['thematic_breaks_bad']), findsNothing);
    expect(find.text('300000 – 320000 (1)'), findsOneWidget);
    expect(find.text('500000 – 1200000 (1)'), findsOneWidget);

    // The three classifications side by side.
    await tapKey(tester, 'thematic_compare');
    await tester.pumpAndSettle();
    expect(find.text(s['thematic_method_jenks']), findsWidgets);
    await tester.tap(find.text(s['close']));
    await tester.pumpAndSettle();

    await tapKey(tester, 'thematic_answer');
    await tester.pumpAndSettle();
    expect(sent.single['answer'], {
      'field': 0,
      'normalise': 'none',
      'method': 'manual',
      'classes': 4,
      'ramp': 'Blues',
      'breaks': [320000.0, 400000.0, 500000.0],
    });
    expect(find.text(s.f('result_score', [50])), findsOneWidget);
    expect(find.byKey(const Key('thematic_target')), findsOneWidget);
    expect(find.byKey(const Key('thematic_answer')), findsNothing);
    expect(find.byKey(const Key('thematic_pdf')), findsOneWidget);
  });

  testWidgets('play, free mode: handed in, no score; reopening keeps it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final free = ThematicSettings.fromJson({...studentView(settings), 'mode': 'free'});
    final api = Api(client: MockClient((_) async => http.Response(jsonEncode({'ok': true, 'duplicate': false}), 201)));
    Widget page() => MaterialApp(
      home: Scaffold(
        body: ThematicPlay(ctx: context(api, free.toJson()), units: all),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text(s['thematic_question_free']), findsOneWidget);
    await tapKey(tester, 'thematic_field_1');
    await tester.pump();
    expect(find.byKey(const Key('thematic_warn_counts')), findsNothing); // a rate
    await tapKey(tester, 'thematic_answer');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('thematic_sent')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('thematic_sent')), findsOneWidget);
  });

  test('the teacher\'s export: a row per student, and the units with the numbers and the target class', () {
    final answers = [
      ThematicAnswer('p1', settings.target, 100, 0),
      const ThematicAnswer('p2', ThematicChoice(field: 1, method: 'manual', classes: 3, breaks: [2, 4]), 25, 0),
    ];
    final rows = thematicAnswersToCsv(settings, answers, 'en').trim().split('\r\n');
    expect(rows, hasLength(3));
    expect(rows[1], contains(',"people",area,quantile,3,Greens,"",100,'));
    expect(rows[2], contains(',"share",none,manual,3,Blues,"2.0 4.0",25,'));
    final base = ThematicBase.of(all, settings);
    final geo = jsonDecode(thematicToGeoJson(base, settings)) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(features, hasLength(5));
    final tbilisi = features.last['properties'] as Map<String, dynamic>;
    expect(tbilisi['id'], 'ge_tbilisi');
    expect(tbilisi['people'], 1200000);
    expect(tbilisi['target_class'], 3);
    expect((features.first['properties'] as Map)['target_class'], isNull);
    final ring = ((features.first['geometry'] as Map)['coordinates'] as List).first as List;
    expect(ring.first, ring.last);
  });
}
