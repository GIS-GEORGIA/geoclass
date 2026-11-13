import 'dart:typed_data';

import 'elevation.dart';

/// What [viewshed] says about a cell.
const viewHidden = 0, viewSeen = 1, viewNone = 255;

/// GDAL's curvature coefficient for visible light (gdal_viewshed -cc default): the earth's curvature less
/// atmospheric refraction.
const viewCurvature = 0.85714;

/// WGS84 semi-major axis, the sphere GDAL takes from the area's UTM CRS.
const _sphereDiameter = 2 * 6378137.0;

/// The cells seen by an observer [observer] metres above the ground at cell [row], [col], with targets
/// [target] metres above theirs: one value per cell, rows north to south ([viewSeen], [viewHidden], or
/// [viewNone] where the grid has no data). Null when the observer's cell has no data.
///
/// This is `gdal_viewshed` (GDAL 3.8, alg/viewshed.cpp) step for step, in its default Edge mode with the whole
/// grid in range: the line through the observer first, then line by line away from it, each cell's sight
/// line height taken from the two cells between it and the observer, and heights lowered by
/// [curvature] × distance² / earth diameter. test/terrain_test.dart checks it against gdal_viewshed's output.
/// GDAL reads an empty cell as a height; it is given one far below the ground here, so it hides nothing.
Uint8List? viewshed(
  ElevationGrid g,
  int row,
  int col, {
  required double observer,
  double target = 0,
  double curvature = viewCurvature,
}) {
  final w = g.width, h = g.height;
  if (row < 0 || col < 0 || row >= h || col >= w) return null;
  final z = g.heights();
  if (z[row * w + col].isNaN) return null;
  final out = Uint8List(w * h);
  final cell2 = g.cell * g.cell;

  // Lowers a cell's height for its distance from the observer, as GDAL's AdjustHeightInRange does.
  double lowered(double v, int dx, int dy) =>
      curvature == 0 ? v : v - curvature * (dx * dx + dy * dy) * cell2 / _sphereDiameter;
  double line(int i, double za, double zo) => i == 1 ? za : (za - zo) / (i - 1) + za;
  double edge(int i, int j, double za, double zb, double zo) =>
      i == j ? line(i, za, zo) : ((za - zo) * i + (zb - zo) * (j - i)) / (j - 1) + zo;

  Float64List read(int r) {
    final v = Float64List(w);
    for (var c = 0; c < w; c++) {
      final x = z[r * w + c];
      v[c] = x.isNaN ? -9999.0 : x;
    }
    return v;
  }

  void see(int r, Float64List v, int c, double sight) {
    out[r * w + c] = v[c] + target < sight ? viewHidden : viewSeen;
    if (v[c] < sight) v[c] = sight;
  }

  final first = read(row);
  final zo = observer + first[col];
  out[row * w + col] = viewSeen;
  if (col > 0) {
    first[col - 1] = lowered(first[col - 1], 1, 0);
    out[row * w + col - 1] = viewSeen;
  }
  if (col < w - 1) {
    first[col + 1] = lowered(first[col + 1], 1, 0);
    out[row * w + col + 1] = viewSeen;
  }
  for (var c = col - 2; c >= 0; c--) {
    first[c] = lowered(first[c], col - c, 0);
    see(row, first, c, line(col - c, first[c + 1], zo));
  }
  for (var c = col + 2; c < w; c++) {
    first[c] = lowered(first[c], c - col, 0);
    see(row, first, c, line(c - col, first[c - 1], zo));
  }

  // Up the grid, then down it, each line from the one before.
  for (final step in const [-1, 1]) {
    var last = Float64List.fromList(first);
    for (var r = row + step; r >= 0 && r < h; r += step) {
      final v = read(r);
      final dy = (r - row).abs();
      v[col] = lowered(v[col], 0, dy);
      see(r, v, col, line(dy, last[col], zo));
      for (var c = col - 1; c >= 0; c--) {
        final dx = col - c;
        v[c] = lowered(v[c], dx, dy);
        see(r, v, c, dx >= dy ? edge(dy, dx, last[c + 1], v[c + 1], zo) : edge(dx, dy, last[c + 1], last[c], zo));
      }
      for (var c = col + 1; c < w; c++) {
        final dx = c - col;
        v[c] = lowered(v[c], dx, dy);
        see(r, v, c, dx >= dy ? edge(dy, dx, last[c - 1], v[c - 1], zo) : edge(dx, dy, last[c - 1], last[c], zo));
      }
      last = v;
    }
  }

  for (var i = 0; i < z.length; i++) {
    if (z[i].isNaN) out[i] = viewNone;
  }
  return out;
}

/// The cell under a UTM point, or null outside the grid.
({int row, int col})? cellAtUtm(ElevationGrid g, double x, double y) {
  if (!g.containsUtm(x, y)) return null;
  final col = ((x - g.meta.bounds[0]) / g.cell).floor().clamp(0, g.width - 1);
  final row = ((g.meta.bounds[3] - y) / g.cell).floor().clamp(0, g.height - 1);
  return (row: row, col: col);
}

/// Colour of the seen ground on the map (ARGB).
const viewSeenColour = 0xff00c853;

/// The viewshed as RGBA pixels, one per cell: seen ground green, the rest see-through.
Uint8List viewshedPixels(Uint8List seen) {
  final rgba = Uint8List(seen.length * 4);
  final words = rgba.buffer.asUint32List();
  const c = viewSeenColour;
  final abgr = 0xff000000 | (c & 0xff) << 16 | (c & 0xff00) | (c >> 16 & 0xff);
  for (var i = 0; i < seen.length; i++) {
    if (seen[i] == viewSeen) words[i] = abgr;
  }
  return rgba;
}
