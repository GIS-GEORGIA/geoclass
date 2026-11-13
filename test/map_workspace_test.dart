import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/main.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/hillshade.dart';
import 'package:geoclass/terrain/map_workspace.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), bytes);
  const s = S('ka');

  void mockTileCache(WidgetTester tester) {
    // The map's tile cache asks for a folder; tests have no platform to give one.
    final cache = Directory.systemTemp.createTempSync('geoclass-tiles-');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
  }

  test('the relief picture is the hillshade in grey, see-through where there is none', () {
    final rgba = reliefPixels(grid);
    final shade = hillshade(grid);
    expect(rgba.length, grid.width * grid.height * 4);
    int alpha(int row, int col) => rgba[(row * 40 + col) * 4 + 3];
    expect(alpha(0, 0), 0); // edge
    expect(alpha(12, 20), 0); // the empty cell
    final i = (5 * 40 + 5) * 4;
    expect(rgba.sublist(i, i + 4), [shade[5 * 40 + 5], shade[5 * 40 + 5], shade[5 * 40 + 5], 255]);
  });

  testWidgets('shows the area, and a touch gives the height there', (tester) async {
    mockTileCache(tester);
    LatLng? touched;
    double? height;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapWorkspace(
            grid: grid,
            s: s,
            onTap: (p, h) {
              touched = p;
              height = h;
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(grid.meta.name('ka')), findsOneWidget);
    expect(find.text(s['terrain_tap_hint']), findsOneWidget);
    expect(find.textContaining('Copernicus WorldDEM-30'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(MapWorkspace)) + const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 400));
    expect(touched, isNotNull);
    expect(height, isNotNull);
    expect(height, closeTo(grid.heightAt(touched!)!, 1e-9));
    expect(find.text(s.f('terrain_height', [height!.round()])), findsOneWidget);
  });

  testWidgets('the whole area stays in view when the map changes size, until the user moves it', (tester) async {
    mockTileCache(tester);
    final map = MapController();
    bool allInView() => grid.outline.every(map.camera.visibleBounds.contains);
    await tester.binding.setSurfaceSize(const Size(400, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapWorkspace(grid: grid, s: s, controller: map),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(allInView(), isTrue);
    final small = map.camera.zoom;
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(allInView(), isTrue);
    expect(map.camera.zoom, greaterThan(small));
  });

  testWidgets('the source box gives the full Copernicus notice', (tester) async {
    mockTileCache(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapWorkspace(grid: grid, s: s),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.textContaining('Copernicus WorldDEM-30'));
    await tester.pumpAndSettle();
    expect(find.text(grid.meta.attribution), findsOneWidget);
    expect(find.text(s['terrain_surface_note']), findsOneWidget);
  });

  testWidgets('an area that cannot be loaded says why, and loads on retry', (tester) async {
    mockTileCache(tester);
    var down = true;
    final loader = DemLoader(
      base: 'https://x.test',
      client: MockClient((req) async {
        if (down) throw const SocketException('offline');
        return switch (req.url.path) {
          '/areas/fixture/1/area.json' => http.Response.bytes(utf8.encode(jsonEncode(metaJson)), 200),
          '/areas/fixture/1/dem.u16.gz' => http.Response.bytes(bytes, 200),
          _ => http.Response('', 404),
        };
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AreaMap(loader: loader, id: 'fixture', version: 1, s: s, builder: (_, g) => Text('loaded ${g.width}')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(s['dem_offline']), findsOneWidget);
    down = false;
    await tester.tap(find.text(s['retry']));
    await tester.pumpAndSettle();
    expect(find.text('loaded 40'), findsOneWidget);
  });

  testWidgets('the slope layer is offered only when the game allows it', (tester) async {
    mockTileCache(tester);
    Future<void> openLayers(bool? slope) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapWorkspace(key: ValueKey(slope), grid: grid, s: s, slope: slope),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip(s['layers']));
      await tester.pump();
    }

    await openLayers(null);
    expect(find.byKey(const Key('terrain_slope_switch')), findsNothing);
    await openLayers(false);
    expect(find.byKey(const Key('terrain_slope_switch')), findsOneWidget);
    expect(find.byType(SlopeLegend), findsNothing);
    await tester.tap(find.byKey(const Key('terrain_slope_switch')));
    await tester.pump();
    expect(find.byType(SlopeLegend), findsOneWidget);
    expect(find.text(s.f('terrain_slope_over', [30])), findsOneWidget);
    expect(find.byType(OverlayImageLayer), findsNWidgets(2)); // relief and slope
  });

  test('the areas page has its own address', () {
    expect(isAreasRoute('/areas'), isTrue);
    expect(isAreasRoute('/#/areas/'), isTrue);
    expect(isAreasRoute('/areas/x'), isFalse);
    expect(isAreasRoute('/'), isFalse);
    expect(joinToken('/areas'), isNull);
  });
}
