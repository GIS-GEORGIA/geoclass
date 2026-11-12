import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/nickname_dialog.dart';
import 'package:geoclass/nicknames.dart';
import 'package:geoclass/queue.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Students get a new random id in every session, may pick a made-up name, and can start over afresh.
void main() {
  group('participant id', () {
    test('each session gets its own, so sessions can’t be linked', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await participantId('token-a');
      final b = await participantId('token-b');
      expect(a, isNot(b));
      expect(await participantId('token-a'), a);
    });

    test('a session this device was already playing keeps the old shared id', () async {
      SharedPreferences.setMockInitialValues({
        'participant_id': 'old-shared-id-01',
        'join_token-a': '{}', // the session was opened before
        'cards_token-a': '{}',
      });
      expect(await participantId('token-a'), 'old-shared-id-01');
      expect(await participantId('token-new'), isNot('old-shared-id-01'));
    });

    test('starting over removes it, its nickname and progress; the next id is new', () async {
      SharedPreferences.setMockInitialValues({'participant_id': 'old-shared-id-01', 'join_token-a': '{}'});
      final before = await participantId('token-a');
      final p = await SharedPreferences.getInstance();
      await p.setString('nick_token-a', 'Blue Fox');
      await p.setString('nick_token-b', 'Other');
      await forgetSessionOnDevice('token-a');
      expect(p.getString('nick_token-a'), isNull);
      expect(p.getString('nick_token-b'), 'Other');
      final after = await participantId('token-a');
      expect(after, isNot(before));
    });
  });

  group('nicknames', () {
    test('a picked one is shown instead of the automatic one, until the server says none', () {
      final automatic = nickname('pid-nick-0001', 'en');
      rememberNicknames({'pid-nick-0001': 'Tbilisi Fox'});
      expect(nickname('pid-nick-0001', 'en'), 'Tbilisi Fox');
      rememberNicknames(const {}, forIds: ['pid-nick-0001']);
      expect(nickname('pid-nick-0001', 'en'), automatic);
    });

    test('the same rule as the server', () {
      expect(cleanNickname('  მწვანე   მელა '), 'მწვანე მელა');
      expect(cleanNickname('Fox_9-b'), 'Fox_9-b');
      expect(cleanNickname(''), '');
      expect(cleanNickname('x' * 21), isNull);
      expect(cleanNickname('<b>hi</b>'), isNull);
      expect(cleanNickname('-dash'), isNull);
    });

    test('suggestions are different made-up names in the right language', () {
      final ka = suggestedNicknames('ka', random: Random(1));
      expect(ka.toSet(), hasLength(6));
      expect(ka.every((n) => cleanNickname(n) == n), isTrue);
      expect(suggestedNicknames('en', random: Random(1)).first, matches(RegExp(r'^[A-Z][a-z]+ [A-Z][a-z]+$')));
    });

    test('the teacher’s polling learns the picked nicknames of the session', () async {
      final api = Api(
        teacherKey: 'k',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'changed': true,
              'session': {
                'id': 's1',
                'name': 'A',
                'game': 'travel',
                'status': 'open',
                'rev': 1,
                'createdAt': 0,
                'archived': false,
              },
              'responses': [
                {'participantId': 'pid-poll-0001'},
                {'participantId': 'pid-poll-0002'},
              ],
              'nicknames': {'pid-poll-0001': 'Kazbegi Owl'},
            }),
            200,
          ),
        ),
      );
      rememberNicknames({'pid-poll-0002': 'stale'});
      await api.poll('s1', null);
      expect(nickname('pid-poll-0001', 'en'), 'Kazbegi Owl');
      expect(nickname('pid-poll-0002', 'en'), isNot('stale'));
    });
  });

  group('nickname dialog', () {
    Future<String?> open(WidgetTester tester, Future<void> Function() act) async {
      String? result = 'not closed';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<String>(
                context: context,
                builder: (_) => const NicknameDialog(s: S('en'), lang: 'en', current: 'Blue Fox'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('warns not to use a real name, and saves a typed one', (tester) async {
      final result = await open(tester, () async {
        expect(find.text(const S('en')['nick_warning']), findsOneWidget);
        expect(find.text('Now: Blue Fox'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Rioni Otter');
        await tester.tap(find.text(const S('en')['nick_save']));
      });
      expect(result, 'Rioni Otter');
    });

    testWidgets('refuses a bad one and stays open', (tester) async {
      final result = await open(tester, () async {
        await tester.enterText(find.byType(TextField), '<script>');
        await tester.tap(find.text(const S('en')['nick_save']));
        await tester.pump();
        expect(find.text(const S('en')['nick_bad']), findsOneWidget);
      });
      expect(result, 'not closed');
    });

    testWidgets('a suggestion is picked with one tap; automatic goes back to none', (tester) async {
      final picked = await open(tester, () async => tester.tap(find.byType(ActionChip).first));
      expect(cleanNickname(picked!), picked);
      final none = await open(tester, () async => tester.tap(find.text(const S('en')['nick_auto'])));
      expect(none, '');
    });
  });
}
