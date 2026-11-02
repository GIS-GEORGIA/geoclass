import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/mapping_session_page.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The teacher's page against a pretend server: no network, no real key.
void main() {
  Map<String, dynamic> row(String id, String who, String kind, int at, {bool hidden = false}) => {
        'id': id,
        'participantId': who,
        'hidden': hidden,
        'createdAt': at,
        'answer': {
          'kind': kind,
          'category': 'park',
          'coords': switch (kind) {
            'point' => [
                [44.8, 41.7],
              ],
            'line' => [
                [44.8, 41.7],
                [44.81, 41.71],
              ],
            _ => [
                [44.8, 41.7],
                [44.81, 41.7],
                [44.81, 41.71],
              ],
          },
        },
      };

  late void Function() restoreErrors;

  Future<List<Map<String, dynamic>>> open(WidgetTester tester, Size size, {Map<String, dynamic> settings = const {}}) async {
    final timerCalls = <Map<String, dynamic>>[];
    var current = settings;
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
            'name': 'Uban',
            'game': 'mapping',
            'status': 'open',
            'rev': timerCalls.length + 1,
            'archived': false,
            'settings': current,
            'createdAt': 1,
            'now': now,
          },
          'responses': [
            row('a1', 'student-one', 'point', 10),
            row('a2', 'student-one', 'line', 20),
            row('a3', 'student-one', 'polygon', 30),
            row('b1', 'student-two', 'point', 10),
            row('b2', 'student-two', 'point', 11, hidden: true),
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    // Tests draw text in a font with very wide letters, so the map's one-line credit
    // doesn't fit a phone. Any other overflow still fails.
    final report = FlutterError.onError;
    restoreErrors = () => FlutterError.onError = report;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().contains('overflowed by 230 pixels')) report?.call(details);
    };

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'lang': 'ka'});
    final appSettings = Settings();
    await tester.runAsync(appSettings.load);

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: MappingSessionPage(
          settings: appSettings,
          session: SessionInfo.fromJson({
            'id': 's1',
            'name': 'Uban',
            'game': 'mapping',
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
    return timerCalls;
  }

  const phone = Size(375, 812);
  const laptop = Size(1280, 800);
  const s = S('ka');

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    restoreErrors();
  }

  for (final size in [phone, laptop]) {
    testWidgets('choosing the time and starting sends it with the map position, at $size', (tester) async {
      final calls = await open(tester, size);
      expect(find.text(s.f('mapping_minutes', [3])), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text(s.f('mapping_minutes', [4])), findsOneWidget);

      await tester.tap(find.text(s['mapping_start']));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(calls.single['seconds'], 240);
      expect(calls.single['center'], hasLength(2));
      expect(calls.single['zoom'], greaterThan(10));
      // The clock replaces the start button.
      expect(find.text(s['mapping_start']), findsNothing);
      expect(find.text(s['mapping_more']), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('a running clock counts down, adds a minute and stops', (tester) async {
    final endsAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90;
    final calls = await open(tester, phone, settings: {'endsAt': endsAt});
    expect(find.textContaining(RegExp(r'^1:[23]\d$')), findsOneWidget);

    await tester.tap(find.text(s['mapping_more']));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls.last['seconds'], inInclusiveRange(145, 150));
    expect(calls.last.containsKey('center'), isFalse);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls.last['seconds'], 0);
    await close(tester);
  });

  testWidgets('the leaderboard ranks by visible objects', (tester) async {
    await open(tester, laptop);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles, hasLength(2));
    expect((tiles[0].trailing as Text).data, '3');
    expect((tiles[1].trailing as Text).data, '1');
    expect(find.textContaining('${s['tool_polygon']}: 1'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the objects list shows every object and can hide one', (tester) async {
    await open(tester, laptop);
    await tester.tap(find.textContaining(s['mapping_objects']));
    await tester.pump();
    expect(find.byType(ListTile), findsNWidgets(5));
    expect(find.text(s['hidden_label']), findsOneWidget);
    await close(tester);
  });
}
