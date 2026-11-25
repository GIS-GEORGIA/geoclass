import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/games/registry.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/sessions/create_session_page.dart';
import 'package:geoclass/sessions/session_filters.dart';
import 'package:geoclass/sessions/session_widgets.dart';

SessionInfo session(
  String id,
  String name, {
  String status = 'open',
  int at = 0,
  bool archived = false,
  String? by,
  String game = 'coordinates',
}) => SessionInfo(
  id: id,
  name: name,
  game: game,
  status: status,
  rev: 1,
  createdAt: at,
  archived: archived,
  teacherName: by,
);

void main() {
  const s = S('en');
  final all = [
    session('a', 'Rivers practice', at: 100),
    session('b', 'rivers quiz', status: 'closed', at: 300, by: 'Nino'),
    session('c', 'Mountains', status: 'paused', at: 200, by: 'Giorgi'),
    session('d', 'Old rivers', at: 50, archived: true),
    session('e', 'Rivers team', status: 'closed', at: 400),
  ];
  List<String> ids(SessionFilter f) => [for (final x in filterSessions(all, f)) x.id];

  group('filterSessions', () {
    test('defaults: not archived, newest first', () {
      expect(ids(const SessionFilter()), ['e', 'b', 'c', 'a']);
      expect(ids(const SessionFilter(archived: true)), ['e', 'b', 'c', 'a', 'd']);
    });

    test('search ignores case and spaces at either end', () {
      expect(ids(const SessionFilter(query: '  RIVERS ')), ['e', 'b', 'a']);
      expect(ids(const SessionFilter(query: 'nothing')), isEmpty);
    });

    test('filters combine', () {
      expect(ids(const SessionFilter(query: 'rivers', status: 'closed')), ['e', 'b']);
      expect(ids(const SessionFilter(query: 'rivers', status: 'closed', creator: mine)), ['e']);
      expect(ids(const SessionFilter(status: 'paused', creator: 'Giorgi')), ['c']);
      expect(ids(const SessionFilter(status: 'open', creator: 'Nino')), isEmpty);
    });

    test('sorts oldest first and by name', () {
      expect(ids(const SessionFilter(sort: SessionSort.oldest)), ['a', 'c', 'b', 'e']);
      expect(ids(const SessionFilter(sort: SessionSort.name)), ['c', 'a', 'b', 'e']);
    });

    test('reset keeps the archived switch only', () {
      const f = SessionFilter(query: 'x', status: 'open', creator: 'Nino', sort: SessionSort.name, archived: true);
      expect(f.isFiltered, isTrue);
      final r = f.reset();
      expect(r.isFiltered, isFalse);
      expect(r.archived, isTrue);
      expect(const SessionFilter(archived: true).isFiltered, isFalse);
      expect(f.copyWith(status: () => null).status, isNull);
      expect(f.copyWith(query: 'y').status, 'open');
    });
  });

  test('creators: the teacher first, then the others by name', () {
    expect(creators(all), [mine, 'Giorgi', 'Nino']);
    expect(creators([all[1]]), ['Nino']);
    expect(creators(const []), isEmpty);
  });

  test('validSessionName', () {
    expect(validSessionName(''), isFalse);
    expect(validSessionName('   \n'), isFalse);
    expect(validSessionName(' a '), isTrue);
    expect(validSessionName('x' * maxSessionName), isTrue);
    expect(validSessionName('x' * (maxSessionName + 1)), isFalse);
  });

  test('suggestedNames name the game, number the next one and stay within the limit', () {
    for (final lang in ['ka', 'en']) {
      final names = suggestedNames(S(lang), 'Rivers', 4);
      expect(names, hasLength(6), reason: lang);
      expect(names.toSet(), hasLength(6), reason: lang);
      for (final n in names) {
        expect(n, contains('Rivers'), reason: lang);
        expect(validSessionName(n), isTrue, reason: lang);
      }
      expect(names.last, contains('05'), reason: lang);
    }
    // A title that asks a question loses its question mark before the suffix.
    expect(suggestedNames(s, 'Where did you travel?', 0).first, isNot(contains('?')));
    expect(suggestedNames(s, 'Where did you travel?', 0).first, contains('Where did you travel'));
    for (final n in suggestedNames(s, 'G' * 120, 0)) {
      expect(n.length, lessThanOrEqualTo(maxSessionName));
    }
  });

  group('CreateSessionPage', () {
    // A game with no setup, so the button says Create.
    final game = pickableGames().firstWhere((g) => !(gameModule(g)?.hasSetup ?? g != 'mapping'));

    Future<List<(String, String)?>> open(WidgetTester t) async {
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final results = <(String, String)?>[];
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await Navigator.push<(String, String)>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CreateSessionPage(s: s, counts: {game: 2}),
                    ),
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      return results;
    }

    bool enabled(WidgetTester t) => t.widget<FilledButton>(find.byKey(const Key('create_submit'))).onPressed != null;

    testWidgets('needs a game and a name that is not only spaces', (t) async {
      await open(t);
      expect(enabled(t), isFalse);
      expect(find.byKey(const Key('create_name')), findsNothing);

      await t.tap(find.byKey(Key('create_game_$game')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('create_suggestion_0')), findsOneWidget);
      expect(enabled(t), isFalse);

      await t.enterText(find.byKey(const Key('create_name')), '   ');
      await t.pump();
      expect(enabled(t), isFalse);
      expect(find.text(s['session_name_required']), findsOneWidget);

      await t.enterText(find.byKey(const Key('create_name')), 'Class 7');
      await t.pump();
      expect(enabled(t), isTrue);
      expect(find.text(s['session_name_required']), findsNothing);
    });

    testWidgets('a suggestion fills the name, which can still be edited, and comes back trimmed', (t) async {
      final results = await open(t);
      await t.tap(find.byKey(Key('create_game_$game')));
      await t.pumpAndSettle();

      final names = suggestedNames(s, gameTitle(s, game), 2);
      expect(names.last, contains('03'));
      await t.tap(find.byKey(const Key('create_suggestion_1')));
      await t.pump();
      final field = t.widget<TextField>(find.byKey(const Key('create_name')));
      expect(field.controller!.text, names[1]);
      expect(enabled(t), isTrue);

      await t.enterText(find.byKey(const Key('create_name')), '  ${names[1]} B  ');
      await t.pump();
      await t.tap(find.byKey(const Key('create_submit')));
      await t.pumpAndSettle();
      expect(results, [(game, '${names[1]} B')]);
    });

    testWidgets('on a phone the games are one column, so their names are not cut', (t) async {
      await open(t);
      await t.binding.setSurfaceSize(null);
      t.view.physicalSize = const Size(400, 900);
      await t.pumpAndSettle();
      final first = t.getRect(find.byKey(Key('create_game_${pickableGames()[0]}')));
      final second = t.getRect(find.byKey(Key('create_game_${pickableGames()[1]}')));
      expect(first.width, greaterThan(300));
      expect(second.top, greaterThan(first.bottom));
      expect(t.takeException(), isNull);

      // Picking a game far up the long list brings the naming part into view.
      await t.tap(find.byKey(Key('create_game_${pickableGames()[0]}')));
      await t.pumpAndSettle();
      final name = t.getRect(find.byKey(const Key('create_name')));
      expect(name.bottom, lessThanOrEqualTo(900));
      expect(name.top, greaterThanOrEqualTo(0));
      // Long suggestions wrap instead of being cut at the edge.
      for (var i = 0; i < 6; i++) {
        final box = find.byKey(Key('create_suggestion_$i'));
        expect(t.getRect(box).right, lessThanOrEqualTo(400));
        final text = t.renderObject<RenderParagraph>(find.descendant(of: box, matching: find.byType(RichText)));
        expect(text.didExceedMaxLines, isFalse);
      }
    });

    testWidgets('cancel returns nothing', (t) async {
      final results = await open(t);
      await t.tap(find.text(s['cancel']));
      await t.pumpAndSettle();
      expect(results, [null]);
    });
  });

  group('SessionCard', () {
    Future<List<SessionAction>> card(WidgetTester t, SessionInfo x) async {
      final got = <SessionAction>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: sessionCardHeight,
              child: SessionCard(s: s, session: x, onAction: got.add),
            ),
          ),
        ),
      );
      return got;
    }

    testWidgets('shows the session and offers open and delete', (t) async {
      final got = await card(t, session('a', 'Rivers practice', status: 'paused', by: 'Nino', at: 1700000000));
      expect(find.text('Rivers practice'), findsOneWidget);
      expect(find.text(gameTitle(s, 'coordinates')), findsOneWidget);
      expect(find.textContaining('Nino'), findsOneWidget);
      expect(find.text(s['status_paused']), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.tap(find.byKey(const Key('session_open_a')));
      await t.tap(find.byKey(const Key('session_menu_a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('session_delete')));
      await t.pumpAndSettle();
      expect(got, [SessionAction.open, SessionAction.delete]);
    });

    testWidgets('a long name does not overflow', (t) async {
      await card(t, session('b', 'A very long session name ' * 6, archived: true));
      expect(t.takeException(), isNull);
      expect(find.text(s['archived']), findsOneWidget);
    });
  });

  testWidgets('SessionToolbar: on a phone the status is a drop-down', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var f = const SessionFilter();
    final search = TextEditingController();
    addTearDown(search.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => SessionToolbar(
              s: s,
              filter: f,
              creators: const [mine],
              search: search,
              onChanged: (v) => set(() => f = v),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.byKey(const Key('session_creator')), findsNothing);
    await t.tap(find.byKey(const Key('session_status')));
    await t.pumpAndSettle();
    await t.tap(find.text(s['status_closed']).last);
    await t.pumpAndSettle();
    expect(f.status, 'closed');
    expect(t.takeException(), isNull);
  });

  testWidgets('SessionToolbar: reset clears the search and the filters', (t) async {
    final search = TextEditingController(text: 'riv');
    addTearDown(search.dispose);
    var f = const SessionFilter(query: 'riv', status: 'closed', sort: SessionSort.name);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => SessionToolbar(
              s: s,
              filter: f,
              creators: const [mine, 'Nino'],
              search: search,
              onChanged: (v) => set(() => f = v),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('session_creator')), findsOneWidget);
    await t.tap(find.text(s['status_open']));
    await t.pump();
    expect(f.status, 'open');
    expect(f.query, 'riv');

    await t.tap(find.byKey(const Key('session_reset')));
    await t.pump();
    expect(f.isFiltered, isFalse);
    expect(search.text, isEmpty);
    expect(t.widget<TextButton>(find.byKey(const Key('session_reset'))).onPressed, isNull);
  });
}
