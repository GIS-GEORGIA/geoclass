import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/privacy_info.dart';

void main() {
  for (final lang in ['ka', 'en']) {
    testWidgets('the ⓘ opens the privacy summary ($lang)', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = S(lang);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [PrivacyInfoButton(s: s)]),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(find.text(s['info_title']), findsOneWidget);
      for (final k in [...privacyPoints, 'info_intro', 'info_technical']) {
        expect(s[k], isNot(k), reason: 'missing text $k');
        expect(find.text(s[k]), findsOneWidget);
      }
      expect(find.text(s['privacy']), findsOneWidget);
      await tester.tap(find.text(s['close']));
      await tester.pumpAndSettle();
      expect(find.text(s['info_title']), findsNothing);
    });
  }

  testWidgets('a student can erase their answers, after saying yes; the teacher side has no such button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const s = S('ka');
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              PrivacyInfoButton(
                s: s,
                onForget: () async {
                  calls++;
                  return 3;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(s['forget_title']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['forget_title']));
    await tester.pumpAndSettle();
    expect(find.text(s['forget_body']), findsOneWidget);
    await tester.tap(find.text(s['cancel']));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.ensureVisible(find.text(s['forget_title']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['forget_title']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['forget_do']));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text(s.f('forget_done', [3])), findsOneWidget);
    expect(find.text(s['info_title']), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [PrivacyInfoButton(s: s)]),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text(s['forget_title']), findsNothing);
  });
}
