import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/cards.dart';
import 'package:geoclass/cards_play.dart';
import 'package:geoclass/evidence.dart';
import 'package:geoclass/evidence_play.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/queue.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Online answers: the right answer stays on the server, and the result comes in its reply to the answer.
void main() {
  const s = S('ka');

  test('the queue hands each reply to the game', () async {
    SharedPreferences.setMockInitialValues({});
    final replies = <String, Map<String, dynamic>>{};
    final queue = SubmissionQueue(
      (item) async => {'score': item['submissionId'] == 'a' ? 50 : 100},
      onReply: (item, reply) => replies[item['submissionId'] as String] = reply,
    );
    await queue.add({'submissionId': 'a'});
    await queue.add({'submissionId': 'b'});
    await queue.flush();
    expect(replies, {
      'a': {'score': 50},
      'b': {'score': 100},
    });
  });

  test('an aerial task without its point is marked as checked on the server', () {
    final online = CoordTask.fromJson({'mode': 'photo', 'format': 'dd', 'photo': 'p01.jpg'});
    expect(online.secret, isTrue);
    expect(online.label, isEmpty);
    final offline = CoordTask.fromJson({
      'lat': 41.7,
      'lon': 44.8,
      'mode': 'photo',
      'format': 'dd',
      'photo': 'p01.jpg',
      'label': 'x',
    });
    expect(offline.secret, isFalse);
    expect(offline.lat, 41.7);
  });

  group('evidence, online answers', () {
    // What the join response gives: the coordinates are on the picture, the accepted names are not.
    final task = EvidenceTask.fromJson({
      'kind': 'receipt',
      'lat': 41.6938,
      'lon': 44.8015,
      'shown': 'dms',
      'ask': 'dd',
      'questions': ['coords', 'name'],
      'converter': false,
      'seed': 7,
    });

    Future<void> play(WidgetTester tester, http.Client client) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
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
        ),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '41.69381');
      await tester.enterText(fields.at(1), '44.80152');
      await tester.enterText(find.widgetWithText(TextField, s['ev_name_hint']), 'რუსთაველი');
      await tester.ensureVisible(find.text(s['play_answer']));
      await tester.tap(find.text(s['play_answer']));
      await tester.pumpAndSettle();
    }

    testWidgets('the name is scored by the server, which also gives the right one', (tester) async {
      expect(task.names, isEmpty);
      final client = MockClient((request) async {
        final q = ((jsonDecode(request.body) as Map)['answer'] as Map)['q'];
        final reply = q == 'name'
            ? {'ok': true, 'score': 0, 'right': 'თავისუფლების მოედანი'}
            : {'ok': true, 'score': 100};
        return http.Response(jsonEncode(reply), 201, headers: {'content-type': 'application/json'});
      });
      await play(tester, client);
      expect(find.text(s.f('ev_result_total', [100, 200])), findsOneWidget);
      expect(find.textContaining('თავისუფლების მოედანი'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('without internet the name waits, and is not scored on the device', (tester) async {
      await play(tester, MockClient((_) async => throw http.ClientException('offline')));
      expect(find.text(s.f('ev_result_total', [100, 100])), findsOneWidget);
      expect(find.text(s['play_checked_later']), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('cards, online answers', () {
    // The server's hidden order: card id -> pair * 2 + side. The device never sees it.
    const order = [3, 0, 5, 1, 4, 2];
    late List<Map<String, dynamic>> sent;
    late bool offline;

    Future<void> open(WidgetTester tester) async {
      sent = [];
      offline = false;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final settings = {
        'arrow': false,
        'rotation': 'none',
        'answers': 'online',
        'session': 'sess-1',
        'cards': [
          for (var i = 0; i < 6; i++) {'id': i, 'r': 0},
        ],
        'endsAt': now + 120,
      };
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/submit')) {
          if (offline) throw http.ClientException('offline');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(body);
          final a = (body['answer'] as Map)['a'] as int, b = (body['answer'] as Map)['b'] as int;
          return http.Response(
            jsonEncode({'ok': true, 'match': order[a] ~/ 2 == order[b] ~/ 2}),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'name': 'x', 'game': 'cards', 'status': 'open', 'settings': settings, 'now': now}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final report = FlutterError.onError;
      FlutterError.onError = (_) {}; // the pictures can't load in a test
      addTearDown(() => FlutterError.onError = report);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CardsPlay(
              s: s,
              token: 'tok',
              settings: settings,
              now: now,
              api: Api(client: client),
              onStopped: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    List<CardTile> tiles(WidgetTester tester) => tester.widgetList<CardTile>(find.byType(CardTile)).toList();
    int at(WidgetTester tester, int id) => tiles(tester).indexWhere((t) => t.card.id == id);
    Future<void> tapId(WidgetTester tester, int id) async {
      await tester.tap(find.byType(CardTile).at(at(tester, id)), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('pictures come by card id, never by file name', (tester) async {
      await open(tester);
      final urls = tiles(tester).map((t) => t.card.url).toSet();
      expect(urls, {for (var i = 0; i < 6; i++) '$publicUrl/api/card-image/sess-1/$i'});
      expect(tiles(tester).every((t) => t.card.pair == -1), isTrue);
      await close(tester);
    });

    testWidgets('the server says whether two cards match', (tester) async {
      await open(tester);
      // Ids 1 and 3 are pair 0 on the server.
      await tapId(tester, 1);
      await tapId(tester, 3);
      expect(sent.single['answer'], {'a': 1, 'b': 3});
      expect(find.text(s.f('cards_found', [1, 3])), findsOneWidget);
      expect(tiles(tester).where((t) => t.found), hasLength(2));
      // Ids 0 and 2 are different pairs.
      await tapId(tester, 0);
      await tapId(tester, 2);
      expect(tiles(tester).where((t) => t.wrong), hasLength(2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(s.f('cards_found', [1, 3])), findsOneWidget);
      expect(find.text('1'), findsOneWidget); // one mistake
      await close(tester);
    });

    testWidgets('without internet a try is not counted and the student is told', (tester) async {
      await open(tester);
      offline = true;
      await tapId(tester, 1);
      await tapId(tester, 3);
      expect(find.text(s['cards_need_internet']), findsOneWidget);
      expect(tiles(tester).where((t) => t.found || t.selected), isEmpty);
      expect(find.text(s.f('cards_found', [0, 3])), findsOneWidget);
      await close(tester);
    });
  });
}
