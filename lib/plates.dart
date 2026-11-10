import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An outline hidden in a colour plate: a continent or a country, in a [-1, 1] box, y down.
class PlateShape {
  final String id, ka, en, group;
  final List<List<Offset>> polys;
  const PlateShape(this.id, this.ka, this.en, this.group, this.polys);

  String label(String lang) => lang == 'en' ? en : ka;

  factory PlateShape.fromJson(Map<String, dynamic> j) => PlateShape(
    j['id'] as String,
    j['ka'] as String,
    j['en'] as String,
    j['group'] as String,
    [
      for (final p in j['polys'] as List)
        [for (final xy in p as List) Offset(((xy as List)[0] as num).toDouble(), (xy[1] as num).toDouble())],
    ],
  );

  /// Even-odd test over every part: countries that touch are filled as one.
  bool contains(Offset point) {
    var inside = false;
    for (final ring in polys) {
      for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        final a = ring[i], b = ring[j];
        if ((a.dy > point.dy) != (b.dy > point.dy) && point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
          inside = !inside;
        }
      }
    }
    return inside;
  }
}

List<PlateShape> parsePlateShapes(String json) => [
  for (final s in jsonDecode(json) as List) PlateShape.fromJson(s as Map<String, dynamic>),
];

Future<List<PlateShape>>? _loading;

/// Built by tool/build_plates.mjs from Natural Earth.
Future<List<PlateShape>> loadPlateShapes() =>
    _loading ??= rootBundle.loadString('assets/plates.json').then(parsePlateShapes);

/// The two sets of colours of a plate: the figure's and the background's, of about the same lightness,
/// so the figure shows only by its hue.
class PlatePalette {
  final String id;
  final List<Color> figure, background;
  const PlatePalette(this.id, this.figure, this.background);
}

const platePalettes = [
  // Red and green: the pair most people with a colour vision deficiency confuse.
  PlatePalette(
    'red_green',
    [Color(0xFFE5835C), Color(0xFFD9704E), Color(0xFFEE9A6A), Color(0xFFE07B62), Color(0xFFF0A87C)],
    [Color(0xFF9DAF5C), Color(0xFF8DA35A), Color(0xFFB2BC6A), Color(0xFFA3B76F), Color(0xFF94AE66)],
  ),
  // Pink on grey violet, like the printed sheet.
  PlatePalette(
    'pink_violet',
    [Color(0xFFE180AA), Color(0xFFED96BA), Color(0xFFD46A97), Color(0xFFE68CB0)],
    [Color(0xFFAB9EB4), Color(0xFF9F90A8), Color(0xFFBBAEC3), Color(0xFFA594AE)],
  ),
  // Blue and violet: harder for the rarer, blue-yellow kind.
  PlatePalette(
    'blue_violet',
    [Color(0xFF759BD3), Color(0xFF85AADB), Color(0xFF688EC8), Color(0xFF91B2DF)],
    [Color(0xFFB494C8), Color(0xFFA987BF), Color(0xFFC0A3D2), Color(0xFFAE91C3)],
  ),
];

class PlateDot {
  final Offset center; // in the plate's unit circle
  final double radius;
  final Color color;
  final bool figure;
  const PlateDot(this.center, this.radius, this.color, this.figure);
}

/// How much of the plate's radius the outline may take.
const _figureSize = 0.72;

/// Dots of different sizes packed into a circle. The same seed always makes the same plate.
List<PlateDot> makePlate(PlateShape shape, PlatePalette palette, int seed, {int tries = 14000}) {
  final r = Random(seed);
  const minR = 0.011, maxR = 0.03, gap = 0.004;
  const cell = 2 * maxR + gap;
  final grid = <int, List<int>>{};
  final dots = <PlateDot>[];
  int key(int x, int y) => x * 1000 + y;

  for (var i = 0; i < tries; i++) {
    // Big dots first, then smaller ones fill the gaps, as on printed plates.
    final progress = i / tries;
    final radius = minR + (maxR - minR) * pow(r.nextDouble(), 1 + 3 * progress);
    final angle = r.nextDouble() * 2 * pi;
    final dist = sqrt(r.nextDouble()) * (1 - radius);
    final c = Offset(cos(angle) * dist, sin(angle) * dist);
    final gx = ((c.dx + 1) / cell).floor(), gy = ((c.dy + 1) / cell).floor();
    var free = true;
    for (var x = gx - 1; x <= gx + 1 && free; x++) {
      for (var y = gy - 1; y <= gy + 1 && free; y++) {
        for (final j in grid[key(x, y)] ?? const <int>[]) {
          if ((dots[j].center - c).distance < dots[j].radius + radius + gap) {
            free = false;
            break;
          }
        }
      }
    }
    if (!free) continue;
    final figure = shape.contains(c / _figureSize);
    final colours = figure ? palette.figure : palette.background;
    final base = colours[r.nextInt(colours.length)];
    // A little lightness noise on both, so neither stands out by brightness.
    final shade = HSLColor.fromColor(base);
    final color = shade.withLightness((shade.lightness + (r.nextDouble() - 0.5) * 0.08).clamp(0.0, 1.0)).toColor();
    (grid[key(gx, gy)] ??= []).add(dots.length);
    dots.add(PlateDot(c, radius, color, figure));
  }
  return dots;
}

/// Draws a plate. Revealed, the background fades so the figure shows to everyone.
class PlatePainter extends CustomPainter {
  final List<PlateDot> dots;
  final bool revealed;
  const PlatePainter(this.dots, {this.revealed = false});

  @override
  void paint(Canvas canvas, Size size) {
    final side = min(size.width, size.height);
    final scale = side / 2;
    final centre = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(centre, scale, Paint()..color = const Color(0xFFF7F4EF));
    final paint = Paint();
    const faded = Color(0xFFE2DED8);
    for (final d in dots) {
      paint.color = revealed && !d.figure ? faded : (revealed ? const Color(0xFF3C2A21) : d.color);
      canvas.drawCircle(centre + d.center * scale, d.radius * scale, paint);
    }
  }

  @override
  bool shouldRepaint(PlatePainter old) => old.dots != dots || old.revealed != revealed;
}
