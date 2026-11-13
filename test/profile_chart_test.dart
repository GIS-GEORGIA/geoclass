import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/terrain/areas_page.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/profile.dart';
import 'package:geoclass/terrain/profile_chart.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), File('$dir/dem.u16').readAsBytesSync());
  final ref = jsonDecode(File('$dir/profile.json').readAsStringSync()) as Map<String, dynamic>;
  final line = [
    for (final v in ref['vertices'] as List) LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
  ];
  final profile = TerrainProfile.along(grid, line);
  const s = S('ka');

  Widget chartApp(TerrainProfile p, void Function(ProfileSample?) onCursor, {ProfileSample? cursor}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProfileChart(profile: p, s: s, cursor: cursor, onCursor: onCursor),
              ProfileSummary(profile: p, s: s, cursor: cursor),
            ],
          ),
        ),
      ),
    ),
  );

  test('axis steps are 1, 2 or 5 times a power of ten', () {
    expect(niceStep(161, 4), 50);
    expect(niceStep(2150, 4), 1000);
    expect(niceStep(2150, 5), 500);
    expect(niceStep(12, 4), 5);
    expect(niceStep(0, 4), 1);
  });

  test('distances are written in metres, then kilometres', () {
    expect(profileDistance(740.4, s), '740 მ');
    expect(profileDistance(2152.58, s), '2.15 კმ');
    expect(profileDistance(12500, const S('en')), '12.5 km');
  });

  testWidgets('pointing at the chart picks the sample at that distance', (tester) async {
    ProfileSample? picked;
    await tester.pumpWidget(chartApp(profile, (c) => picked = c));
    final box = tester.getRect(find.byType(ProfileChart));
    final plotLeft = box.left + ProfilePainter.left, plotRight = box.right - ProfilePainter.right;

    await tester.tapAt(Offset(plotLeft, box.center.dy));
    expect(picked, same(profile.samples.first));
    await tester.tapAt(Offset(plotRight, box.center.dy));
    expect(picked, same(profile.samples.last));
    await tester.tapAt(Offset((plotLeft + plotRight) / 2, box.center.dy));
    expect(picked!.distance, closeTo(profile.length / 2, profile.length / profile.samples.length));

    final drag = await tester.startGesture(Offset(plotLeft + 10, box.center.dy));
    await drag.moveTo(Offset(plotRight - 10, box.center.dy));
    expect(picked!.distance, greaterThan(profile.length * 0.9));
    await drag.up();
  });

  testWidgets('the summary gives the profile numbers and what is under the cursor', (tester) async {
    final cursor = profile.samples[30];
    await tester.pumpWidget(chartApp(profile, (_) {}, cursor: cursor));
    final text = tester.widgetList<Text>(find.byType(Text)).map((t) => t.textSpan!.toPlainText()).join('\n');
    expect(text, contains('სიგრძე: 2.15 კმ'));
    expect(text, contains('ყველაზე დაბალი: ${profile.lowest!.height!.round()} მ'));
    expect(text, contains('ყველაზე მაღალი: ${profile.highest!.height!.round()} მ'));
    expect(text, contains('ასვლა: ${profile.ascent.round()} მ'));
    expect(text, contains('დაშვება: ${profile.descent.round()} მ'));
    expect(text, contains('ყველაზე ციცაბო: მონაკვეთი 2: 9.1° (-16%)'));
    expect(
      tester.widget<Text>(find.byKey(const Key('profile_cursor'))).textSpan!.toPlainText(),
      'აქ: ${profileDistance(cursor.distance, s)} · ${cursor.height!.round()} მ',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a line with no heights at all still draws, empty', (tester) async {
    final off = TerrainProfile.along(grid, const [LatLng(41.70, 44.80), LatLng(41.70, 44.801)]);
    await tester.pumpWidget(chartApp(off, (_) {}));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('ყველაზე მაღალი'), findsNothing);
  });

  testWidgets('on the areas page, touches draw a line and its profile shows; undo takes a point off', (tester) async {
    final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePreview(grid: grid, s: s),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final map = tester.getRect(find.byType(ProfilePreview));
    final centre = Offset(map.center.dx, map.top + 250);

    await tester.tapAt(centre); // not drawing yet: only the height
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProfileChart), findsNothing);

    await tester.tap(find.text(s['profile_draw']));
    await tester.pump();
    expect(find.text(s['profile_draw_hint']), findsOneWidget);
    await tester.tapAt(centre - const Offset(60, 30));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(centre + const Offset(60, 30));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProfileChart), findsOneWidget);
    expect(find.textContaining('სიგრძე: '), findsOneWidget);

    await tester.tap(find.byTooltip(s['profile_undo']));
    await tester.pump();
    expect(find.byType(ProfileChart), findsNothing);
    await tester.tap(find.byTooltip(s['profile_clear']));
    await tester.pump();
    expect(find.byTooltip(s['profile_clear']), findsNothing);
  });
}
