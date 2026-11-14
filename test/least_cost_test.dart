import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/terrain/elevation.dart';
import 'package:geoclass/terrain/least_cost.dart';

void main() {
  const dir = 'test/fixtures/least_cost';
  final metaJson = jsonDecode(File('$dir/area.json').readAsStringSync()) as Map<String, dynamic>;
  final grid = ElevationGrid.fromBytes(AreaMeta.fromJson(metaJson), File('$dir/dem.u16').readAsBytesSync());
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final w = grid.width;
  int cell(Object? rc) => ((rc as List)[0] as int) * w + (rc[1] as int);
  final start = cell(expected['start']), end = cell(expected['end']);
  Float64List field(String name) => File('$dir/$name').readAsBytesSync().buffer.asFloat64List();
  final slopeModel = CostModel.slope((expected['theta'] as num).toDouble());
  // gdaldem's slope, which r.cost's costs were made from; and the app's own, which differs by under 0.001°.
  final gdalSlope = File('$dir/slope.f32').readAsBytesSync().buffer.asFloat32List();
  final slope = CostSurface(grid, slopeModel, slopes: gdalSlope);
  final ownSlope = CostSurface(grid, slopeModel);
  final tobler = CostSurface(grid, const CostModel.tobler());

  void sameField(Float64List mine, Float64List theirs, {double within = 1e-9}) {
    expect(mine.length, theirs.length);
    var worst = 0.0;
    for (var i = 0; i < mine.length; i++) {
      expect(mine[i].isNaN, theirs[i].isNaN, reason: 'cell $i reached by one only');
      if (mine[i].isNaN) continue;
      final gap = (mine[i] - theirs[i]).abs() / (theirs[i] < 1 ? 1 : theirs[i]);
      if (gap > worst) worst = gap;
    }
    expect(worst, lessThan(within));
  }

  test('slope model: the cumulative cost is GRASS r.cost’s, cell for cell', () {
    sameField(costField(slope, start).cost, field('slope_cost.f64'));
    // With the app's own slope (lib/terrain/slope.dart, gdaldem's method in double precision).
    sameField(costField(ownSlope, start).cost, field('slope_cost.f64'), within: 1e-4);
  });

  test('slope model: the route is r.drain’s, at its cost', () {
    final route = leastCostRoute(slope, start, end)!;
    final grass = [for (final rc in (expected['slope'] as Map)['path'] as List) cell(rc)];
    final want = ((expected['slope'] as Map)['cost'] as num).toDouble();
    expect(route.cost, closeTo(want, want * 1e-9));
    expect(routeCost(slope, grass), closeTo(want, want * 1e-9));
    expect(route.cells, grass);
  });

  test('Tobler model: the cumulative time is SciPy’s Dijkstra’s, cell for cell', () {
    sameField(costField(tobler, start).cost, field('tobler_cost.f64'));
    final route = leastCostRoute(tobler, start, end)!;
    final want = ((expected['tobler'] as Map)['cost'] as num).toDouble();
    expect(route.cost, closeTo(want, want * 1e-9));
    expect(routeCost(tobler, route.cells), closeTo(route.cost, 1e-9));
    // Uphill and downhill differ: the way back takes another time.
    final back = leastCostRoute(tobler, end, start)!;
    expect((back.cost - route.cost).abs(), greaterThan(1));
  });

  test('a drawn route: straight legs of neighbouring cells, costing no less than the best', () {
    expect(routeThrough([0, 3 * w + 5], w), [0, w + 1, w + 2, 2 * w + 3, 2 * w + 4, 3 * w + 5]);
    expect(routeThrough([5 * w + 5, 5 * w + 2, 5 * w + 2], w), [5 * w + 5, 5 * w + 4, 5 * w + 3, 5 * w + 2]);
    final drawn = routeThrough([start, 40 * w + 60, end], w);
    for (var k = 1; k < drawn.length; k++) {
      expect((drawn[k] ~/ w - drawn[k - 1] ~/ w).abs(), lessThanOrEqualTo(1));
      expect((drawn[k] % w - drawn[k - 1] % w).abs(), lessThanOrEqualTo(1));
    }
    final best = leastCostRoute(slope, start, end)!.cost;
    expect(routeCost(slope, drawn), greaterThan(best));
    // A jump, or a step onto the grid's edge (no slope there), can't be scored.
    expect(routeCost(slope, [start, start + 2]), isNull);
    expect(routeCost(slope, [w + 1, 1]), isNull);
    expect(routeCost(tobler, [w + 1, 1]), isNotNull);
  });

  test('steps go both ways; a route’s length, climb and steepest slope', () {
    final route = leastCostRoute(slope, start, end)!;
    final steps = stepsOf(route.cells, w);
    expect(steps.length, route.cells.length - 1);
    expect(RegExp(r'^[0-7]+$').hasMatch(steps), isTrue);
    expect(cellsOf(start, steps, w), route.cells);
    final stats = routeStats(slope, [w + 1, w + 2, 2 * w + 3]);
    expect(stats.length, closeTo(30 + 30 * 1.4142135623730951, 1e-9));
    final h = [grid.cellHeight(1, 1)!, grid.cellHeight(1, 2)!, grid.cellHeight(2, 3)!];
    expect(
      stats.climb,
      closeTo([for (var k = 1; k < 3; k++) (h[k] - h[k - 1]).clamp(0, 1e9)].reduce((a, b) => a + b), 1e-9),
    );
    expect(stats.steepest, greaterThan(0));
    expect(CostModel.fromJson(slopeModel.toJson()), slopeModel);
    expect(CostModel.fromJson(const CostModel.tobler().toJson()), const CostModel.tobler());
    expect(() => CostModel.fromJson({'kind': 'x'}), throwsFormatException);
  });

  test('fast enough on a whole area: Dijkstra over a 604 × 448 grid', () {
    // Kazbegi's size, made of the fixture repeated: the time on this machine, printed for the report.
    final b = (metaJson['bounds'] as List).cast<num>();
    final meta = AreaMeta.fromJson({
      ...metaJson,
      'width': 604,
      'height': 448,
      'id': 'big',
      'bounds': [b[0], b[3] - 448 * 30, b[0] + 604 * 30, b[3]],
    });
    final src = File('$dir/dem.u16').readAsBytesSync().buffer.asUint16List();
    final big = Uint16List(604 * 448);
    for (var r = 0; r < 448; r++) {
      for (var c = 0; c < 604; c++) {
        big[r * 604 + c] = src[(r % grid.height) * w + (c % w)];
      }
    }
    final g = ElevationGrid.fromBytes(meta, big.buffer.asUint8List());
    final s = CostSurface(g, slopeModel);
    final watch = Stopwatch()..start();
    final f = costField(s, 200 * 604 + 300);
    watch.stop();
    // ignore: avoid_print
    print('Dijkstra on 604 × 448: ${watch.elapsedMilliseconds} ms');
    expect(f.cost.where((v) => !v.isNaN).length, greaterThan(200000));
  });
}
