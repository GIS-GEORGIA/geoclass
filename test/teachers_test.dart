import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/teachers_page.dart';

void main() {
  test('the message to a new teacher has the key, the site and the end date in both languages', () {
    final end = DateTime(2026, 12, 31, 12).millisecondsSinceEpoch ~/ 1000;
    final m = keyMessage('Nino', 'KEY-123', end, 'https://geoclass.qgis.ge');
    expect('KEY-123'.allMatches(m).length, 2);
    expect('2026-12-31'.allMatches(m).length, 2);
    expect(m, contains('გამარჯობა, Nino!'));
    expect(m, contains('Hello, Nino!'));
    expect(m, contains('https://geoclass.qgis.ge'));
  });

  test('dates are shown as year-month-day', () {
    expect(dayOf(DateTime(2027, 3, 5, 9).millisecondsSinceEpoch ~/ 1000), '2027-03-05');
  });

  testWidgets('the validity dialog needs a name and a validity of at most five years', (tester) async {
    (String, int, String)? picked;
    final s = S('en');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showDialog<(String, int, String)>(
              context: context,
              builder: (_) => ValidityDialog(s: s, askName: true),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    FilledButton create() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, s['create']));
    expect(create().onPressed, isNull); // no name yet

    await tester.enterText(find.widgetWithText(TextField, s['teacher_name']), 'Nino');
    await tester.pump();
    expect(create().onPressed, isNotNull); // 30 days by default

    await tester.tap(find.text(s['unit_day']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s['unit_year']).last);
    await tester.pumpAndSettle();
    expect(create().onPressed, isNull); // 30 years is too long
    await tester.enterText(find.widgetWithText(TextField, s['teacher_valid_for']), '2');
    await tester.pump();
    await tester.tap(find.text(s['create']));
    await tester.pumpAndSettle();
    expect(picked, ('Nino', 2, 'year'));
  });
}
