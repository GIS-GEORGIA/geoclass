import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/cards_session_page.dart';
import 'package:geoclass/coordinates_play.dart';
import 'package:geoclass/coordinates_session_page.dart';
import 'package:geoclass/games/aerial.dart';
import 'package:geoclass/games/game.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/games/travel.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/session_page.dart';
import 'package:geoclass/settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A game that exists only in this test: registering this one module is all it takes.
class _QuizGame extends GameModule {
  const _QuizGame();
  @override
  String get id => 'test-quiz';
  @override
  IconData get icon => Icons.quiz;
  @override
  String title(S s) => 'Quiz';
  @override
  bool get hasSetup => true;
  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) async => {
    'quiz': {'questions': []},
  };
  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      Text('teacher ${session.name}');
  @override
  Widget play(PlayContext ctx) => Text('play ${ctx.settings['questions']}');
}

SessionInfo _session(String game) =>
    SessionInfo(id: 's1', name: 'VII a', game: game, status: 'open', rev: 0, createdAt: 0, archived: false);

PlayContext _ctx(Map<String, dynamic> settings, {Api? api}) => PlayContext(
  s: const S('en'),
  lang: 'en',
  token: 'token-1',
  settings: settings,
  now: 0,
  resetAt: 0,
  api: api ?? Api(),
  onStopped: (_) {},
);

void main() {
  final appSettings = Settings();

  test('travel and aerial are modules; the other games are still handled in the pages', () {
    expect(gameModule('travel'), isA<TravelGame>());
    expect(gameModule('aerial'), isA<AerialGame>());
    for (final legacy in ['coordinates', 'mapping', 'cards', 'evidence', 'plates', 'puzzle', 'layout']) {
      expect(gameModule(legacy), isNull, reason: legacy);
    }
    expect(pickableGames().take(9), [
      'travel',
      'coordinates',
      'aerial',
      'evidence',
      'mapping',
      'cards',
      'plates',
      'puzzle',
      'layout',
    ]);
    expect(gameIcon('aerial'), Icons.satellite_alt);
    expect(gameIcon('cards'), Icons.style);
  });

  test('the session page comes from the module, or from the old switch', () {
    expect(sessionPageFor(appSettings, _session('travel')), isA<TravelSessionPage>());
    expect(sessionPageFor(appSettings, _session('aerial')), isA<CoordinatesSessionPage>());
    expect(sessionPageFor(appSettings, _session('cards')), isA<CardsSessionPage>());
  });

  test('the aerial module plays with the tasks join gave, answers kept on the server', () {
    final play = gameModule('aerial')!.play(
      _ctx({
        'answers': 'online',
        'tasks': [
          {'mode': 'photo', 'format': 'dd', 'photo': 'p01.jpg'},
          {'mode': 'photo', 'format': 'dd', 'photo': 'p02.jpg'},
        ],
      }),
    );
    expect(play, isA<CoordinatesPlay>());
    final tasks = (play as CoordinatesPlay).tasks;
    expect(tasks, hasLength(2));
    expect(tasks.every((t) => t.secret), isTrue);
  });

  group('a registered test game', () {
    setUpAll(() => registerGame(const _QuizGame()));

    test('is offered to the teacher, with its icon and name', () {
      expect(pickableGames().last, 'test-quiz');
      expect(gameIcon('test-quiz'), Icons.quiz);
      expect(gameModule('test-quiz')!.title(const S('ka')), 'Quiz');
    });

    testWidgets('gives the teacher’s page and the student’s screen', (tester) async {
      await tester.pumpWidget(MaterialApp(home: sessionPageFor(appSettings, _session('test-quiz'))));
      expect(find.text('teacher VII a'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: gameModule('test-quiz')!.play(_ctx({'questions': 2}))));
      expect(find.text('play 2'), findsOneWidget);
    });

    test('its settings go to the server as they are', () async {
      Map<String, dynamic>? sent;
      final api = Api(
        teacherKey: 'k',
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'session': {
                'id': 's1',
                'name': 'Q',
                'game': 'test-quiz',
                'status': 'open',
                'rev': 0,
                'createdAt': 0,
                'archived': false,
              },
              'token': 't',
            }),
            201,
          );
        }),
      );
      final fields = await gameModule('test-quiz')!.setup(_FakeContext(), const S('en'), 'en');
      await api.createSession('Q', 'test-quiz', fields: fields);
      expect(sent, {
        'name': 'Q',
        'game': 'test-quiz',
        'quiz': {'questions': []},
      });
    });
  });

  testWidgets('the travel module sends an answer left from last time as soon as it opens', (tester) async {
    // The map's tile cache asks for a folder; tests have no platform to give one.
    final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
    SharedPreferences.setMockInitialValues({
      'pending_submissions': jsonEncode([
        {
          'token': 'token-1',
          'submissionId': 'sub-left-0001',
          'participantId': 'par-0001',
          'answer': {},
          'lat': 1,
          'lon': 2,
        },
      ]),
    });
    final sent = <String>[];
    final api = Api(
      client: MockClient((request) async {
        sent.add((jsonDecode(request.body) as Map)['submissionId'] as String);
        return http.Response(jsonEncode({'ok': true, 'duplicate': false}), 201);
      }),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TravelPlay(ctx: _ctx(const {}, api: api)),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(sent, ['sub-left-0001']);
    // As before the move: the earlier answer goes quietly, and the form stays for a new one.
    expect(find.text(const S('en')['student_where']), findsOneWidget);
  });
}

/// setup() of the test game doesn't use its context.
class _FakeContext extends Fake implements BuildContext {}
