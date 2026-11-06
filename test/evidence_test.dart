import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/converter.dart';
import 'package:geoclass/coords.dart';
import 'package:geoclass/evidence.dart';
import 'package:geoclass/evidence_play.dart';
import 'package:geoclass/evidence_setup_page.dart';
import 'package:geoclass/export.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/places.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const s = S('ka');
  const square = EvidenceTask(
    kind: 'receipt',
    lat: 41.6938,
    lon: 44.8015,
    shown: 'dms',
    ask: 'dd',
    questions: ['coords', 'map', 'name'],
    names: ['თავისუფლების მოედანი', 'Freedom Square'],
    converter: true,
    seed: 7,
  );

  group('scoring', () {
    test('typed coordinates are scored strictly, like the server', () {
      expect(strictScoreFor(0), 100);
      expect(strictScoreFor(30), 100);
      expect(strictScoreFor(1000), 31); // worker/test: about 1 km off gives 31
      expect(strictScoreFor(4999), inInclusiveRange(0, 1));
      expect(strictScoreFor(5000), 0);
      expect(strictScoreFor(300), lessThan(strictScoreFor(100)));
    });

    test('names ignore case, spaces and punctuation', () {
      expect(nameMatches(square, '  თავისუფლების  მოედანი! '), isTrue);
      expect(nameMatches(square, 'freedom-square'), isTrue);
      expect(nameMatches(square, 'Freedom Sqare'), isFalse);
      expect(nameMatches(square, '...'), isFalse);
    });

    test('an accepted answer counts as 100 on the leaderboard', () {
      EvidenceAnswer a(String who, int round, int score, int at, {bool accepted = false, bool hidden = false}) => EvidenceAnswer(
        id: '$who$round',
        participantId: who,
        question: evidenceQuestions[round % 3],
        round: round,
        score: score,
        createdAt: at,
        lat: 0,
        lon: 0,
        accepted: accepted,
        hidden: hidden,
      );
      final rows = evidenceLeaderboard([
        a('one', 0, 100, 10),
        a('one', 2, 0, 11),
        a('two', 0, 90, 12),
        a('two', 2, 0, 13, accepted: true),
        a('three', 0, 100, 5),
        a('three', 1, 100, 6, hidden: true),
      ]);
      expect([for (final r in rows) (r.participantId, r.points)], [('two', 190), ('three', 100), ('one', 100)]);
    });
  });

  group('coordinates', () {
    test('one value reads as DD, DM or DMS', () {
      expect(parseOne('41.6938'), closeTo(41.6938, 1e-9));
      expect(parseOne('41,6938'), closeTo(41.6938, 1e-9));
      expect(parseOne('41 41.628'), closeTo(41.6938, 1e-6));
      expect(parseOne('41°41′37.7″ N'), closeTo(41.69381, 1e-5));
      expect(parseOne('44 48 05 W'), closeTo(-44.80139, 1e-5));
      expect(parseOne('-41.5'), -41.5);
      expect(parseOne('41 61'), isNull);
      expect(parseOne('41.5 20'), isNull);
      expect(parseOne(''), isNull);
    });

    test('pictures write each format so it reads back to the same place', () {
      for (final f in evidenceFormats) {
        final text = pictureCoords(f, square.lat, square.lon);
        final numbers = [for (final m in RegExp(r'\d+').allMatches(text)) int.parse(m.group(0)!)];
        final point = f == 'utm' ? fromUtm(numbers[0], numbers[1].toDouble(), numbers[2].toDouble()) : parseAny(text);
        expect(point, isNotNull, reason: text);
        expect(distanceM(point!.latitude, point.longitude, square.lat, square.lon), lessThan(30), reason: text);
      }
      expect(pictureCoords('dd', square.lat, square.lon), '41.69380° N, 44.80150° E');
      expect(pictureCoords('utm', square.lat, square.lon), startsWith('UTM 38N  E '));
    });
  });

  test('tasks keep every field through JSON', () {
    final back = EvidenceTask.fromJson(jsonDecode(jsonEncode(square.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), square.toJson());
  });

  test('the same seed always draws the same details', () {
    final a = PictureDetails.fromSeed(42), b = PictureDetails.fromSeed(42);
    expect(a.date, b.date);
    expect(a.number, b.number);
    expect(a.speed, greaterThan(a.limit));
  });

  test('random tasks name real Georgian places and ask in another format', () {
    final index = PlaceIndex([
      const Place('Kutaisi', 'ქუთაისი', 'GE', 42.27, 42.7),
      const Place('Batumi', 'ბათუმი', 'GE', 41.64, 41.63),
      const Place('Paris', '', 'FR', 48.85, 2.35),
    ], const {});
    final tasks = randomEvidenceTasks(index, 5, random: Random(1));
    expect(tasks, hasLength(2));
    for (final t in tasks) {
      expect(t.ask, isNot(t.shown));
      expect(t.names, hasLength(2));
      expect(t.questions, evidenceQuestions);
    }
  });

  test('the CSV says what counts after the teacher accepts an answer', () {
    final csv = evidenceToCsv([
      const EvidenceAnswer(id: 'x', participantId: 'p1', question: 'name', name: '=SUM(1)', round: 2, score: 0, createdAt: 1, lat: 0, lon: 0, accepted: true),
    ], [square], 'ka');
    final line = csv.split('\r\n')[1];
    expect(line, contains(",name,receipt,dms,dd,\"'=SUM(1)\",,,,0,true,100,"));
  });

  // The test font is wider than the real one, so pages with a map's credit line get a wider window.
  Future<void> phone(WidgetTester tester, {double width = 375, double height = 812}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('both pictures fit a phone and show the coordinates', (tester) async {
    await phone(tester);
    for (final kind in evidenceKinds) {
      final task = EvidenceTask.fromJson({...square.toJson(), 'kind': kind, 'shown': 'dm'});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: EvidencePicture(s: s, task: task)))));
      expect(find.text(pictureCoords('dm', square.lat, square.lon)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(EvidencePicture));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    }
    expect(find.text(s['ev_sample_banner']), findsOneWidget);
  });

  testWidgets('the converter shows every format and goes back from UTM', (tester) async {
    await phone(tester);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: CoordConverter(s: s)))));
    await tester.enterText(find.byType(TextField).at(0), '41 41 38');
    await tester.enterText(find.byType(TextField).at(1), '44.8015');
    await tester.pump();
    expect(find.text(formatDms(41.69389, 44.8015)), findsOneWidget);
    expect(find.text('UTM 37N'), findsOneWidget);
    final utm38 = toUtm(41.693889, 44.8015, zone: 38);

    await tester.tap(find.text('UTM → DD'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), '${utm38.easting.round()}');
    await tester.enterText(find.byType(TextField).at(1), '${utm38.northing.round()}');
    await tester.pump();
    expect(find.text(formatDd(41.69389, 44.80150)), findsOneWidget);
  });

  testWidgets('the editor needs a place and an accepted name', (tester) async {
    await phone(tester, width: 900, height: 3000);
    EvidenceTask? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await Navigator.of(context).push<EvidenceTask>(
            MaterialPageRoute(builder: (_) => const EvidenceTaskEditor(s: s)),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    bool canSave() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, s['ev_save'])).onPressed != null;
    expect(canSave(), isFalse);
    await tester.enterText(find.byType(TextField).first, '41.6938, 44.8015');
    await tester.pump();
    expect(canSave(), isFalse); // the name question is on, with no accepted name
    final names = find.widgetWithText(TextField, s['ev_names']);
    await tester.enterText(names, 'თავისუფლების მოედანი\n\nFreedom Square');
    await tester.pump();
    expect(canSave(), isTrue);
    await tester.tap(find.text(s['ev_save']));
    await tester.pumpAndSettle();
    expect(saved!.names, ['თავისუფლების მოედანი', 'Freedom Square']);
    expect(saved!.questions, evidenceQuestions);
    expect(saved!.lat, 41.6938);
  });

  testWidgets('a student answers the coordinates and the name, then sees the result', (tester) async {
    await phone(tester, width: 900, height: 3000);
    SharedPreferences.setMockInitialValues({});
    final sent = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      sent.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{"ok":true}', 201, headers: {'content-type': 'application/json'});
    });
    final task = EvidenceTask.fromJson({...square.toJson(), 'questions': ['coords', 'name'], 'converter': false});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EvidencePlay(
          s: s,
          lang: 'ka',
          token: 'tok',
          tasks: [task],
          resetAt: 0,
          api: Api(client: client),
          onStopped: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(s['ev_converter']), findsNothing);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '41.69381');
    await tester.enterText(fields.at(1), '44.80152');
    final name = find.widgetWithText(TextField, s['ev_name_hint']);
    await tester.enterText(name, 'freedom square');
    await tester.ensureVisible(find.text(s['play_answer']));
    await tester.tap(find.text(s['play_answer']));
    await tester.pumpAndSettle();

    expect(sent.map((b) => (b['answer'] as Map)['q']), ['coords', 'name']);
    expect(sent.first['round'], 0);
    expect((sent.first['lat'] as num).toDouble(), closeTo(41.69381, 1e-6));
    expect(find.text(s.f('ev_result_total', [200, 200])), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // the result map fits itself just after it opens
  });
}
