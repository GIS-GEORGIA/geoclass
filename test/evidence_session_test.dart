import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/evidence_session_page.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The teacher's page against a pretend server: no network, no real key.
void main() {
  const s = S('ka');
  final settings = {
    'tasks': [
      {
        'kind': 'receipt',
        'lat': 41.6938,
        'lon': 44.8015,
        'shown': 'dms',
        'ask': 'dd',
        'questions': ['coords', 'name'],
        'names': ['თავისუფლების მოედანი'],
        'converter': true,
        'seed': 3,
      },
    ],
  };

  Map<String, dynamic> row(String id, String who, int round, Map<String, dynamic> answer, int score, int at, {bool accepted = false}) => {
    'id': id,
    'participantId': who,
    'round': round,
    'answer': answer,
    'lat': 41.6938,
    'lon': 44.8015,
    'distanceM': answer['q'] == 'name' ? null : 12.0,
    'score': score,
    'hidden': false,
    'accepted': accepted,
    'createdAt': at,
  };

  Future<List<(String, Map<String, dynamic>)>> open(WidgetTester tester) async {
    final patches = <(String, Map<String, dynamic>)>[];
    var accepted = false;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add((request.url.pathSegments.last, body));
        accepted = body['accepted'] as bool;
        return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
      }
      return http.Response(
        jsonEncode({
          'changed': true,
          'session': {
            'id': 's1',
            'name': 'Detective',
            'game': 'evidence',
            'status': 'open',
            'rev': patches.length + 1,
            'archived': false,
            'settings': settings,
            'createdAt': 1,
            'now': 100,
          },
          'responses': [
            row('a1', 'student-one', 0, {'q': 'coords', 'raw': '41.6938 N, 44.8015 E', 'format': 'dd'}, 100, 10),
            row('a2', 'student-one', 2, {'q': 'name', 'name': 'თავისუფლების მოედანი'}, 100, 11),
            row('b1', 'student-two', 0, {'q': 'coords', 'raw': '41.6938 N, 44.8015 E', 'format': 'dd'}, 100, 12),
            row('b2', 'student-two', 2, {'q': 'name', 'name': 'თავისუფლების მოედნი'}, 0, 13, accepted: accepted),
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    tester.view.physicalSize = const Size(375, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'lang': 'ka'});
    final appSettings = Settings();
    await tester.runAsync(appSettings.load);

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: EvidenceSessionPage(
          settings: appSettings,
          session: SessionInfo.fromJson({
            'id': 's1',
            'name': 'Detective',
            'game': 'evidence',
            'status': 'open',
            'rev': 0,
            'createdAt': 1,
            'archived': false,
            'settings': settings,
          }),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }, () => client);
    return patches;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  List<String?> scores(WidgetTester tester) =>
      tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.trailing as Text).data).toList();

  testWidgets('accepting a slip as right lifts the student on the leaderboard, and undo takes it back', (tester) async {
    final patches = await open(tester);
    expect(scores(tester), ['200 / 200', '100 / 200']);

    await tester.tap(find.text(s['ev_review']));
    await tester.pump();
    expect(find.text('თავისუფლების მოედნი'), findsOneWidget);
    // Only the wrong answer offers it.
    expect(find.text(s['ev_accept']), findsOneWidget);
    await tester.tap(find.text(s['ev_accept']));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(patches.single.$1, 'b2');
    expect(patches.single.$2, {'accepted': true});
    expect(find.text(s.f('ev_accepted_note', [0])), findsOneWidget);

    await tester.tap(find.text(s['ev_unaccept']));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(patches.last.$2, {'accepted': false});
    expect(find.text(s['ev_accept']), findsOneWidget);

    await tester.tap(find.text(s['leaderboard']));
    await tester.pump();
    expect(scores(tester), ['200 / 200', '100 / 200']);
    await close(tester);
  });
}
