import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/plates.dart';
import 'package:geoclass/plates_page.dart';

void main() {
  const s = S('ka');
  final shapes = parsePlateShapes(File('assets/plates.json').readAsStringSync());

  group('outlines', () {
    test('every shape has both names, a group and parts inside the box', () {
      expect(shapes.length, greaterThanOrEqualTo(30));
      expect(shapes.map((x) => x.id).toSet(), hasLength(shapes.length));
      for (final x in shapes) {
        expect(x.ka, isNotEmpty, reason: x.id);
        expect(x.en, isNotEmpty, reason: x.id);
        expect(['continent', 'country'], contains(x.group));
        expect(x.polys, isNotEmpty, reason: x.id);
        for (final p in x.polys.expand((r) => r)) {
          expect(p.dx.abs() <= 1.001 && p.dy.abs() <= 1.001, isTrue, reason: x.id);
        }
      }
    });

    test('a point is inside a shape only where the shape is', () {
      final square = PlateShape('sq', 'კვ', 'sq', 'country', const [
        [Offset(-0.5, -0.5), Offset(0.5, -0.5), Offset(0.5, 0.5), Offset(-0.5, 0.5)],
      ]);
      expect(square.contains(Offset.zero), isTrue);
      expect(square.contains(const Offset(0.9, 0)), isFalse);
      final saudi = shapes.firstWhere((x) => x.id == 'saudi_arabia');
      expect(saudi.contains(Offset.zero), isTrue);
      expect(saudi.contains(const Offset(-0.99, -0.99)), isFalse);
    });
  });

  group('plates', () {
    test('every shape shows: enough of the dots belong to the figure', () {
      for (final x in shapes) {
        final dots = makePlate(x, platePalettes.first, 1, tries: 6000);
        final share = dots.where((d) => d.figure).length / dots.length;
        expect(share, inInclusiveRange(0.05, 0.75), reason: x.id);
      }
    });

    test('dots stay inside the circle and never overlap', () {
      final dots = makePlate(shapes.first, platePalettes[1], 7);
      expect(dots.length, greaterThan(800));
      for (final d in dots) {
        expect(d.center.distance + d.radius, lessThanOrEqualTo(1.0001));
      }
      for (var i = 0; i < dots.length; i += 7) {
        for (var j = i + 1; j < dots.length; j++) {
          expect((dots[i].center - dots[j].center).distance, greaterThan(dots[i].radius + dots[j].radius));
        }
      }
    });

    test('the same seed makes the same plate, another seed another', () {
      final a = makePlate(shapes[4], platePalettes[0], 42, tries: 3000);
      final b = makePlate(shapes[4], platePalettes[0], 42, tries: 3000);
      final c = makePlate(shapes[4], platePalettes[0], 43, tries: 3000);
      expect([for (final d in a) d.center], [for (final d in b) d.center]);
      expect([for (final d in a) d.color], [for (final d in b) d.color]);
      expect(a.first.center, isNot(c.first.center));
    });

    test('figure and background colours are about equally light', () {
      for (final p in platePalettes) {
        double light(List<Color> colours) => colours.map((c) => c.computeLuminance()).reduce((a, b) => a + b) / colours.length;
        expect((light(p.figure) - light(p.background)).abs(), lessThan(0.04), reason: p.id);
      }
    });
  });

  testWidgets('notice first; then the plates, the answer on demand and the explanation at the end', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: PlatesPage(s: s, lang: 'ka', shapes: shapes)));

    expect(find.text(s['plates_notice_1']), findsOneWidget);
    expect(find.text(s['plates_notice_4']), findsOneWidget);
    await tester.tap(find.text(s['plates_agree']));
    await tester.pump();

    await tester.tap(find.text('6'));
    await tester.tap(find.text(s['plates_group_continent']));
    await tester.pump();
    // Only 4 continents: the teacher is told.
    expect(find.text(s.f('plates_only', [4])), findsOneWidget);
    await tester.tap(find.text(s['plates_start']));
    await tester.pump();

    expect(find.text('1 / 4'), findsOneWidget);
    expect(find.text(s['plates_question']), findsOneWidget);
    final continents = [for (final x in shapes) if (x.group == 'continent') x.ka];
    expect(continents.where((n) => find.text(n).evaluate().isNotEmpty), isEmpty);

    await tester.tap(find.text(s['plates_reveal']));
    await tester.pump();
    expect(continents.where((n) => find.text(n).evaluate().isNotEmpty), hasLength(1));

    // The keyboard works too: right arrow moves on and hides the answer.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('2 / 4'), findsOneWidget);
    expect(find.text(s['plates_question']), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text(s['plates_hide']), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pump();
    }
    expect(find.text(s['plates_end_title']), findsOneWidget);
    expect(find.text(s['plates_end_3']), findsOneWidget);
  });
}
