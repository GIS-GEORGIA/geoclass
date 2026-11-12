import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
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
}
