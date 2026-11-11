import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/layout.dart';
import 'package:geoclass/layout_play.dart';
import 'package:geoclass/puzzle.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const s = S('ka');
  final units = parseGeoUnits(File('assets/ge_units.json').readAsStringSync());

  test('the score matches the server: colours, elements on the page, grid', () {
    final sheet = Sheet(
      [3, 0, 2, -1],
      [
        SheetElement('title', const Rect.fromLTWH(0.3, 0.02, 0.4, 0.08)),
        SheetElement('north', const Rect.fromLTWH(0.9, 0.1, 0.06, 0.1)),
        SheetElement('legend', const Rect.fromLTWH(1.2, 0.5, 0.2, 0.3)),
      ],
      grid: 0.5,
      title: 'საქართველოს რეგიონები',
    );
    expect(layoutScore([3, 0, 1, 2], sheet), 53);
    sheet.title = '';
    expect(layoutScore([3, 0, 2, -1], sheet), 70 + 6 + 6);
    final copy = Sheet.fromJson(jsonDecode(jsonEncode(sheet.toJson())) as Map<String, dynamic>, 4);
    expect(copy.toJson(), sheet.toJson());
    expect(sheet.toJson()['grid'], 0.5);
  });

  test('a legend gives each unit its own colour; regions with up to 12 municipalities', () {
    final legend = makeLegend(12, Random(1));
    expect(legend.toSet(), hasLength(12));
    expect(layoutUnits(units, 'georgia'), hasLength(12));
    final regions = layoutRegions(units).map((r) => r.id);
    expect(regions, contains('ge_imereti'));
    expect(regions, isNot(contains('ge_abkhazia')));
  });

  test('the map fills its frame, every unit can be tapped, and the scale is about right', () {
    final map = SheetMap.of(units, 'georgia');
    for (var i = 0; i < map.units.length; i++) {
      final rings = map.rings[i];
      // A point well inside the unit: the label point of its puzzle piece, projected the same way.
      final piece = PuzzlePiece(i, '', '', '', rings);
      expect(map.unitAt(piece.labelAt), i, reason: map.units[i].id);
    }
    expect(map.unitAt(const Offset(0.9, 0.3)), isNull);
    // Georgia, about 700 km wide, on some 20 cm of paper.
    expect(map.scaleDenominator, inInclusiveRange(2.5e6, 4.5e6));
    expect(formatScale(3456789), '1 : 3 500 000');
    expect(niceKm(87), 50);
    expect(niceKm(230), 200);
    final b = map.lonLatBounds;
    expect(b.left, lessThan(40.1));
    expect(b.right, greaterThan(46.6));
  });

  test('the PDF is one A4 page', () async {
    final map = SheetMap.of(units, 'ge_guria');
    final bytes = await sheetPdf(map, Sheet.empty(map.units.length), const [0, 1, 2], 'ka');
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    final media = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)').firstMatch(latin1.decode(bytes));
    // A4 landscape in points: 297 × 210 mm.
    expect(double.parse(media!.group(1)!), closeTo(841.9, 0.1));
    expect(double.parse(media.group(2)!), closeTo(595.3, 0.1));
  });

  testWidgets('student: colours a unit, adds elements and a grid, hands in', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    Map<String, dynamic>? sent;
    final api = Api(
      client: MockClient((request) async {
        sent = (jsonDecode(request.body) as Map<String, dynamic>)['answer'] as Map<String, dynamic>;
        return http.Response(jsonEncode({'ok': true, 'score': 41}), 201, headers: {'content-type': 'application/json'});
      }),
    );
    const settings = {
      'area': 'ge_guria',
      'legend': [4, 7, 1],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayoutPlay(
            s: s,
            lang: 'ka',
            token: 'tok',
            settings: settings,
            api: api,
            onStopped: (_) {},
            units: units,
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    final map = SheetMap.of(units, 'ge_guria');
    final ozurgeti = map.units.indexWhere((u) => u.ka == 'ოზურგეთი');
    await tester.tap(find.text('ოზურგეთი'));
    await tester.pump();
    final sheet = find.byKey(const ValueKey('sheet'));
    final box = tester.getRect(sheet);
    final inside = PuzzlePiece(0, '', '', '', map.rings[ozurgeti]).labelAt;
    await tester.tapAt(box.topLeft + Offset(inside.dx * box.width, inside.dy * box.width));
    await tester.pump();

    await tester.tap(find.text(s['layout_el_north']));
    await tester.tap(find.text(s['layout_el_title']));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'გურია');
    await tester.tap(find.text('1°'));
    await tester.pump();
    await tester.tap(find.text(s['layout_hand_in']));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    final fills = (sent!['fills'] as List).cast<int>();
    expect(fills[ozurgeti], const [4, 7, 1][ozurgeti]);
    expect(fills.where((f) => f >= 0), hasLength(1));
    expect([for (final e in sent!['elements'] as List) (e as Map)['kind']], ['north', 'title']);
    expect(sent!['title'], 'გურია');
    expect(sent!['grid'], 1);
    expect(find.text(s.f('layout_score', [41])), findsOneWidget);
  });
}
