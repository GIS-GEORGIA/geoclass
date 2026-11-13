import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/coords.dart';
import 'package:geoclass/terrain/dem_loader.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/hillshade.dart';
import 'package:geoclass/terrain/profile.dart';
import 'package:geoclass/terrain/slope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// The terrain grid against GDAL. test/fixtures/terrain is a 40×30 piece of the real Kazbegi package
/// with one empty cell, written with GDAL's answers by tool/areas/make_test_fixture.py.
void main() {
  const dir = 'test/fixtures/terrain';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final bytes = File('$dir/dem.u16').readAsBytesSync();
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final meta = AreaMeta.fromJson(metaJson);
  final grid = ElevationGrid.fromBytes(meta, bytes);

  group('grid', () {
    test('reads the size, position and scale from area.json', () {
      expect(meta.zone, 38);
      expect([meta.width, meta.height, meta.cell], [40, 30, 30.0]);
      expect(meta.attribution, startsWith('produced using Copernicus WorldDEM-30'));
      expect(meta.surface, contains('DSM'));
    });

    test('cell values are the stored steps of 0.1 m, little-endian', () {
      final raw = ByteData.sublistView(bytes);
      expect(grid.cellHeight(0, 0), closeTo(raw.getUint16(0, Endian.little) * 0.1, 1e-9));
      expect(grid.cellHeight(12, 20), isNull); // the empty cell
      expect(grid.cellHeight(-1, 0), isNull);
      expect(grid.cellHeight(0, 40), isNull);
    });

    test('heights between cells agree with GDAL bilinear, empty cells included', () {
      final points = expected['heights'] as List;
      var empty = 0;
      for (final p in points) {
        final h = grid.heightAtUtm((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
        if (p['h'] == null) {
          expect(h, isNull, reason: '$p');
          empty++;
        } else {
          expect(h, closeTo((p['h'] as num).toDouble(), 0.001), reason: '$p');
        }
      }
      expect(points.length, greaterThan(40));
      expect(empty, 3);
    });

    test('outside the grid there is no height', () {
      final b = meta.bounds;
      expect(grid.heightAtUtm(b[0] - 1, b[3] - 100), isNull);
      expect(grid.heightAtUtm(b[0] + 100, b[1] - 0.01), isNull);
      expect(grid.heightAtUtm(b[0], b[3]), grid.cellHeight(0, 0));
    });

    test('map positions convert to UTM as GDAL does', () {
      for (final p in expected['utm'] as List) {
        final u = toUtm((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble(), zone: meta.zone);
        expect(u.easting, closeTo((p['x'] as num).toDouble(), 0.01), reason: p['name'] as String);
        expect(u.northing, closeTo((p['y'] as num).toDouble(), 0.01), reason: p['name'] as String);
      }
    });

    test('a height asked for by map position is the one at its UTM point', () {
      final c = grid.cellCentre(7, 9);
      final p = fromUtm(meta.zone, c.x, c.y);
      expect(grid.heightAt(p), closeTo(grid.cellHeight(7, 9)!, 0.01));
      expect(grid.heightAt(const LatLng(41.7, 44.8)), isNull); // Tbilisi, far outside
    });

    test('the outline goes round the grid', () {
      final o = grid.outline;
      expect(o, hasLength(4));
      expect(o[0].latitude, lessThan(o[3].latitude));
      expect(o[0].longitude, lessThan(o[1].longitude));
      expect(grid.heightAt(o[0]), isNotNull);
    });

    test('a grid of the wrong size is refused', () {
      expect(() => ElevationGrid.fromBytes(meta, Uint8List(bytes.length - 2)), throwsFormatException);
    });

    test('area.json the app cannot use is refused', () {
      Map<String, dynamic> changed(void Function(Map<String, dynamic>) f) {
        final j = jsonDecode(jsonEncode(metaJson)) as Map<String, dynamic>;
        f(j);
        return j;
      }

      for (final bad in [
        changed((j) => j['crs'] = 'EPSG:4326'),
        changed((j) => j['grid']['type'] = 'float32'),
        changed((j) => j['width'] = 41),
        changed((j) => j['width'] = 5000),
        changed((j) => j['id'] = '../x'),
        changed((j) => j['grid']['sha256'] = 'abc'),
      ]) {
        expect(() => AreaMeta.fromJson(bad), throwsFormatException);
      }
    });
  });

  group('hillshade', () {
    final gdal = File('$dir/hillshade.u8').readAsBytesSync();

    test('is the same as gdaldem hillshade, cell for cell', () {
      final shade = hillshade(grid);
      expect(shade.length, gdal.length);
      var worst = 0;
      for (var i = 0; i < shade.length; i++) {
        expect(shade[i] == 0, gdal[i] == 0, reason: 'cell $i: ours ${shade[i]}, gdaldem ${gdal[i]}');
        worst = (shade[i] - gdal[i]).abs() > worst ? (shade[i] - gdal[i]).abs() : worst;
      }
      expect(worst, lessThanOrEqualTo(1));
      expect(shade.where((v) => v == 0).length, 145); // the edge, and the 9 cells around the empty one
    });

    test('light from the other side darkens what was lit', () {
      final a = hillshade(grid), b = hillshade(grid, azimuth: 135);
      final cells = [
        for (var i = 0; i < a.length; i++)
          if (a[i] != 0) i,
      ];
      final ma = cells.map((i) => a[i]).reduce((x, y) => x + y) / cells.length;
      final mb = cells.map((i) => b[i]).reduce((x, y) => x + y) / cells.length;
      final together = cells.map((i) => (a[i] - ma) * (b[i] - mb)).reduce((x, y) => x + y);
      expect(together, lessThan(0)); // where one is brighter than usual, the other is darker
    });
  });

  group('profile', () {
    final ref = jsonDecode(File('$dir/profile.json').readAsStringSync()) as Map<String, dynamic>;
    final line = [
      for (final v in ref['vertices'] as List) LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()),
    ];
    final profile = TerrainProfile.along(grid, line);
    double? num_(Object? v) => (v as num?)?.toDouble();

    test('samples every half cell, with GDAL heights and geodesic distances', () {
      final want = ref['samples'] as List;
      expect(profile.samples, hasLength(want.length));
      for (var i = 0; i < want.length; i++) {
        final got = profile.samples[i], w = want[i];
        expect(got.distance, closeTo(num_(w['d'])!, 0.001), reason: 'sample $i');
        if (w['h'] == null) {
          expect(got.height, isNull, reason: 'sample $i');
        } else {
          expect(got.height, closeTo(num_(w['h'])!, 0.01), reason: 'sample $i');
        }
      }
      for (var i = 1; i < profile.samples.length; i++) {
        final a = profile.samples[i - 1], b = profile.samples[i];
        expect(math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2)), lessThanOrEqualTo(grid.cell / 2 + 1e-9));
      }
      expect(profile.samples.where((s) => s.height == null), hasLength(2)); // crossing the empty cell
    });

    test('length, lowest, highest, climb and drop are as GDAL and PROJ give them', () {
      expect(profile.length, closeTo(num_(ref['length'])!, 0.001));
      expect(profile.lowest!.height, closeTo(num_(ref['min'])!, 0.01));
      expect(profile.highest!.height, closeTo(num_(ref['max'])!, 0.01));
      expect(profile.ascent, closeTo(num_(ref['ascent'])!, 0.05));
      expect(profile.descent, closeTo(num_(ref['descent'])!, 0.05));
      // What goes up and comes down adds up to the change from end to end, gap aside.
      final first = profile.samples.first.height!, last = profile.samples.last.height!;
      expect(profile.ascent - profile.descent, closeTo(last - first, 30));
    });

    test('each section has its length and mean grade, and the steepest is found', () {
      final want = ref['sections'] as List;
      expect(profile.sections, hasLength(3));
      for (var k = 0; k < 3; k++) {
        final got = profile.sections[k], w = want[k];
        expect(got.start, closeTo(num_(w['start'])!, 0.001));
        expect(got.length, closeTo(num_(w['length'])!, 0.001));
        expect(got.grade, closeTo(num_(w['grade'])!, 1e-5));
      }
      expect(profile.steepest!.index, 1);
      expect(profile.steepest!.slopeDegrees, closeTo(math.atan(num_(want[1]['grade'])!) * 180 / math.pi, 1e-3));
    });

    test('finds the sample nearest a distance, and where it is on the map', () {
      expect(profile.nearest(-5), same(profile.samples.first));
      expect(profile.nearest(1e9), same(profile.samples.last));
      final s = profile.samples[40];
      expect(profile.nearest(s.distance + 1), same(s));
      expect(grid.heightAt(profile.positionOf(s)), closeTo(s.height!, 0.01));
    });

    test('a line off the area has no heights, and a line needs two vertices', () {
      final off = TerrainProfile.along(grid, const [LatLng(41.70, 44.80), LatLng(41.70, 44.801)]);
      expect(off.samples.every((s) => s.height == null), isTrue);
      expect(off.lowest, isNull);
      expect(off.steepest, isNull);
      expect(off.ascent, 0);
      expect(() => TerrainProfile.along(grid, [line.first]), throwsArgumentError);
      expect(() => TerrainProfile.along(grid, const [LatLng(35, 30), LatLng(50, 60)]), throwsArgumentError);
    });
  });

  group('slope', () {
    final raw = File('$dir/slope.f32').readAsBytesSync();
    final gdal = Float32List.view(Uint8List.fromList(raw).buffer);

    test('is the same as gdaldem slope, cell for cell', () {
      final ours = slope(grid);
      expect(ours.length, gdal.length);
      var worst = 0.0, empty = 0;
      for (var i = 0; i < ours.length; i++) {
        final none = gdal[i] == -9999;
        expect(ours[i].isNaN, none, reason: 'cell $i: ours ${ours[i]}, gdaldem ${gdal[i]}');
        if (none) {
          empty++;
        } else {
          worst = math.max(worst, (ours[i] - gdal[i]).abs());
        }
      }
      expect(worst, lessThan(1e-3)); // degrees
      expect(empty, 145); // the edge, and the 9 cells around the empty one
    });

    test('a plane of known grade has that slope everywhere', () {
      // Heights rising 1 m per 30 m cell to the east and 1 m to the north: tan(slope) = sqrt(2) / 30.
      final m = AreaMeta.fromJson(metaJson);
      final b = ByteData(m.width * m.height * 2);
      for (var r = 0; r < m.height; r++) {
        for (var c = 0; c < m.width; c++) {
          b.setUint16((r * m.width + c) * 2, 10000 + 10 * c + 10 * (m.height - r), Endian.little);
        }
      }
      final plane = slope(ElevationGrid.fromBytes(m, b.buffer.asUint8List()));
      final want = math.atan(math.sqrt(2) / 30) * 180 / math.pi;
      expect(plane[5 * m.width + 5], closeTo(want, 1e-4));
      expect(plane[20 * m.width + 30], closeTo(want, 1e-4));
    });

    test('classes and their colours', () {
      expect(<double>[double.nan, 0, 4.99, 5, 14.9, 15, 29.9, 30, 70].map(slopeClass), [-1, 0, 0, 1, 1, 2, 2, 3, 3]);
      final rgba = slopePixels(Float32List.fromList([double.nan, 2, 40]));
      expect(rgba.sublist(0, 4), [0, 0, 0, 0]);
      expect(rgba.sublist(4, 8), [0x4c, 0xaf, 0x50, 255]);
      expect(rgba.sublist(8, 12), [0xd3, 0x2f, 0x2f, 255]);
    });
  });

  group('loader', () {
    final catalog = {
      'areas': [
        {'id': 'fixture', 'version': 1, 'ka': 'ნიმუში', 'en': 'Sample', 'bbox': metaJson['bbox'], 'min': 1, 'max': 2},
      ],
      'attribution': metaJson['attribution'],
    };

    http.Response respond(http.Request req, {Uint8List? grid, Map<String, dynamic>? area}) => switch (req.url.path) {
      '/areas/catalog.json' => http.Response.bytes(utf8.encode(jsonEncode(catalog)), 200),
      '/areas/fixture/1/area.json' => http.Response.bytes(utf8.encode(jsonEncode(area ?? metaJson)), 200),
      '/areas/fixture/1/dem.u16.gz' => http.Response.bytes(grid ?? bytes, 200),
      _ => http.Response('not found', 404),
    };

    MockClient server({Uint8List? grid, Map<String, dynamic>? area, List<String>? log}) => MockClient((req) async {
      log?.add(req.url.path);
      return respond(req, grid: grid, area: area);
    });

    test('lists the catalog', () async {
      final areas = await DemLoader(client: server(), base: 'https://x.test').catalog();
      expect(areas.single.id, 'fixture');
      expect(areas.single.name('ka'), 'ნიმუში');
    });

    test('loads a grid, and the same grid again without asking twice', () async {
      final log = <String>[];
      final loader = DemLoader(
        client: server(log: log),
        base: 'https://x.test',
      );
      final a = await loader.load('fixture', 1);
      final b = await loader.load('fixture', 1);
      expect(identical(a, b), isTrue);
      expect(a.cellHeight(0, 0), grid.cellHeight(0, 0));
      expect(log, ['/areas/fixture/1/area.json', '/areas/fixture/1/dem.u16.gz']);
    });

    test('a damaged or cut-off grid is refused', () async {
      final damaged = Uint8List.fromList(bytes)..[100] ^= 1;
      for (final g in [damaged, Uint8List.sublistView(bytes, 0, bytes.length - 2)]) {
        final loader = DemLoader(
          client: server(grid: g),
          base: 'https://x.test',
        );
        await expectLater(
          loader.load('fixture', 1),
          throwsA(isA<DemError>().having((e) => e.key, 'key', 'dem_bad_data')),
        );
      }
    });

    test('area.json for another area is refused', () async {
      final other = Map<String, dynamic>.from(metaJson)..['id'] = 'mestia';
      final loader = DemLoader(
        client: server(area: other),
        base: 'https://x.test',
      );
      await expectLater(loader.load('fixture', 1), throwsA(isA<DemError>()));
    });

    test('a missing area says so', () async {
      final loader = DemLoader(client: server(), base: 'https://x.test');
      await expectLater(
        loader.load('mestia', 1),
        throwsA(isA<DemError>().having((e) => e.key, 'key', 'dem_not_found')),
      );
    });

    test('no connection says so, and the next try asks again', () async {
      var down = true;
      final loader = DemLoader(
        client: MockClient((req) async {
          if (down) throw const SocketException('offline');
          return respond(req);
        }),
        base: 'https://x.test',
      );
      await expectLater(loader.load('fixture', 1), throwsA(isA<DemError>().having((e) => e.key, 'key', 'dem_offline')));
      down = false;
      expect((await loader.load('fixture', 1)).width, 40);
    });

    test('a bad area id is not even asked for', () async {
      final log = <String>[];
      final loader = DemLoader(
        client: server(log: log),
        base: 'https://x.test',
      );
      await expectLater(loader.load('../secret', 1), throwsA(isA<DemError>()));
      expect(log, isEmpty);
    });
  });
}
