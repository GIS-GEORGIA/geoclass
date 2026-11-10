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

  factory PlateShape.fromJson(Map<String, dynamic> j) =>
      PlateShape(j['id'] as String, j['ka'] as String, j['en'] as String, j['group'] as String, [
        for (final p in j['polys'] as List)
          [for (final xy in p as List) Offset(((xy as List)[0] as num).toDouble(), (xy[1] as num).toDouble())],
      ]);

  /// Even-odd test over every part: countries that touch are filled as one.
  bool contains(Offset point) {
    var inside = false;
    for (final ring in polys) {
      for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        final a = ring[i], b = ring[j];
        if ((a.dy > point.dy) != (b.dy > point.dy) &&
            point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
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

/// What can be hidden in the plates, in the order the teacher sees it.
const plateGroups = ['ge_region', 'ge_municipality', 'continent', 'country'];
const plateCounts = [6, 9, 12, 20];

/// One plate of a session: everyone's device draws the same plate from these three.
class PlateSpec {
  final String shape, palette;
  final int seed;
  const PlateSpec(this.shape, this.palette, this.seed);

  factory PlateSpec.fromJson(Map<String, dynamic> j) =>
      PlateSpec(j['shape'] as String, j['palette'] as String, (j['seed'] as num).toInt());
  Map<String, dynamic> toJson() => {'shape': shape, 'palette': palette, 'seed': seed};

  static List<PlateSpec> listFrom(Map<String, dynamic> settings) => [
    for (final p in settings['deck'] as List? ?? const []) PlateSpec.fromJson(p as Map<String, dynamic>),
  ];

  @override
  bool operator ==(Object other) =>
      other is PlateSpec && other.shape == shape && other.palette == palette && other.seed == seed;
  @override
  int get hashCode => Object.hash(shape, palette, seed);

  PlatePalette get colours => platePalettes.firstWhere((p) => p.id == palette, orElse: () => platePalettes.first);
}

/// Picks the plates at random from the chosen groups. With 'mix' the palettes take turns.
List<PlateSpec> makeDeck(List<PlateShape> shapes, Set<String> groups, int count, String palette, Random r) {
  final pool = shapes.where((x) => groups.contains(x.group)).toList()..shuffle(r);
  return [
    for (final (i, shape) in pool.take(count).indexed)
      PlateSpec(shape.id, palette == 'mix' ? platePalettes[i % platePalettes.length].id : palette, r.nextInt(1 << 31)),
  ];
}

/// Plates already drawn, so going back and forth doesn't draw them again.
class PlateCache {
  final _drawn = <PlateSpec, List<PlateDot>>{};
  List<PlateDot>? dots(PlateSpec spec, List<PlateShape> shapes) {
    final shape = shapes.where((x) => x.id == spec.shape).firstOrNull;
    if (shape == null) return null; // made by a newer version of the app
    return _drawn[spec] ??= makePlate(shape, spec.colours, spec.seed);
  }
}

/// The plate, and under it the question or, once shown, the answer.
class PlateView extends StatelessWidget {
  final List<PlateDot>? dots;
  final bool revealed;
  final String question, answer;
  final VoidCallback? onTap;
  const PlateView({
    super.key,
    required this.dots,
    required this.revealed,
    required this.question,
    required this.answer,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GestureDetector(
              onTap: onTap,
              child: AspectRatio(
                aspectRatio: 1,
                child: dots == null
                    ? const Center(child: Icon(Icons.help_outline, size: 64))
                    : CustomPaint(painter: PlatePainter(dots!, revealed: revealed)),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: revealed
                  ? Text(answer, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700))
                  : Text(question, style: text.titleMedium),
            ),
          ),
        ),
      ],
    );
  }
}

Widget _platesList(List<Widget> children) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 720),
    child: ListView(padding: const EdgeInsets.all(20), children: children),
  ),
);

/// What the class hears before the first plate. [note] says who sees what; [actions] go under it.
Widget platesNotice(
  BuildContext context,
  String Function(String) s, {
  required String note,
  required List<Widget> actions,
}) {
  final text = Theme.of(context).textTheme;
  return _platesList([
    Icon(Icons.campaign_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
    const SizedBox(height: 8),
    Text(s('plates_notice_title'), textAlign: TextAlign.center, style: text.headlineSmall),
    const SizedBox(height: 16),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final k in const ['plates_notice_1', 'plates_notice_2', 'plates_notice_3', 'plates_notice_4'])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 8),
                      child: Icon(Icons.check_circle_outline, size: 20),
                    ),
                    Expanded(child: Text(s(k), style: text.titleMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text(note, style: text.bodySmall),
    const SizedBox(height: 16),
    ...actions,
  ]);
}

/// After the last plate: why people see the plates differently, and why it matters for maps.
Widget platesEnd(BuildContext context, String Function(String) s, {List<Widget> actions = const []}) {
  final text = Theme.of(context).textTheme;
  return _platesList([
    Icon(Icons.palette_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
    const SizedBox(height: 8),
    Text(s('plates_end_title'), textAlign: TextAlign.center, style: text.headlineSmall),
    const SizedBox(height: 16),
    for (final k in const ['plates_end_1', 'plates_end_2', 'plates_end_3'])
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(s(k), style: text.titleMedium),
        ),
      ),
    const SizedBox(height: 16),
    ...actions,
  ]);
}
