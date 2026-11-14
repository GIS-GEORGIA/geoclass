import 'dart:math' as math;
import 'dart:typed_data';

import 'elevation.dart';
import 'slope.dart';

/// Least-cost routes over an area's grid, moving cell to cell (8 neighbours). Two cost models:
///
///   slope   each cell costs 1 + (slope / θ)² per metre (slope from [slopeOf], gdaldem's Horn method); a move
///           costs the mean of the two cells' costs times its length (30 m, diagonally 30 m × √2). As GRASS
///           r.cost counts it: test/least_cost_test.dart checks the cumulative cost against r.cost and the
///           route against r.drain. Cells without a slope (the grid's edge, gaps) can't be crossed.
///   tobler  a move takes length / v minutes, v = 6·exp(−3.5·|dh / length + 0.05|) km/h (Tobler's hiking
///           function), so going up and coming down differ. Checked against SciPy's Dijkstra, since GRASS and
///           GDAL have no such tool. Cells without a height can't be crossed.
///
/// worker/src/games/least_cost.ts adds up the cost of a route the same way, to score it.
class CostModel {
  /// 'slope' or 'tobler'.
  final String kind;

  /// The slope model's θ in degrees: a slope of θ makes a cell cost twice a flat one.
  final double theta;

  const CostModel.slope(this.theta) : kind = 'slope';
  const CostModel.tobler() : kind = 'tobler', theta = 0;

  bool get isSlope => kind == 'slope';

  factory CostModel.fromJson(Map<String, dynamic> j) => switch (j['kind']) {
    'slope' => CostModel.slope((j['theta'] as num).toDouble()),
    'tobler' => const CostModel.tobler(),
    _ => throw const FormatException('bad cost model'),
  };

  Map<String, dynamic> toJson() => {'kind': kind, if (isSlope) 'theta': theta};

  @override
  bool operator ==(Object other) => other is CostModel && other.kind == kind && other.theta == theta;
  @override
  int get hashCode => Object.hash(kind, theta);
}

/// The θ a teacher can pick, as the server allows them.
const costThetas = [10.0, 15.0, 20.0];

/// Moves to the eight neighbours, as (row, col) offsets; a route's steps are sent as indices into this list.
const costSteps = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)];

/// What a move costs on one grid under one model.
class CostSurface {
  final ElevationGrid grid;
  final CostModel model;

  /// Heights (NaN where none), and for the slope model each cell's cost per metre (NaN where it can't be crossed).
  final Float64List _heights, _cellCost;

  CostSurface._(this.grid, this.model, this._heights, this._cellCost);

  /// [slopes] stands in for [slopeOf] in tests, to cost the same slope as a reference tool.
  factory CostSurface(ElevationGrid g, CostModel model, {Float32List? slopes}) {
    final n = g.width * g.height;
    final heights = Float64List(n);
    for (var i = 0; i < n; i++) {
      heights[i] = g.cellHeight(i ~/ g.width, i % g.width) ?? double.nan;
    }
    final cost = Float64List(model.isSlope ? n : 0);
    if (model.isSlope) {
      final s = slopes ?? slopeOf(g);
      for (var i = 0; i < n; i++) {
        final t = s[i] / model.theta;
        cost[i] = 1 + t * t; // NaN stays NaN
      }
    }
    return CostSurface._(g, model, heights, cost);
  }

  int get width => grid.width;
  int get height => grid.height;

  /// Whether a route may stand on cell [i].
  bool passable(int i) => model.isSlope ? !_cellCost[i].isNaN : !_heights[i].isNaN;

  /// The cost of the move from cell [a] to its neighbour [b], [diagonal] or not; NaN where it can't be made.
  double move(int a, int b, bool diagonal) {
    final d = diagonal ? grid.cell * math.sqrt2 : grid.cell;
    if (model.isSlope) return (_cellCost[a] + _cellCost[b]) / 2 * d;
    final v = 6 * math.exp(-3.5 * ((_heights[b] - _heights[a]) / d + 0.05).abs()); // km/h
    return d / (v * 1000 / 60); // minutes
  }

  double heightOf(int i) => _heights[i];
}

/// The cumulative cost from [start] to every cell (NaN where it can't be reached), and for each cell the cell
/// it is reached from (-1 for the start and unreached cells). Dijkstra's algorithm with a binary heap.
({Float64List cost, Int32List from}) costField(CostSurface s, int start) {
  final n = s.width * s.height, w = s.width;
  final cost = Float64List(n)..fillRange(0, n, double.infinity);
  final from = Int32List(n)..fillRange(0, n, -1);
  final done = Uint8List(n);
  final heap = _Heap();
  if (!s.passable(start)) {
    cost.fillRange(0, n, double.nan);
    return (cost: cost, from: from);
  }
  cost[start] = 0;
  heap.push(0, start);
  while (heap.isNotEmpty) {
    final (c, i) = heap.pop();
    if (done[i] != 0 || c > cost[i]) continue;
    done[i] = 1;
    final r = i ~/ w, col = i % w;
    for (final (dr, dc) in costSteps) {
      final nr = r + dr, nc = col + dc;
      if (nr < 0 || nc < 0 || nr >= s.height || nc >= w) continue;
      final j = nr * w + nc;
      if (done[j] != 0 || !s.passable(j)) continue;
      final next = c + s.move(i, j, dr != 0 && dc != 0);
      if (next < cost[j]) {
        cost[j] = next;
        from[j] = i;
        heap.push(next, j);
      }
    }
  }
  for (var i = 0; i < n; i++) {
    if (cost[i] == double.infinity) cost[i] = double.nan;
  }
  return (cost: cost, from: from);
}

/// The least-cost route from [start] to [end] as cells, start first, and its cost; null when there is none.
({List<int> cells, double cost})? leastCostRoute(CostSurface s, int start, int end) {
  final f = costField(s, start);
  if (f.cost[end].isNaN) return null;
  final cells = <int>[end];
  while (cells.last != start) {
    cells.add(f.from[cells.last]);
  }
  return (cells: cells.reversed.toList(), cost: f.cost[end]);
}

/// The cells of a route through [vertices] (cell indices), each leg a straight line of 8-connected cells
/// (Bresenham), as worker/src/games/least_cost.ts draws it.
List<int> routeThrough(List<int> vertices, int width) {
  final out = <int>[];
  for (var k = 0; k < vertices.length; k++) {
    if (k == 0) {
      out.add(vertices[0]);
      continue;
    }
    var r = vertices[k - 1] ~/ width, c = vertices[k - 1] % width;
    final r1 = vertices[k] ~/ width, c1 = vertices[k] % width;
    final dr = (r1 - r).abs(), dc = (c1 - c).abs();
    final sr = r1 > r ? 1 : -1, sc = c1 > c ? 1 : -1;
    var err = dc - dr;
    while (r != r1 || c != c1) {
      final e2 = 2 * err;
      if (e2 > -dr) {
        err -= dr;
        c += sc;
      }
      if (e2 < dc) {
        err += dc;
        r += sr;
      }
      out.add(r * width + c);
    }
  }
  return out;
}

/// The cost of a route given as cells, each a neighbour of the one before (a cell repeated is no move); null
/// when it crosses a cell that can't be crossed or makes a jump.
double? routeCost(CostSurface s, List<int> cells) {
  if (cells.isEmpty || !s.passable(cells.first)) return null;
  var sum = 0.0;
  for (var k = 1; k < cells.length; k++) {
    final a = cells[k - 1], b = cells[k];
    if (a == b) continue;
    final dr = b ~/ s.width - a ~/ s.width, dc = b % s.width - a % s.width;
    if (dr.abs() > 1 || dc.abs() > 1 || !s.passable(b)) return null;
    sum += s.move(a, b, dr != 0 && dc != 0);
  }
  return sum;
}

/// A route's steps as one digit per move, an index into [costSteps]: how the teacher's app sends its route.
String stepsOf(List<int> cells, int width) {
  final out = StringBuffer();
  for (var k = 1; k < cells.length; k++) {
    final dr = cells[k] ~/ width - cells[k - 1] ~/ width, dc = cells[k] % width - cells[k - 1] % width;
    out.write(costSteps.indexOf((dr, dc)));
  }
  return out.toString();
}

/// The cells of a route from its start and [stepsOf].
List<int> cellsOf(int start, String steps, int width) {
  final out = [start];
  for (var k = 0; k < steps.length; k++) {
    final (dr, dc) = costSteps[steps.codeUnitAt(k) - 48];
    out.add(out.last + dr * width + dc);
  }
  return out;
}

/// A route's length on the grid in metres, its climb (the sum of the rises) in metres, and its steepest cell's
/// slope in degrees.
({double length, double climb, double steepest}) routeStats(CostSurface s, List<int> cells) {
  final slopes = slopeOf(s.grid);
  var length = 0.0, climb = 0.0, steepest = 0.0;
  for (var k = 0; k < cells.length; k++) {
    final sl = slopes[cells[k]];
    if (!sl.isNaN && sl > steepest) steepest = sl;
    if (k == 0 || cells[k] == cells[k - 1]) continue;
    final a = cells[k - 1], b = cells[k];
    length += (a ~/ s.width != b ~/ s.width && a % s.width != b % s.width) ? s.grid.cell * math.sqrt2 : s.grid.cell;
    final rise = s.heightOf(b) - s.heightOf(a);
    if (rise > 0) climb += rise;
  }
  return (length: length, climb: climb, steepest: steepest);
}

/// A min-heap of (cost, cell).
class _Heap {
  final _cost = <double>[];
  final _cell = <int>[];

  bool get isNotEmpty => _cost.isNotEmpty;

  void push(double c, int i) {
    _cost.add(c);
    _cell.add(i);
    var k = _cost.length - 1;
    while (k > 0) {
      final p = (k - 1) >> 1;
      if (_cost[p] <= c) break;
      _cost[k] = _cost[p];
      _cell[k] = _cell[p];
      k = p;
    }
    _cost[k] = c;
    _cell[k] = i;
  }

  (double, int) pop() {
    final top = (_cost[0], _cell[0]);
    final c = _cost.removeLast(), i = _cell.removeLast();
    if (_cost.isNotEmpty) {
      var k = 0;
      final n = _cost.length;
      while (true) {
        var m = 2 * k + 1;
        if (m >= n) break;
        if (m + 1 < n && _cost[m + 1] < _cost[m]) m++;
        if (_cost[m] >= c) break;
        _cost[k] = _cost[m];
        _cell[k] = _cell[m];
        k = m;
      }
      _cost[k] = c;
      _cell[k] = i;
    }
    return top;
  }
}
