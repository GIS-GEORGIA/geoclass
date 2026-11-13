import 'dart:math' as math;
import 'dart:typed_data';

import 'elevation.dart';

/// Slope in degrees, as `gdaldem slope` makes it with its defaults: Horn's 3×3 window on the metric grid.
///
/// One value per cell, rows north to south. NaN where there is none: the grid's edge cells and any cell with
/// an empty cell in its window, as gdaldem leaves them without -compute_edges.
/// test/terrain_test.dart checks this against gdaldem's output.
Float32List slope(ElevationGrid g) {
  final w = g.width, h = g.height;
  final out = Float32List(w * h)..fillRange(0, w * h, double.nan);
  final inv = 1 / (8 * g.cell);
  const deg = 180 / math.pi;
  final z = g.heights();
  for (var r = 1; r < h - 1; r++) {
    for (var c = 1; c < w - 1; c++) {
      final i = r * w + c;
      final a = z[i - w - 1], b = z[i - w], cc = z[i - w + 1];
      final d = z[i - 1], e = z[i], f = z[i + 1];
      final gg = z[i + w - 1], hh = z[i + w], ii = z[i + w + 1];
      if ((a + b + cc + d + e + f + gg + hh + ii).isNaN) continue;
      final dx = ((cc + 2 * f + ii) - (a + 2 * d + gg)) * inv;
      final dy = ((gg + 2 * hh + ii) - (a + 2 * b + cc)) * inv;
      out[i] = math.atan(math.sqrt(dx * dx + dy * dy)) * deg;
    }
  }
  return out;
}

final _slopes = Expando<Float32List>('slope');

/// [slope] of a grid, worked out once and kept with it: the map's overlay and a game share it.
Float32List slopeOf(ElevationGrid g) => _slopes[g] ??= slope(g);

/// The slope classes of the overlay, as their lower bounds in degrees: 0–5°, 5–15°, 15–30°, over 30°.
const slopeClasses = [0, 5, 15, 30];

/// The class of a slope: 0 to 3, or -1 where there is none.
int slopeClass(double degrees) => degrees.isNaN
    ? -1
    : degrees < 5
    ? 0
    : degrees < 15
    ? 1
    : degrees < 30
    ? 2
    : 3;

/// One colour per class (ARGB), from flat to steep: green, yellow, orange, red.
const slopeColours = [0xff4caf50, 0xffffeb3b, 0xffff9800, 0xffd32f2f];

/// The slope overlay as RGBA pixels, one per cell; see-through where there is no slope.
Uint8List slopePixels(Float32List degrees) {
  final rgba = Uint8List(degrees.length * 4);
  // Bytes R, G, B, A in memory are one little-endian word: A << 24 | B << 16 | G << 8 | R.
  final words = rgba.buffer.asUint32List();
  final abgr = [for (final c in slopeColours) 0xff000000 | (c & 0xff) << 16 | (c & 0xff00) | (c >> 16 & 0xff)];
  for (var i = 0; i < degrees.length; i++) {
    final k = slopeClass(degrees[i]);
    if (k >= 0) words[i] = abgr[k];
  }
  return rgba;
}
