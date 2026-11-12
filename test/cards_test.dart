import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/cards.dart';
import 'package:geoclass/cards_play.dart';
import 'package:geoclass/l10n.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

CardTry _ok(String who, int pair, int at) => CardTry(participantId: who, ok: true, pair: pair, createdAt: at);
CardTry _no(String who, int x, int y, int at) => CardTry(participantId: who, ok: false, x: x, y: y, createdAt: at);

void main() {
  group('the list of pairs', () {
    test('reads good entries and names the ones left out', () {
      final pairs = parseCardPairs(jsonEncode([
        {'a': 'tbilisi-1.jpg', 'b': 'tbilisi-2.jpg', 'ka': 'თბილისი', 'en': 'Tbilisi', 'level': 2},
        {'a': 'batumi-1.png', 'b': 'batumi-2.webp', 'ka': 'ბათუმი'},
        {'a': '../x.jpg', 'b': 'y.jpg', 'ka': 'path'},
        {'a': 'same.jpg', 'b': 'same.jpg', 'ka': 'same file twice'},
        {'a': 'a.gif', 'b': 'b.jpg', 'ka': 'not a picture'},
        {'a': 'c.jpg', 'b': 'd.jpg', 'ka': ''},
        {'a': 'e.jpg', 'ka': 'no second picture'},
        'not an object',
      ]));
      expect(pairs.map((p) => p.ka), ['თბილისი', 'ბათუმი']);
      expect(pairs[0].level, 2);
      expect(pairs[1].level, 1);
      expect(pairs[1].en, '');
    });

    // Fails with a clear message when a pair is added with a mistake.
    test('every entry in web/cards/index.json is valid and both files exist', () {
      final raw = File('web/cards/index.json').readAsStringSync();
      expect(parseCardPairs(raw).length, (jsonDecode(raw) as List).length, reason: 'an entry has a mistake');
      final used = <String>{};
      for (final p in parseCardPairs(raw)) {
        for (final f in [p.a, p.b]) {
          expect(File('web/cards/$f').existsSync(), isTrue, reason: '$f is listed but missing');
          expect(used.add(f), isTrue, reason: '$f is used by two pairs');
        }
      }
    });

    test('an out-of-range level falls back to 1', () {
      final pairs = parseCardPairs(jsonEncode([
        {'a': 'a.jpg', 'b': 'b.jpg', 'ka': 'x', 'level': 9},
      ]));
      expect(pairs.single.level, 1);
    });
  });

  group('turning cards', () {
    test('no rotation leaves both north up', () {
      expect(pickAngles('none', Random(1)), (0, 0));
    });

    test('quarter turns are right angles and the two cards differ', () {
      for (var seed = 0; seed < 50; seed++) {
        final (a, b) = pickAngles('quarter', Random(seed));
        expect(a % 90, 0);
        expect(b % 90, 0);
        expect(a, isNot(b));
      }
    });

    test('any angle keeps the two cards at least a quarter turn apart', () {
      for (var seed = 0; seed < 50; seed++) {
        final (a, b) = pickAngles('any', Random(seed));
        expect(a, inInclusiveRange(0, 359));
        expect(b, inInclusiveRange(0, 359));
        final apart = (a - b).abs();
        expect(apart > 89 && apart < 271, isTrue, reason: '$a vs $b');
      }
    });

    test('the arrow shows only when asked for and only on turned cards', () {
      const pair = DeckPair(a: 'a.jpg', b: 'b.jpg', label: '', labelEn: '', ra: 0, rb: 90);
      expect(const Deck(pairs: [pair], arrow: true, rotation: 'quarter').showsArrow, isTrue);
      expect(const Deck(pairs: [pair], arrow: false, rotation: 'quarter').showsArrow, isFalse);
      expect(const Deck(pairs: [pair], arrow: true, rotation: 'none').showsArrow, isFalse);
    });

    test('a deck survives the trip to the server and back', () {
      const deck = Deck(
        pairs: [DeckPair(a: 'a.jpg', b: 'b.jpg', label: 'ა', labelEn: 'A', ra: 10, rb: 200)],
        arrow: true,
        rotation: 'any',
      );
      final back = Deck.fromSettings(jsonDecode(jsonEncode(deck.toJson())) as Map<String, dynamic>);
      expect(back.pairs.single.rb, 200);
      expect(back.pairs.single.labelFor('en'), 'A');
      expect(back.pairs.single.labelFor('ka'), 'ა');
      expect(back.arrow, isTrue);
      expect(back.rotation, 'any');
    });

    test('dealing gives every card once', () {
      const deck = Deck(
        pairs: [
          DeckPair(a: 'a1.jpg', b: 'a2.jpg', label: '', labelEn: '', ra: 0, rb: 0),
          DeckPair(a: 'b1.jpg', b: 'b2.jpg', label: '', labelEn: '', ra: 0, rb: 0),
        ],
        arrow: false,
        rotation: 'none',
      );
      final cards = dealCards(deck, Random(3));
      expect(cards.map((c) => c.file).toSet(), {'a1.jpg', 'a2.jpg', 'b1.jpg', 'b2.jpg'});
      expect(cards.where((c) => c.pair == 0), hasLength(2));
    });
  });

  group('the leaderboard', () {
    test('most pairs first, then fewer wrong tries, then whoever was sooner', () {
      final rows = cardsLeaderboard([
        _ok('slow', 0, 50), _ok('slow', 1, 60),
        _ok('fast', 0, 10), _ok('fast', 1, 20),
        _ok('sloppy', 0, 5), _ok('sloppy', 1, 6), _no('sloppy', 0, 1, 7),
        _ok('best', 0, 30), _ok('best', 1, 31), _ok('best', 2, 32),
        _no('only-wrong', 0, 1, 40),
      ]);
      expect(rows.map((r) => r.participantId), ['best', 'fast', 'slow', 'sloppy', 'only-wrong']);
      expect(rows.first.found, 3);
      expect(rows[3].mistakes, 1);
      expect(rows.last.found, 0);
    });
  });

  test('pair statistics count who found a pair and how often it was mixed up', () {
    final stats = pairStats([_ok('a', 0, 1), _ok('b', 0, 2), _ok('b', 2, 3), _no('a', 1, 2, 4), _no('b', 1, 0, 5)], 3);
    expect(stats.found, [2, 0, 1]);
    expect(stats.confused, [1, 2, 1]);
  });

  group('the compass reading', () {
    test('the first reading is taken as it is', () {
      expect(smoothHeading(null, 123), 123);
    });

    test('moves part of the way, around the short side of the circle', () {
      expect(smoothHeading(100, 200), closeTo(130, 0.001));
      expect(smoothHeading(350, 10), closeTo(356, 0.001));
      expect(smoothHeading(10, 350), closeTo(4, 0.001));
    });
  });

  group('the student game', () {
    const s = S('ka');
    final deckJson = {
      'pairs': [
        for (final i in [0, 1, 2]) {'a': 'p$i-1.jpg', 'b': 'p$i-2.jpg', 'label': 'p$i', 'ra': 0, 'rb': 90},
      ],
      'arrow': true,
      'rotation': 'quarter',
    };

    late List<Map<String, dynamic>> sent;
    late void Function() restoreErrors;

    Future<void> open(WidgetTester tester, {int? endsIn, bool refuse = false}) async {
      sent = [];
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final settings = {...deckJson, 'endsAt': ?(endsIn == null ? null : now + endsIn)};
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/submit')) {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'error': 'time_up'}), refuse ? 409 : 201);
        }
        return http.Response(
          jsonEncode({'name': 'x', 'game': 'cards', 'status': 'open', 'settings': settings, 'now': now}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final report = FlutterError.onError;
      restoreErrors = () => FlutterError.onError = report;
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'lang': 'ka'});

      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CardsPlay(
              s: s,
              token: 'tok',
              settings: settings,
              now: now,
              api: Api(),
              onStopped: (_) {},
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }, () => client);
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      restoreErrors();
    }

    List<CardTile> tiles(WidgetTester tester) => tester.widgetList<CardTile>(find.byType(CardTile)).toList();

    Future<void> tapCard(WidgetTester tester, int position) async {
      await tester.tap(find.byType(CardTile).at(position), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('waits for the teacher and shows no cards', (tester) async {
      await open(tester);
      expect(find.text(s['mapping_wait']), findsOneWidget);
      expect(find.byType(CardTile), findsNothing);
      await close(tester);
    });

    testWidgets('lays out two cards for each pair with a north arrow on each', (tester) async {
      await open(tester, endsIn: 120);
      expect(tiles(tester), hasLength(6));
      expect(find.byType(NorthArrow), findsNWidgets(6));
      expect(find.text(s.f('cards_found', [0, 3])), findsOneWidget);
      expect(find.text(CardsCredit.data), findsOneWidget);
      expect(find.text(CardsCredit.maps), findsOneWidget);
      await close(tester);
    });

    testWidgets('a matching pair is kept and sent once', (tester) async {
      await open(tester, endsIn: 120);
      final all = tiles(tester);
      final first = all.indexWhere((t) => t.card.pair == 1);
      final second = all.lastIndexWhere((t) => t.card.pair == 1);
      await tapCard(tester, first);
      await tapCard(tester, second);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(s.f('cards_found', [1, 3])), findsOneWidget);
      // Offline the device sends the two cards, pair * 2 + side, and the server checks them again.
      expect({(sent.single['answer'] as Map)['a'], (sent.single['answer'] as Map)['b']}, {2, 3});
      expect(sent.single['participantId'], isNotEmpty);
      expect(tiles(tester).where((t) => t.found), hasLength(2));
      await close(tester);
    });

    testWidgets('a wrong try counts, shows red for a moment and names both pairs', (tester) async {
      await open(tester, endsIn: 120);
      final all = tiles(tester);
      final first = all.indexWhere((t) => t.card.pair == 0);
      final second = all.indexWhere((t) => t.card.pair == 2);
      await tapCard(tester, first);
      await tapCard(tester, second);

      expect(tiles(tester).where((t) => t.wrong), hasLength(2));
      // Taps during the red moment are ignored.
      await tapCard(tester, all.indexWhere((t) => t.card.pair == 1));
      expect(tiles(tester).where((t) => t.selected), isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(tiles(tester).where((t) => t.wrong), isEmpty);

      expect(sent.single['answer'], {'a': all[first].card.id, 'b': all[second].card.id});
      expect([all[first].card.id ~/ 2, all[second].card.id ~/ 2], [0, 2]);
      expect(find.text('1'), findsOneWidget);
      await close(tester);
    });

    testWidgets('finding every pair says so', (tester) async {
      await open(tester, endsIn: 120);
      for (final pair in [0, 1, 2]) {
        final all = tiles(tester);
        await tapCard(tester, all.indexWhere((t) => t.card.pair == pair));
        await tapCard(tester, all.lastIndexWhere((t) => t.card.pair == pair));
      }
      expect(find.text(s['cards_all_found']), findsOneWidget);
      expect(sent.map((x) => {(x['answer'] as Map)['a'] ~/ 2, (x['answer'] as Map)['b'] ~/ 2}), [{0}, {1}, {2}]);
      await close(tester);
    });

    testWidgets('a try the server refuses is not sent again', (tester) async {
      await open(tester, endsIn: 120, refuse: true);
      final all = tiles(tester);
      await tapCard(tester, all.indexWhere((t) => t.card.pair == 0));
      await tapCard(tester, all.lastIndexWhere((t) => t.card.pair == 0));
      await tester.pump(const Duration(seconds: 12));
      expect(sent, hasLength(1));
      await close(tester);
    });

    testWidgets('after the time is up the cards stay but cannot be played', (tester) async {
      await open(tester, endsIn: -30);
      expect(tiles(tester), hasLength(6));
      expect(find.text(s['mapping_time_up']), findsOneWidget);
      final all = tiles(tester);
      await tapCard(tester, all.indexWhere((t) => t.card.pair == 0));
      await tapCard(tester, all.lastIndexWhere((t) => t.card.pair == 0));
      expect(sent, isEmpty);
      await close(tester);
    });
  });
}
