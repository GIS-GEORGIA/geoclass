import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/plates.dart';
import 'package:geoclass/plates_play.dart';
import 'package:geoclass/plates_session_page.dart';
import 'package:geoclass/plates_setup_page.dart';
import 'package:geoclass/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const s = S('ka');
  final shapes = parsePlateShapes(File('assets/plates.json').readAsStringSync());

  group('outlines', () {
    test('every shape has both names, a group and parts inside the box', () {
      expect(shapes.length, greaterThanOrEqualTo(30));
      expect(shapes.map((x) => x.id).toSet(), hasLength(shapes.length));
      for (final x in shapes) {
        expect(x.ka, isNotEmpty, reason: x.id);
        expect(x.en, isNotEmpty, reason: x.id);
        expect(plateGroups, contains(x.group));
        expect(x.polys, isNotEmpty, reason: x.id);
        for (final p in x.polys.expand((r) => r)) {
          expect(p.dx.abs() <= 1.001 && p.dy.abs() <= 1.001, isTrue, reason: x.id);
        }
      }
    });

    test('a point is inside a shape only where the shape is', () {
      final square = PlateShape('sq', 'კვ', 'sq', 'country', const [
        [Offset(-0.5, -0.5), Offset(0.5, -0.5), Offset(0.5, 0.5), Offset(-0.5, 0.5)],
      ]);
      expect(square.contains(Offset.zero), isTrue);
      expect(square.contains(const Offset(0.9, 0)), isFalse);
      final saudi = shapes.firstWhere((x) => x.id == 'saudi_arabia');
      expect(saudi.contains(Offset.zero), isTrue);
      expect(saudi.contains(const Offset(-0.99, -0.99)), isFalse);
    });
  });

  group('plates', () {
    test('every shape shows: enough of the dots belong to the figure', () {
      for (final x in shapes) {
        final dots = makePlate(x, platePalettes.first, 1, tries: 6000);
        final share = dots.where((d) => d.figure).length / dots.length;
        expect(share, inInclusiveRange(0.05, 0.75), reason: x.id);
      }
    });

    test('dots stay inside the circle and never overlap', () {
      final dots = makePlate(shapes.first, platePalettes[1], 7);
      expect(dots.length, greaterThan(800));
      for (final d in dots) {
        expect(d.center.distance + d.radius, lessThanOrEqualTo(1.0001));
      }
      for (var i = 0; i < dots.length; i += 7) {
        for (var j = i + 1; j < dots.length; j++) {
          expect((dots[i].center - dots[j].center).distance, greaterThan(dots[i].radius + dots[j].radius));
        }
      }
    });

    test('the same seed makes the same plate, another seed another', () {
      final a = makePlate(shapes[4], platePalettes[0], 42, tries: 3000);
      final b = makePlate(shapes[4], platePalettes[0], 42, tries: 3000);
      final c = makePlate(shapes[4], platePalettes[0], 43, tries: 3000);
      expect([for (final d in a) d.center], [for (final d in b) d.center]);
      expect([for (final d in a) d.color], [for (final d in b) d.color]);
      expect(a.first.center, isNot(c.first.center));
    });

    test('figure and background colours are about equally light', () {
      for (final p in platePalettes) {
        double light(List<Color> colours) =>
            colours.map((c) => c.computeLuminance()).reduce((a, b) => a + b) / colours.length;
        expect((light(p.figure) - light(p.background)).abs(), lessThan(0.04), reason: p.id);
      }
    });
  });

  test('a deck takes only the chosen groups, no shape twice, palettes in turn', () {
    final deck = makeDeck(shapes, {'ge_region', 'continent'}, 12, 'mix', Random(1));
    expect(deck, hasLength(12));
    final groups = {for (final x in shapes) x.id: x.group};
    expect(deck.map((p) => groups[p.shape]).toSet(), {'ge_region', 'continent'});
    expect(deck.map((p) => p.shape).toSet(), hasLength(12));
    expect(deck.take(3).map((p) => p.palette), platePalettes.map((p) => p.id));
    expect(makeDeck(shapes, {'continent'}, 9, 'red_green', Random(1)), hasLength(4));
    final copy = PlateSpec.fromJson(deck.first.toJson());
    expect(copy, deck.first);
  });

  test('Georgia: every region and the municipalities, with Georgian names', () {
    expect(shapes.where((x) => x.group == 'ge_region'), hasLength(12));
    expect(shapes.where((x) => x.group == 'ge_municipality').length, greaterThanOrEqualTo(60));
    final names = {for (final x in shapes) x.id: x.ka};
    expect(names['ge_m_keda'], 'ქედა');
    expect(names['ge_abkhazia'], 'აფხაზეთი');
  });

  testWidgets('setup: the teacher picks groups and gets a deck', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<PlateSpec>? deck;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => deck = await Navigator.of(context).push<List<PlateSpec>>(
              MaterialPageRoute(
                builder: (_) => PlatesSetupPage(s: s, shapes: shapes),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Regions and countries are on at first; leave only continents.
    await tester.tap(find.textContaining(s['plates_group_ge_region']));
    await tester.tap(find.textContaining(s['plates_group_country']));
    await tester.pump();
    expect(find.text(s['plates_none']), findsOneWidget);
    await tester.tap(find.textContaining(s['plates_group_continent']));
    await tester.tap(find.text('6'));
    await tester.pump();
    expect(find.text(s.f('plates_only', [4])), findsOneWidget);
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(deck, hasLength(4));
  });

  Map<String, dynamic> sessionJson(Map<String, dynamic> settings, int rev) => {
    'id': 's1',
    'name': 'Plates',
    'game': 'plates',
    'status': 'open',
    'rev': rev,
    'archived': false,
    'settings': settings,
    'createdAt': 1,
    'now': 100,
  };
  final jsonHeaders = {'content-type': 'application/json'};
  final deck = [
    const PlateSpec('ge_kakheti', 'red_green', 1).toJson(),
    const PlateSpec('italy', 'pink_violet', 2).toJson(),
  ];
  String ka(String id) => shapes.firstWhere((x) => x.id == id).ka;

  testWidgets('teacher: notice first, then moves the plates for everyone and shows the answer', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var state = <String, dynamic>{'deck': deck, 'at': 0, 'revealed': false};
    final sent = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/plate')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sent.add(body);
        state = {...state, ...body};
        return http.Response(jsonEncode({'session': sessionJson(state, sent.length + 1)}), 200, headers: jsonHeaders);
      }
      return http.Response(
        jsonEncode({'changed': true, 'session': sessionJson(state, sent.length + 1), 'responses': []}),
        200,
        headers: jsonHeaders,
      );
    });
    SharedPreferences.setMockInitialValues({'lang': 'ka'});
    final appSettings = Settings();
    await tester.runAsync(appSettings.load);

    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: PlatesSessionPage(
            settings: appSettings,
            session: SessionInfo.fromJson(sessionJson({'deck': deck, 'at': 0, 'revealed': false}, 0)),
            shapes: shapes,
          ),
        ),
      );
      await settle();
    }, () => client);

    expect(find.text(s['plates_notice_1']), findsOneWidget);
    expect(find.text(s['plates_notice_teacher']), findsOneWidget);
    await tester.tap(find.text(s['plates_agree']));
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text(ka('ge_kakheti')), findsNothing);

    await tester.tap(find.text(s['plates_reveal']));
    await settle();
    expect(sent.last, {'at': 0, 'revealed': true});
    expect(find.text(ka('ge_kakheti')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle();
    expect(sent.last, {'at': 1, 'revealed': false});
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text(s['plates_question']), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await settle();
    expect(sent.last, {'at': 2, 'revealed': false});
    expect(find.text(s['plates_end_title']), findsOneWidget);

    await tester.tap(find.text(s['plates_again']));
    await settle();
    expect(sent.last, {'at': 0, 'revealed': false});
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('student: the notice, then follows the plate the teacher shows, and sends nothing', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var shown = <String, dynamic>{'plate': deck[0], 'at': 0, 'count': 2, 'revealed': false};
    final paths = <String>[];
    final api = Api(
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({'name': 'Plates', 'game': 'plates', 'status': 'open', 'settings': shown, 'now': 100}),
          200,
          headers: jsonHeaders,
        );
      }),
    );
    String? stopped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlatesPlay(
            s: s,
            lang: 'ka',
            token: 'tok',
            settings: shown,
            api: api,
            onStopped: (v) => stopped = v,
            shapes: shapes,
          ),
        ),
      ),
    );
    expect(find.text(s['plates_notice_student']), findsOneWidget);
    await tester.tap(find.text(s['plates_understood']));
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text(s['plates_question']), findsOneWidget);

    shown = {'plate': deck[0], 'at': 0, 'count': 2, 'revealed': true};
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text(ka('ge_kakheti')), findsOneWidget);

    shown = {'plate': deck[1], 'at': 1, 'count': 2, 'revealed': false};
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text(ka('ge_kakheti')), findsNothing);

    shown = {'plate': null, 'at': 2, 'count': 2, 'revealed': false};
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text(s['plates_end_title']), findsOneWidget);
    expect(paths.toSet(), {'/api/join'});
    expect(stopped, isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
