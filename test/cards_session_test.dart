import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/cards_session_page.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The teacher's page against a pretend server: no network, no real key.
void main() {
  const s = S('ka');
  final deck = {
    'pairs': [
      for (final i in [0, 1, 2]) {'a': 'p$i-1.jpg', 'b': 'p$i-2.jpg', 'label': 'ადგილი $i', 'ra': 0, 'rb': 0},
    ],
    'arrow': false,
    'rotation': 'none',
  };

  Map<String, dynamic> row(String id, String who, Map<String, dynamic> answer, int at) =>
      {'id': id, 'participantId': who, 'hidden': false, 'createdAt': at, 'answer': answer};

  Future<List<Map<String, dynamic>>> open(WidgetTester tester, {Map<String, dynamic> extra = const {}}) async {
    final timerCalls = <Map<String, dynamic>>[];
    var current = {...deck, ...extra};
    final client = MockClient((request) async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (request.url.path.endsWith('/timer')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        timerCalls.add(body);
        current = {...current, 'endsAt': now + (body['seconds'] as int)};
      }
      return http.Response(
        jsonEncode({
          'changed': true,
          'session': {
            'id': 's1',
            'name': 'Cards',
            'game': 'cards',
            'status': 'open',
            'rev': timerCalls.length + 1,
            'archived': false,
            'settings': current,
            'createdAt': 1,
            'now': now,
          },
          'responses': [
            row('a1', 'student-one', {'ok': true, 'pair': 0}, 10),
            row('a2', 'student-one', {'ok': true, 'pair': 1}, 20),
            row('a3', 'student-one', {'ok': false, 'x': 0, 'y': 2}, 25),
            row('b1', 'student-two', {'ok': true, 'pair': 0}, 12),
            row('b2', 'student-two', {'ok': false, 'x': 1, 'y': 2}, 14),
            row('b3', 'student-two', {'ok': false, 'x': 1, 'y': 0}, 15),
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'lang': 'ka'});
    final appSettings = Settings();
    await tester.runAsync(appSettings.load);

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: CardsSessionPage(
          settings: appSettings,
          session: SessionInfo.fromJson({
            'id': 's1',
            'name': 'Cards',
            'game': 'cards',
            'status': 'open',
            'rev': 0,
            'createdAt': 1,
            'archived': false,
            'settings': current,
          }),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }, () => client);
    return timerCalls;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('choosing the time and starting sends only the seconds', (tester) async {
    final calls = await open(tester);
    expect(find.text(s.f('mapping_minutes', [3])), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.text(s['mapping_start']));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls.single, {'seconds': 240});
    // The clock replaces the start button.
    expect(find.text(s['mapping_start']), findsNothing);
    expect(find.text(s['mapping_more']), findsOneWidget);
    await close(tester);
  });

  testWidgets('a running clock adds a minute and stops', (tester) async {
    final endsAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90;
    final calls = await open(tester, extra: {'endsAt': endsAt});
    await tester.tap(find.text(s['mapping_more']));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls.last['seconds'], inInclusiveRange(145, 150));
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls.last['seconds'], 0);
    await close(tester);
  });

  testWidgets('the leaderboard ranks by pairs, then wrong tries', (tester) async {
    await open(tester);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles, hasLength(2));
    expect((tiles[0].trailing as Text).data, '2 / 3');
    expect((tiles[1].trailing as Text).data, '1 / 3');
    expect((tiles[0].subtitle as Text).data, s.f('cards_mistakes', [1]));
    expect((tiles[1].subtitle as Text).data, s.f('cards_mistakes', [2]));
    await close(tester);
  });

  testWidgets('the pairs list says who found each pair and how often it was mixed up', (tester) async {
    await open(tester);
    await tester.tap(find.text(s['cards_pairs']));
    await tester.pump();
    final stats = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => (t.subtitle as Text).data).toList();
    expect(stats, [
      s.f('cards_pair_stats', [2, 2, 2]),
      s.f('cards_pair_stats', [1, 2, 2]),
      s.f('cards_pair_stats', [0, 2, 2]),
    ]);
    expect(find.text('ადგილი 1'), findsOneWidget);
    await close(tester);
  });

  testWidgets('has no map, and no GeoJSON export', (tester) async {
    await open(tester);
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(s['export_csv']), findsOneWidget);
    expect(find.text(s['export_geojson']), findsNothing);
    await close(tester);
  });
}
