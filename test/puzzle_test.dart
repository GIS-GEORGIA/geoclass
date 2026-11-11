import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/puzzle.dart';
import 'package:geoclass/puzzle_play.dart';
import 'package:geoclass/puzzle_setup_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final units = parseGeoUnits(File('assets/ge_units.json').readAsStringSync());

  test('Georgia: 12 regions, the municipalities each in a region, Tskhinvali fixed', () {
    expect(units.regions, hasLength(12));
    expect(units.municipalities.length, greaterThanOrEqualTo(64));
    final regions = units.regions.map((r) => r.id).toSet();
    for (final m in units.municipalities) {
      expect(regions, contains(m.region), reason: m.id);
      expect(m.ka, isNotEmpty);
    }
    expect(units.municipalitiesOf('ge_guria').map((m) => m.ka), containsAll(['ოზურგეთი', 'ლანჩხუთი', 'ჩოხატაური']));
    expect(units.fixed.single.id, 'tskhinvali');
    expect(units.divisible.map((r) => r.id), isNot(contains('ge_abkhazia')));
    expect(units.divisible.map((r) => r.id), isNot(contains('ge_tbilisi')));
  });

  test('the board fits, pieces lie on it, and the same settings cut the same pieces', () {
    for (final spec in [
      const PuzzleSpec(kind: 'regions', seed: 1),
      const PuzzleSpec(kind: 'municipalities', seed: 1),
      const PuzzleSpec(kind: 'municipalities', area: 'ge_imereti', seed: 1),
      const PuzzleSpec(kind: 'grid', area: 'ge_kakheti', rows: 4, cols: 5, seed: 3),
    ]) {
      final board = buildBoard(units, spec);
      expect(board.size.longestSide, inInclusiveRange(700, 1601), reason: spec.kind);
      final area = board.rect.inflate(board.size.longestSide * 0.2);
      for (final p in board.pieces) {
        expect(area.contains(p.bounds.topLeft) && area.contains(p.bounds.bottomRight), isTrue, reason: p.id);
        expect(insideRings(p.labelAt, p.rings), isTrue, reason: p.id);
      }
      final again = buildBoard(units, spec);
      expect(again.pieces.map((p) => p.bounds), board.pieces.map((p) => p.bounds));
    }
    expect(buildBoard(units, const PuzzleSpec(kind: 'regions', seed: 1)).pieces, hasLength(12));
    // Abkhazia stays one piece among the municipalities.
    final all = buildBoard(units, const PuzzleSpec(kind: 'municipalities', seed: 1));
    expect(all.pieces.map((p) => p.id), contains('ge_abkhazia'));
    expect(all.pieces.length, units.municipalities.length + 1);
    expect(all.fixed, hasLength(1));
  });

  test('neighbours get different colours', () {
    final board = buildBoard(units, const PuzzleSpec(kind: 'regions', seed: 1));
    final imereti = board.pieces.firstWhere((p) => p.id == 'ge_imereti');
    final racha = board.pieces.firstWhere((p) => p.id == 'ge_racha_lechkhumi_and_kvemo_svaneti');
    expect(imereti.color, isNot(racha.color));
  });

  test('jigsaw pieces cover the board once, and neighbours share their knob', () {
    const size = Size(600, 400);
    final pieces = jigsaw(size, 4, 6, 9);
    expect(pieces, hasLength(24));
    final random = Random(1);
    for (var i = 0; i < 2000; i++) {
      final p = Offset(random.nextDouble() * size.width, random.nextDouble() * size.height);
      final hits = pieces.where((x) => insideRings(p, x.rings)).length;
      // A point exactly on an edge may count for none or two; those are rare.
      expect(hits, lessThanOrEqualTo(1));
    }
    var area = 0.0;
    for (final x in pieces) {
      final r = x.rings.single;
      var a = 0.0;
      for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
        a += (r[j].dx + r[i].dx) * (r[j].dy - r[i].dy);
      }
      area += a.abs() / 2;
    }
    expect(area, closeTo(size.width * size.height, 1));
    expect(pieces.first.id, 'A1');
    expect(pieces.last.id, 'D6');
  });

  test('grid size follows the board shape', () {
    expect(gridFor(const Size(1600, 800), 16), (3, 6));
    expect(gridFor(const Size(800, 800), 25), (5, 5));
    expect(gridFor(const Size(1600, 400), 64), (4, 8));
  });

  test('leaderboard: finished first by time, then by pieces placed', () {
    final tries = [
      const PuzzleTry('a', true, 0, 110),
      const PuzzleTry('a', true, 1, 130),
      const PuzzleTry('b', false, 1, 105),
      const PuzzleTry('b', true, 0, 120),
      const PuzzleTry('b', true, 1, 125),
      const PuzzleTry('c', true, 0, 140),
      const PuzzleTry('c', true, 0, 141),
    ];
    final rows = puzzleLeaderboard(tries, 2, 100);
    expect(rows.map((r) => r.participantId), ['b', 'a', 'c']);
    expect(rows.first.seconds, 25);
    expect(rows.first.mistakes, 1);
    expect(rows.last.seconds, isNull);
    final hard = hardestPieces(tries, 2);
    expect(hard.first, (piece: 1, placed: 2, mistakes: 1));
    expect(hard.last.placed, 3);
  });

  widgetTests(units);
}

const _s = S('ka');
final _json = {'content-type': 'application/json'};

void widgetTests(GeoUnits units) {
  testWidgets('setup: the teacher picks a region by municipalities and gets the settings', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PuzzleSpec? spec;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => spec = await Navigator.of(context).push<PuzzleSpec>(
              MaterialPageRoute(
                builder: (_) => PuzzleSetupPage(s: _s, lang: 'ka', units: units, loadMap: false),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(_s.f('puzzle_pieces', [12])), findsOneWidget);

    await tester.tap(find.text(_s['puzzle_kind_municipalities']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_s['puzzle_georgia']));
    await tester.pumpAndSettle();
    await tester.tap(find.text('გურია').last);
    await tester.pumpAndSettle();
    expect(find.text(_s.f('puzzle_pieces', [3])), findsOneWidget);
    await tester.tap(find.text(_s['cards_rot_quarter']));
    await tester.tap(find.text(_s['puzzle_help_frame']));
    await tester.pump();
    await tester.tap(find.text(_s['create']));
    await tester.pumpAndSettle();
    expect(spec!.toJson(), {
      ...spec!.toJson(),
      'kind': 'municipalities',
      'area': 'ge_guria',
      'rotation': 'quarter',
      'help': 'frame',
      'pieces': 3,
    });
  });

  testWidgets('student: waits for the clock, a wrong drop counts, the right one stays', (tester) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final spec = const PuzzleSpec(kind: 'municipalities', area: 'ge_guria', look: 'color', seed: 4, pieces: 3);
    var settings = <String, dynamic>{...spec.toJson()};
    final sent = <Map<String, dynamic>>[];
    final api = Api(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/submit')) {
          sent.add((jsonDecode(request.body) as Map<String, dynamic>)['answer'] as Map<String, dynamic>);
          return http.Response(jsonEncode({'ok': true, 'duplicate': false}), 201, headers: _json);
        }
        return http.Response(
          jsonEncode({'name': 'P', 'game': 'puzzle', 'status': 'open', 'settings': settings, 'now': 1000}),
          200,
          headers: _json,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PuzzlePlay(
            s: _s,
            lang: 'ka',
            token: 'tok',
            settings: settings,
            now: 1000,
            api: api,
            onStopped: (_) {},
            units: units,
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(_s['puzzle_wait_body']), findsOneWidget);

    settings = {...settings, 'endsAt': 1300, 'startedAt': 1000};
    await tester.pump(const Duration(seconds: 4));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(_s.f('puzzle_placed', [0, 3])), findsOneWidget);

    final board = buildBoard(units, spec);
    final names = {for (final p in board.pieces) p.index: p.name('ka')};
    expect(names.values, contains('ოზურგეთი'));
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is BoardPainter);
    final painter = tester.widget<CustomPaint>(paint).painter! as BoardPainter;
    final origin = tester.getTopLeft(paint);

    Future<void> drag(int pieceIndex, Offset boardPoint) async {
      final from = tester.getCenter(find.byKey(ValueKey('piece-$pieceIndex')));
      final to = origin + boardPoint * painter.scale + const Offset(0, 28);
      final g = await tester.startGesture(from);
      await g.moveBy(const Offset(0, -30));
      await tester.pump();
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    final first = board.pieces.first;
    final other = board.pieces.last;
    await drag(first.index, other.center);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(_s['puzzle_wrong']), findsOneWidget);

    await drag(first.index, first.center);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(_s.f('puzzle_placed', [1, 3])), findsOneWidget);
    expect(sent, [
      {'ok': false, 'piece': first.index},
      {'ok': true, 'piece': first.index},
    ]);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
