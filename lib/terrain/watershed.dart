import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../coords.dart';
import 'elevation.dart';

/// Where water leaves each cell: tool/areas/build_watershed.py's flow.u8.gz, made by GRASS r.watershed -s
/// (single flow direction, D8). One byte per cell, rows north to south: 0 north-east, 1 north, 2 north-west,
/// 3 west, 4 south-west, 5 south, 6 south-east, 7 east; [flowNone] where water leaves the area.
const flowNone = 255;
const flowOffsets = [(-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1)];

class FlowGrid {
  final int width, height;
  final Uint8List dirs;

  /// Upstream cells that make a stream on the map (watershed.json's stream_cells).
  final int streamCells;

  FlowGrid(this.width, this.height, this.dirs, {this.streamCells = 1112}) {
    if (dirs.length != width * height) {
      throw FormatException('flow grid has ${dirs.length} cells, expected ${width * height}');
    }
  }

  /// The cell water goes to from cell [i], or -1 where it leaves the area.
  int downstream(int i) {
    final k = dirs[i];
    if (k >= 8) return -1;
    final (dr, dc) = flowOffsets[k];
    final r = i ~/ width + dr, c = i % width + dc;
    if (r < 0 || c < 0 || r >= height || c >= width) return -1;
    return r * width + c;
  }
}

/// How many cells drain through each cell, itself included: the flow accumulation, from the directions
/// alone. For an outlet, this is the size of its basin (test/watershed_test.dart checks it against GRASS
/// r.water.outlet). GRASS's own accumulation leaves out some of what crosses the area's edge.
Int32List accumulation(FlowGrid f) {
  final n = f.width * f.height;
  final into = Int32List(n);
  final down = Int32List(n);
  for (var i = 0; i < n; i++) {
    final t = f.downstream(i);
    down[i] = t;
    if (t >= 0) into[t]++;
  }
  final acc = Int32List(n)..fillRange(0, n, 1);
  final stack = <int>[
    for (var i = 0; i < n; i++)
      if (into[i] == 0) i,
  ];
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final t = down[i];
    if (t < 0) continue;
    acc[t] += acc[i];
    if (--into[t] == 0) stack.add(t);
  }
  return acc;
}

/// The basin of cell [row], [col]: every cell whose water passes through it, as 1 in a mask of the grid.
Uint8List basinMask(FlowGrid f, int row, int col) {
  final w = f.width, h = f.height;
  final mask = Uint8List(w * h);
  final start = row * w + col;
  mask[start] = 1;
  final stack = [start];
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final r = i ~/ w, c = i % w;
    for (var k = 0; k < 8; k++) {
      // The neighbour in direction k flows here when its own direction is the opposite one.
      final (dr, dc) = flowOffsets[k];
      final nr = r + dr, nc = c + dc;
      if (nr < 0 || nc < 0 || nr >= h || nc >= w) continue;
      final j = nr * w + nc;
      if (mask[j] == 0 && f.dirs[j] == (k + 4) % 8) {
        mask[j] = 1;
        stack.add(j);
      }
    }
  }
  return mask;
}

/// Whether a mask reaches the grid's edge: a basin that does is cut off by it, and its true divide is unknown.
bool touchesEdge(Uint8List mask, int width, int height) {
  for (var c = 0; c < width; c++) {
    if (mask[c] != 0 || mask[(height - 1) * width + c] != 0) return true;
  }
  for (var r = 0; r < height; r++) {
    if (mask[r * width] != 0 || mask[r * width + width - 1] != 0) return true;
  }
  return false;
}

/// A mask as runs along its rows: [row, first column, end column (exclusive)], rows north to south.
List<List<int>> maskRuns(Uint8List mask, int width) {
  final out = <List<int>>[];
  for (var r = 0; r * width < mask.length; r++) {
    var c = 0;
    while (c < width) {
      if (mask[r * width + c] == 0) {
        c++;
        continue;
      }
      final start = c;
      while (c < width && mask[r * width + c] != 0) {
        c++;
      }
      out.add([r, start, c]);
    }
  }
  return out;
}

/// The inverse of [maskRuns].
Uint8List runsMask(List<List<int>> runs, int width, int height) {
  final mask = Uint8List(width * height);
  for (final run in runs) {
    mask.fillRange(run[0] * width + run[1], run[0] * width + run[2], 1);
  }
  return mask;
}

/// The stream cell nearest a touch: of the cells within [radius] cells of [row], [col] that carry at least
/// [minCells] (the area's stream threshold by default), the closest, and of equally close ones the one with the
/// most water. A touch beside a tributary finds the tributary, not the river further off.
({int row, int col})? snapToStream(FlowGrid f, Int32List acc, int row, int col, {int radius = 15, int? minCells}) {
  final least = minCells ?? f.streamCells;
  var best = -1, bestD = 1 << 30, bestAcc = 0;
  for (var r = math.max(0, row - radius); r <= math.min(f.height - 1, row + radius); r++) {
    for (var c = math.max(0, col - radius); c <= math.min(f.width - 1, col + radius); c++) {
      final a = acc[r * f.width + c];
      final d = (r - row) * (r - row) + (c - col) * (c - col);
      if (a < least || d > radius * radius) continue;
      if (d < bestD || (d == bestD && a > bestAcc)) {
        best = r * f.width + c;
        bestD = d;
        bestAcc = a;
      }
    }
  }
  return best < 0 ? null : (row: best ~/ f.width, col: best % f.width);
}

/// Colour of the streams on the map (ARGB), and of a basin.
const streamColour = 0xff1565c0, basinColour = 0xff00897b;

/// Cells with at least [threshold] upstream cells, as RGBA pixels: streams blue, the rest see-through.
Uint8List streamPixels(Int32List acc, int threshold) => _pixels(acc.length, (i) => acc[i] >= threshold, streamColour);

/// A mask as RGBA pixels in [colour].
Uint8List maskPixels(Uint8List mask, {int colour = basinColour}) => _pixels(mask.length, (i) => mask[i] != 0, colour);

Uint8List _pixels(int n, bool Function(int i) on, int colour) {
  final rgba = Uint8List(n * 4);
  final words = rgba.buffer.asUint32List();
  final abgr = 0xff000000 | (colour & 0xff) << 16 | (colour & 0xff00) | (colour >> 16 & 0xff);
  for (var i = 0; i < n; i++) {
    if (on(i)) words[i] = abgr;
  }
  return rgba;
}

/// A point in grid units: [row] down from the north edge, [col] east from the west edge; cell (r, c) spans
/// r..r+1 and c..c+1, its centre at r + 0.5, c + 0.5.
typedef GridPoint = ({double row, double col});

GridPoint gridPointOf(ElevationGrid g, LatLng p) {
  final u = toUtm(p.latitude, p.longitude, zone: g.meta.zone);
  return (row: (g.meta.bounds[3] - u.northing) / g.cell, col: (u.easting - g.meta.bounds[0]) / g.cell);
}

LatLng latLngOf(ElevationGrid g, GridPoint p) =>
    fromUtm(g.meta.zone, g.meta.bounds[0] + p.col * g.cell, g.meta.bounds[3] - p.row * g.cell);

/// The cells of a polygon (grid units) as runs along their rows, as worker/src/games/watershed.ts makes them:
/// a cell is inside when its centre is (even–odd rule). Rows from 0 to [maxRow] only.
List<List<int>> polygonRuns(List<GridPoint> poly, {int maxRow = 4000}) {
  final out = <List<int>>[];
  if (poly.length < 3) return out;
  var top = double.infinity, bottom = -double.infinity;
  for (final p in poly) {
    top = math.min(top, p.row);
    bottom = math.max(bottom, p.row);
  }
  final r0 = math.max(0, (top - 0.5).ceil()), r1 = math.min(maxRow - 1, (bottom - 0.5).floor());
  for (var r = r0; r <= r1; r++) {
    final y = r + 0.5;
    final xs = <double>[];
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      if ((a.row <= y && y < b.row) || (b.row <= y && y < a.row)) {
        xs.add(a.col + (y - a.row) * (b.col - a.col) / (b.row - a.row));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final c0 = (xs[k] - 0.5).ceil(), c1 = (xs[k + 1] - 0.5).ceil();
      if (c1 > c0) out.add([r, c0, c1]);
    }
  }
  return out;
}

/// Cells in runs.
int runCells(List<List<int>> runs) => runs.fold(0, (n, r) => n + r[2] - r[1]);

/// Cells in both sets of runs (each sorted by row, then column, with no overlaps).
int runsOverlap(List<List<int>> a, List<List<int>> b) {
  var i = 0, j = 0, both = 0;
  while (i < a.length && j < b.length) {
    final x = a[i], y = b[j];
    if (x[0] != y[0]) {
      x[0] < y[0] ? i++ : j++;
      continue;
    }
    both += math.max(0, math.min(x[2], y[2]) - math.max(x[1], y[1]));
    x[2] < y[2] ? i++ : j++;
  }
  return both;
}

/// The score the server gives: intersection over union of the drawn cells and the basin's, × 100.
int basinScore(List<List<int>> drawn, List<List<int>> basin) {
  final both = runsOverlap(drawn, basin);
  final either = runCells(drawn) + runCells(basin) - both;
  return either == 0 ? 0 : (100 * both / either).round();
}

/// Whether no two edges of a closed polygon cross or touch, other than neighbours at their shared corner.
bool isSimplePolygon(List<GridPoint> p) {
  final n = p.length;
  if (n < 3) return false;
  double cross(GridPoint o, GridPoint a, GridPoint b) =>
      (a.col - o.col) * (b.row - o.row) - (a.row - o.row) * (b.col - o.col);
  bool onSegment(GridPoint a, GridPoint b, GridPoint q) =>
      math.min(a.col, b.col) <= q.col &&
      q.col <= math.max(a.col, b.col) &&
      math.min(a.row, b.row) <= q.row &&
      q.row <= math.max(a.row, b.row);
  bool meet(GridPoint a, GridPoint b, GridPoint c, GridPoint d) {
    final d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
    return (d1 == 0 && onSegment(c, d, a)) ||
        (d2 == 0 && onSegment(c, d, b)) ||
        (d3 == 0 && onSegment(a, b, c)) ||
        (d4 == 0 && onSegment(a, b, d));
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (j == i + 1 || (i == 0 && j == n - 1)) continue; // neighbours share a corner
      if (meet(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n])) return false;
    }
  }
  // Neighbouring edges folding back on themselves.
  for (var i = 0; i < n; i++) {
    final a = p[i], b = p[(i + 1) % n], c = p[(i + 2) % n];
    if (cross(a, b, c) == 0 && (onSegment(a, b, c) || onSegment(b, c, a))) return false;
  }
  return true;
}

// WGS84.
const _a = 6378137.0, _f = 1 / 298.257223563;
const _e2 = _f * (2 - _f);
final _e = math.sqrt(_e2);
const _rad = math.pi / 180;

double _q(double sinPhi) =>
    (1 - _e2) * (sinPhi / (1 - _e2 * sinPhi * sinPhi) - math.log((1 - _e * sinPhi) / (1 + _e * sinPhi)) / (2 * _e));

/// The area of a polygon on the WGS84 ellipsoid in square metres: its corners projected to the Lambert
/// azimuthal equal-area projection of the ellipsoid (Snyder, Map Projections, 1987, pp. 187–190) centred on
/// the polygon, then the plane formula. Equal-area, so for polygons a few tens of kilometres across this is the
/// geodesic area to a few parts in a hundred thousand (test/watershed_test.dart checks it against PROJ's geod).
double geodesicArea(List<LatLng> poly) {
  if (poly.length < 3) return 0;
  final lat1 = poly.map((p) => p.latitude).reduce((a, b) => a + b) / poly.length * _rad;
  final lon0 = poly.map((p) => p.longitude).reduce((a, b) => a + b) / poly.length * _rad;
  final qp = _q(1);
  final rq = _a * math.sqrt(qp / 2);
  final beta1 = math.asin(_q(math.sin(lat1)) / qp);
  final m1 = math.cos(lat1) / math.sqrt(1 - _e2 * math.sin(lat1) * math.sin(lat1));
  final d = _a * m1 / (rq * math.cos(beta1));
  final xs = <double>[], ys = <double>[];
  for (final p in poly) {
    final beta = math.asin(_q(math.sin(p.latitude * _rad)) / qp);
    final dl = p.longitude * _rad - lon0;
    final b =
        rq * math.sqrt(2 / (1 + math.sin(beta1) * math.sin(beta) + math.cos(beta1) * math.cos(beta) * math.cos(dl)));
    xs.add(b * d * math.cos(beta) * math.sin(dl));
    ys.add(b / d * (math.cos(beta1) * math.sin(beta) - math.sin(beta1) * math.cos(beta) * math.cos(dl)));
  }
  var sum = 0.0;
  for (var i = 0; i < xs.length; i++) {
    final j = (i + 1) % xs.length;
    sum += xs[i] * ys[j] - xs[j] * ys[i];
  }
  return sum.abs() / 2;
}

/// The perimeter of a closed polygon in metres: the geodesic length of each side on WGS84.
double geodesicPerimeter(List<LatLng> poly) {
  if (poly.length < 2) return 0;
  const geodesic = Vincenty();
  var sum = 0.0;
  for (var i = 0; i < poly.length; i++) {
    sum += geodesic.distance(poly[i], poly[(i + 1) % poly.length]);
  }
  return sum;
}

/// The UTM point scale factor at a place (Snyder, p. 61): how much longer a short line is on the grid than
/// on the ellipsoid. A grid cell of side s covers (s / k)² of ground.
double utmScale(double lat, double lon, int zone) {
  const k0 = 0.9996;
  final ep2 = _e2 / (1 - _e2);
  final phi = lat * _rad;
  final a = (lon - (zone * 6 - 183)) * _rad * math.cos(phi);
  final t = math.pow(math.tan(phi), 2).toDouble();
  final c = ep2 * math.pow(math.cos(phi), 2);
  final a2 = a * a;
  return k0 *
      (1 +
          (1 + c) * a2 / 2 +
          (5 - 4 * t + 42 * c + 13 * c * c - 28 * ep2) * a2 * a2 / 24 +
          (61 - 148 * t + 16 * t * t) * a2 * a2 * a2 / 720);
}

/// The ground area of [cells] grid cells around [at], in square metres.
double cellsArea(ElevationGrid g, int cells, LatLng at) {
  final k = utmScale(at.latitude, at.longitude, g.meta.zone);
  return cells * g.cell * g.cell / (k * k);
}

/// The way a drop of water takes from cell [row], [col]: the cells from there down the D8 directions, in order,
/// until the water leaves the area. As GRASS r.drain -d follows r.watershed's directions
/// (test/watershed_test.dart checks the cells against it). Never longer than the grid has cells.
List<int> flowPath(FlowGrid f, int row, int col) {
  final out = <int>[];
  final n = f.width * f.height;
  var i = row * f.width + col;
  while (i >= 0 && out.length < n) {
    out.add(i);
    i = f.downstream(i);
  }
  return out;
}

/// The flow accumulation on a log scale, as RGBA pixels: cells with one or a few upstream cells pale and
/// see-through, the rivers dark blue. Log, because the rivers carry thousands of times more than the hillsides.
/// Premultiplied by alpha, as the engine takes raw pixels; opaque streams need no such care.
Uint8List accumulationPixels(Int32List acc) {
  var most = 1;
  for (final a in acc) {
    if (a > most) most = a;
  }
  final top = math.log(most);
  final rgba = Uint8List(acc.length * 4);
  for (var i = 0; i < acc.length; i++) {
    final t = top == 0 ? 0.0 : math.log(acc[i]) / top;
    // From pale cyan (0xb3e5fc) to dark blue (0x0d47a1).
    final alpha = 40 + 215 * t;
    rgba[i * 4] = ((0xb3 + (0x0d - 0xb3) * t) * alpha / 255).round();
    rgba[i * 4 + 1] = ((0xe5 + (0x47 - 0xe5) * t) * alpha / 255).round();
    rgba[i * 4 + 2] = ((0xfc + (0xa1 - 0xfc) * t) * alpha / 255).round();
    rgba[i * 4 + 3] = alpha.round();
  }
  return rgba;
}

/// The stream threshold slider: a position from 0 to 1 to upstream cells, on a log scale from [low] to
/// [high] cells, and back.
int thresholdAt(double t, {int low = 10, int high = 100000}) =>
    (low * math.pow(high / low, t.clamp(0, 1))).round();
double thresholdPosition(int cells, {int low = 10, int high = 100000}) =>
    (math.log(cells.clamp(low, high) / low) / math.log(high / low)).toDouble();
