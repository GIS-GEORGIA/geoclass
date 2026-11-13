import 'dart:math' as math;
import 'dart:typed_data';

import 'elevation.dart';

/// Shaded relief, as `gdaldem hillshade` makes it with its defaults: Horn's slope from the 3×3 window,
/// light from [azimuth]° (clockwise from north) at [altitude]° above the horizon.
///
/// One byte per cell, rows north to south: 1 (dark) to 255 (lit). 0 means no shade: the grid's edge cells
/// and any cell with an empty cell in its window, as gdaldem leaves them without -compute_edges.
/// test/terrain_test.dart checks this against gdaldem's output.
Uint8List hillshade(ElevationGrid g, {double azimuth = 315, double altitude = 45, double zFactor = 1}) {
  final w = g.width, h = g.height;
  final out = Uint8List(w * h);
  const rad = math.pi / 180;
  final az = azimuth * rad, alt = altitude * rad;
  final sinAlt = math.sin(alt);
  final cosAzCosAltZ = math.cos(az) * math.cos(alt) * zFactor;
  final sinAzCosAltZ = math.sin(az) * math.cos(alt) * zFactor;
  final squareZ = zFactor * zFactor;
  final inv = 1 / (8 * g.cell);

  final z = g.heights();

  for (var r = 1; r < h - 1; r++) {
    for (var c = 1; c < w - 1; c++) {
      final i = r * w + c;
      final a = z[i - w - 1], b = z[i - w], cc = z[i - w + 1];
      final d = z[i - 1], e = z[i], f = z[i + 1];
      final gg = z[i + w - 1], hh = z[i + w], ii = z[i + w + 1];
      if ((a + b + cc + d + e + f + gg + hh + ii).isNaN) continue;
      // West minus east, and north minus south: the same signs as gdaldem's result.
      final x = ((a + 2 * d + gg) - (cc + 2 * f + ii)) * inv;
      final y = ((a + 2 * b + cc) - (gg + 2 * hh + ii)) * inv;
      final cang = (sinAlt - (y * cosAzCosAltZ - x * sinAzCosAltZ)) / math.sqrt(1 + squareZ * (x * x + y * y));
      final v = cang <= 0 ? 1.0 : 1 + 254 * cang;
      out[i] = v.round().clamp(1, 255);
    }
  }
  return out;
}
