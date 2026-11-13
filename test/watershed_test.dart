import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/watershed.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const dir = 'test/fixtures/watershed';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), File('$dir/dem.u16').readAsBytesSync());
  final flow = FlowGrid(grid.width, grid.height, File('$dir/flow.u8').readAsBytesSync());
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final acc = accumulation(flow);

  List<List<int>> runsOf(Object? v) => [for (final r in v as List) (r as List).cast<int>()];

  group('basins', () {
    test('are GRASS r.watershed + r.water.outlet basins, cell for cell', () {
      final basins = (expected['basins'] as List).cast<Map<String, dynamic>>();
      expect(basins, hasLength(3));
      for (final b in basins) {
        final (row, col) = ((b['outlet'] as List)[0] as int, (b['outlet'] as List)[1] as int);
        final mask = basinMask(flow, row, col);
        expect(maskRuns(mask, flow.width), runsOf(b['runs']), reason: 'outlet $row, $col');
        // The accumulation at an outlet is its basin's size.
        expect(acc[row * flow.width + col], b['cells']);
        expect(touchesEdge(mask, flow.width, flow.height), isFalse);
      }
    });

    test('every cell drains somewhere: the accumulation adds up', () {
      var leaving = 0;
      for (var i = 0; i < acc.length; i++) {
        if (flow.downstream(i) < 0) leaving += acc[i];
      }
      expect(leaving, flow.width * flow.height);
      // The whole piece drains out somewhere along its edge, so a cell there has a basin that touches it.
      final out = Iterable.generate(acc.length).firstWhere((i) => flow.downstream(i) < 0);
      expect(touchesEdge(basinMask(flow, out ~/ flow.width, out % flow.width), flow.width, flow.height), isTrue);
    });

    test('runs and masks go both ways', () {
      final mask = basinMask(flow, 76, 38);
      expect(runsMask(maskRuns(mask, flow.width), flow.width, flow.height), mask);
    });

    test('a touch near a stream finds the nearest stream cell', () {
      final b = (expected['basins'] as List)[2] as Map<String, dynamic>;
      final (row, col) = ((b['outlet'] as List)[0] as int, (b['outlet'] as List)[1] as int);
      // On the stream: that very cell.
      expect(snapToStream(flow, acc, row, col, minCells: 100), (row: row, col: col));
      // Beside it: a stream cell, and none nearer.
      final near = snapToStream(flow, acc, row + 2, col - 3, minCells: 100)!;
      expect(acc[near.row * flow.width + near.col], greaterThanOrEqualTo(100));
      final d = (near.row - row - 2) * (near.row - row - 2) + (near.col - col + 3) * (near.col - col + 3);
      for (var r = row - 8; r <= row + 12; r++) {
        for (var c = col - 13; c <= col + 7; c++) {
          if (r < 0 || c < 0 || r >= flow.height || c >= flow.width) continue;
          final dd = (r - row - 2) * (r - row - 2) + (c - col + 3) * (c - col + 3);
          if (acc[r * flow.width + c] >= 100) expect(dd, greaterThanOrEqualTo(d));
        }
      }
      expect(snapToStream(flow, acc, 0, 0, minCells: 1 << 30), isNull);
    });

    test('streams and basins as map pixels', () {
      final rgba = streamPixels(Int32List.fromList([5, 1]), 5);
      expect(rgba.sublist(0, 4), [0x15, 0x65, 0xc0, 255]);
      expect(rgba.sublist(4, 8), [0, 0, 0, 0]);
      expect(maskPixels(Uint8List.fromList([1])).sublist(0, 4), [0x00, 0x89, 0x7b, 255]);
    });
  });

  group('drawn polygons', () {
    test('cells inside by their centres, as the server counts them', () {
      // A 2 × 3 rectangle on cell edges holds 6 cells; one shifted by under half a cell still does.
      const rect = <GridPoint>[(row: 2, col: 1), (row: 2, col: 4), (row: 4, col: 4), (row: 4, col: 1)];
      expect(polygonRuns(rect), [
        [2, 1, 4],
        [3, 1, 4],
      ]);
      const shifted = <GridPoint>[
        (row: 2.3, col: 1.4),
        (row: 2.3, col: 4.4),
        (row: 4.3, col: 4.4),
        (row: 4.3, col: 1.4),
      ];
      expect(runCells(polygonRuns(shifted)), 6);
      // A U shape: two runs on its lower rows.
      const u = <GridPoint>[
        (row: 0, col: 0),
        (row: 0, col: 1),
        (row: 2, col: 1),
        (row: 2, col: 2),
        (row: 0, col: 2),
        (row: 0, col: 3),
        (row: 3, col: 3),
        (row: 3, col: 0),
      ];
      expect(polygonRuns(u), [
        [0, 0, 1],
        [0, 2, 3],
        [1, 0, 1],
        [1, 2, 3],
        [2, 0, 3],
      ]);
    });

    test('the score is the overlap of drawn and basin cells, as worker/test/api.test.ts has it', () {
      const basin = [
        [2, 1, 4],
        [3, 1, 4],
      ];
      const rect = <GridPoint>[(row: 2, col: 2), (row: 2, col: 5), (row: 4, col: 5), (row: 4, col: 2)];
      // 4 cells in both, 8 in either.
      expect(runsOverlap(polygonRuns(rect), basin), 4);
      expect(basinScore(polygonRuns(rect), basin), 50);
      expect(basinScore(basin, basin), 100);
      // The basin from GRASS, drawn round on its own cell edges, is scored 100.
      final b = (expected['basins'] as List)[1] as Map<String, dynamic>;
      expect(basinScore(runsOf(b['runs']), runsOf(b['runs'])), 100);
    });

    test('the same cells and scores as worker/test/watershed.test.ts', () {
      final cases = (jsonDecode(File('$dir/scores.json').readAsStringSync()) as Map<String, dynamic>)['cases'] as List;
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final poly = [
          for (final p in c['poly'] as List) (row: ((p as List)[0] as num).toDouble(), col: (p[1] as num).toDouble()),
        ];
        expect(isSimplePolygon(poly), c['simple'], reason: c['note'] as String);
        if (c['simple'] != true) continue;
        final b = c['basin'];
        final basin = b is int ? runsOf(((expected['basins'] as List)[b] as Map)['runs']) : runsOf(b);
        final runs = polygonRuns(poly, maxRow: 120);
        expect(runCells(runs), c['cells'], reason: c['note'] as String);
        expect(runsOverlap(runs, basin), c['overlap'], reason: c['note'] as String);
        expect(basinScore(runs, basin), c['score'], reason: c['note'] as String);
      }
    });

    test('crossing and folded polygons are refused', () {
      const square = <GridPoint>[(row: 0, col: 0), (row: 0, col: 4), (row: 4, col: 4), (row: 4, col: 0)];
      const bowtie = <GridPoint>[(row: 0, col: 0), (row: 0, col: 4), (row: 4, col: 0), (row: 4, col: 4)];
      const folded = <GridPoint>[(row: 0, col: 0), (row: 0, col: 4), (row: 0, col: 2)];
      expect(isSimplePolygon(square), isTrue);
      expect(isSimplePolygon(bowtie), isFalse);
      expect(isSimplePolygon(folded), isFalse);
      expect(isSimplePolygon(square.sublist(0, 2)), isFalse);
    });

    test('grid points and map positions go both ways', () {
      const p = (row: 12.25, col: 40.5);
      final back = gridPointOf(grid, latLngOf(grid, p));
      expect(back.row, closeTo(p.row, 1e-6));
      expect(back.col, closeTo(p.col, 1e-6));
    });
  });

  group('geodesy', () {
    test('area and perimeter are PROJ geod’s (Karney) on WGS84', () {
      for (final p in (expected['polygons'] as List).cast<Map<String, dynamic>>()) {
        final pts = [
          for (final q in p['lonlat'] as List) LatLng(((q as List)[1] as num).toDouble(), (q[0] as num).toDouble()),
        ];
        final area = (p['area_m2'] as num).toDouble(), perimeter = (p['perimeter_m'] as num).toDouble();
        expect((geodesicArea(pts) - area).abs() / area, lessThan(5e-5), reason: 'area $area');
        expect((geodesicPerimeter(pts) - perimeter).abs() / perimeter, lessThan(1e-6), reason: 'perimeter $perimeter');
      }
    });

    test('the UTM scale factor is PROJ’s', () {
      for (final s in (expected['scale'] as List).cast<Map<String, dynamic>>()) {
        final ll = s['lonlat'] as List;
        final k = utmScale((ll[1] as num).toDouble(), (ll[0] as num).toDouble(), 38);
        expect(k, closeTo((s['k'] as num).toDouble(), 1e-9));
      }
    });

    test('a basin’s cells are its ground area', () {
      // The whole piece: its four corners as a polygon, against the cells it holds.
      final corners = grid.outline;
      final area = geodesicArea(corners);
      final cells = cellsArea(grid, grid.width * grid.height, corners.first);
      expect((cells - area).abs() / area, lessThan(2e-4));
    });
  });
}
