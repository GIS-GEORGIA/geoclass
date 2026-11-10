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
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(appBar: AppBar(actions: [PrivacyInfoButton(s: s)])),
      ));
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
}
