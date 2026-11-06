import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'coords.dart';
import 'l10n.dart';

/// The questions of a task, in the order of their round: round = task * 3 + question.
const evidenceQuestions = ['coords', 'map', 'name'];
const evidenceKinds = ['receipt', 'dashcam'];
const evidenceFormats = ['dd', 'dm', 'dms', 'utm'];

/// One task of the evidence game: a picture the app draws, with coordinates the teacher typed.
class EvidenceTask {
  final String kind; // receipt or dashcam
  final double lat, lon;
  final String shown; // the format the picture writes the coordinates in
  final String ask; // the format the answer must be in
  final List<String> questions;
  final List<String> names; // accepted names of the object
  final bool converter;
  final int seed; // the made-up details of the picture

  const EvidenceTask({
    required this.kind,
    required this.lat,
    required this.lon,
    required this.shown,
    required this.ask,
    required this.questions,
    required this.names,
    required this.converter,
    required this.seed,
  });

  bool asks(String question) => questions.contains(question);
  String get title => names.isEmpty ? formatDd(lat, lon) : names.first;

  factory EvidenceTask.fromJson(Map<String, dynamic> j) => EvidenceTask(
    kind: j['kind'] as String,
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    shown: j['shown'] as String,
    ask: j['ask'] as String,
    questions: (j['questions'] as List).cast<String>(),
    names: (j['names'] as List? ?? const []).cast<String>(),
    converter: j['converter'] as bool? ?? true,
    seed: j['seed'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'lat': lat,
    'lon': lon,
    'shown': shown,
    'ask': ask,
    'questions': questions,
    'names': names,
    'converter': converter,
    'seed': seed,
  };

  EvidenceTask copyWith({
    String? kind,
    double? lat,
    double? lon,
    String? shown,
    String? ask,
    List<String>? questions,
    List<String>? names,
    bool? converter,
  }) => EvidenceTask(
    kind: kind ?? this.kind,
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    shown: shown ?? this.shown,
    ask: ask ?? this.ask,
    questions: questions ?? this.questions,
    names: names ?? this.names,
    converter: converter ?? this.converter,
    seed: seed,
  );

  static List<EvidenceTask> listFrom(Map<String, dynamic> settings) => [
    for (final t in settings['tasks'] as List? ?? const []) EvidenceTask.fromJson(t as Map<String, dynamic>),
  ];
}

int randomSeed([Random? random]) => (random ?? Random()).nextInt(0x7fffffff);

// --- Scoring. worker/src/validate.ts has the same rules and decides the real score. ---

/// Strict, for coordinates read off a picture: 100 within 30 m, 0 from 5 km.
int strictScoreFor(double distance) {
  if (distance <= 30) return 100;
  if (distance >= 5000) return 0;
  return (100 * (1 - log(distance / 30) / log(5000 / 30))).round();
}

final _notLetters = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Case, spaces, punctuation and quotes don't matter.
String normaliseName(String name) => name.toLowerCase().replaceAll(_notLetters, '');

bool nameMatches(EvidenceTask task, String name) {
  final given = normaliseName(name);
  return given.isNotEmpty && task.names.any((n) => normaliseName(n) == given);
}

/// One answer to one question, as the teacher's page gets it.
class EvidenceAnswer {
  final String id, participantId, question, raw, format, name;
  final int round, score, createdAt;
  final double lat, lon;
  final double? distanceM;
  final bool accepted, hidden;

  const EvidenceAnswer({
    required this.id,
    required this.participantId,
    required this.question,
    required this.round,
    required this.score,
    required this.createdAt,
    required this.lat,
    required this.lon,
    this.raw = '',
    this.format = '',
    this.name = '',
    this.distanceM,
    this.accepted = false,
    this.hidden = false,
  });

  int get task => round ~/ evidenceQuestions.length;

  /// What counts: the teacher may accept an answer with a small slip as right.
  int get points => accepted ? 100 : score;

  factory EvidenceAnswer.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return EvidenceAnswer(
      id: j['id'] as String,
      participantId: j['participantId'] as String,
      question: a['q'] as String,
      raw: a['raw'] as String? ?? '',
      format: a['format'] as String? ?? '',
      name: a['name'] as String? ?? '',
      round: j['round'] as int,
      score: j['score'] as int? ?? 0,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      distanceM: (j['distanceM'] as num?)?.toDouble(),
      accepted: j['accepted'] as bool? ?? false,
      hidden: j['hidden'] as bool? ?? false,
      createdAt: j['createdAt'] as int,
    );
  }
}

class EvidenceRank {
  final String participantId;
  final int points, answers, lastAt;
  const EvidenceRank(this.participantId, this.points, this.answers, this.lastAt);
}

/// Most points first; on a tie, whoever got there sooner.
List<EvidenceRank> evidenceLeaderboard(List<EvidenceAnswer> answers) {
  final by = <String, List<EvidenceAnswer>>{};
  for (final a in answers) {
    if (!a.hidden) (by[a.participantId] ??= []).add(a);
  }
  final rows = [
    for (final e in by.entries)
      EvidenceRank(
        e.key,
        e.value.fold(0, (sum, a) => sum + a.points),
        e.value.length,
        e.value.map((a) => a.createdAt).reduce(max),
      ),
  ];
  rows.sort((a, b) => a.points != b.points ? b.points.compareTo(a.points) : a.lastAt.compareTo(b.lastAt));
  return rows;
}

// --- The pictures ---

/// How the picture writes the coordinates: with N/E on decimal degrees, and the zone on UTM.
String pictureCoords(String format, double lat, double lon) {
  switch (format) {
    case 'utm':
      final u = toUtm(lat, lon);
      return 'UTM ${u.zone}N  E ${u.easting.round()}  N ${u.northing.round()}';
    case 'dd':
      String one(double v, String pos, String neg) => '${v.abs().toStringAsFixed(5)}° ${v < 0 ? neg : pos}';
      return '${one(lat, 'N', 'S')}, ${one(lon, 'E', 'W')}';
    default:
      return formatAs(format, lat, lon);
  }
}

/// The made-up details, the same on every device for the same seed. No real person, car or document.
class PictureDetails {
  final DateTime when;
  final int number, limit, speed, offence, amount;
  final int light; // dashcam: 0 day, 1 evening, 2 cloudy
  final double curve; // dashcam: where the road bends, -1 to 1
  final List<double> hills;

  PictureDetails._(this.when, this.number, this.limit, this.speed, this.offence, this.amount, this.light, this.curve, this.hills);

  static const offences = 4;

  factory PictureDetails.fromSeed(int seed) {
    final r = Random(seed);
    final when = DateTime(2026, 1 + r.nextInt(10), 1 + r.nextInt(28), 7 + r.nextInt(12), r.nextInt(60), r.nextInt(60));
    final limit = const [40, 50, 60, 70, 80, 90][r.nextInt(6)];
    return PictureDetails._(
      when,
      100000 + r.nextInt(900000),
      limit,
      limit + 12 + r.nextInt(30),
      r.nextInt(offences),
      const [20, 40, 50, 100, 150][r.nextInt(5)],
      r.nextInt(3),
      r.nextDouble() * 2 - 1,
      [for (var i = 0; i < 6; i++) r.nextDouble()],
    );
  }

  String get date => '${when.year}-${_two(when.month)}-${_two(when.day)}';
  String get time => '${_two(when.hour)}:${_two(when.minute)}:${_two(when.second)}';
  static String _two(int v) => '$v'.padLeft(2, '0');
}

/// The picture of a task. Tapping it opens a zoomable copy.
class EvidencePicture extends StatelessWidget {
  final S s;
  final EvidenceTask task;
  final bool zoomable;
  const EvidencePicture({super.key, required this.s, required this.task, this.zoomable = true});

  Widget _drawing() => task.kind == 'dashcam' ? DashcamFrame(s: s, task: task) : FineReceipt(s: s, task: task);

  @override
  Widget build(BuildContext context) {
    final picture = FittedBox(child: _drawing());
    if (!zoomable) return picture;
    return Semantics(
      button: true,
      label: s['ev_zoom'],
      child: GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(8),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                InteractiveViewer(maxScale: 6, child: Center(child: FittedBox(child: _drawing()))),
                Positioned(
                  right: 4,
                  top: 4,
                  child: IconButton.filledTonal(
                    tooltip: s['close'],
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ],
            ),
          ),
        ),
        child: Stack(
          children: [
            picture,
            // Where it covers nothing: the receipt's empty top corner, the dashcam's sky.
            Positioned.fill(
              child: Align(
                alignment: task.kind == 'dashcam' ? const Alignment(1, -0.45) : Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.zoom_in, color: task.kind == 'dashcam' ? Colors.white70 : Colors.black54, size: 28),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A fine receipt that is plainly a classroom sample: no emblem, no real office, no person or car.
class FineReceipt extends StatelessWidget {
  final S s;
  final EvidenceTask task;
  const FineReceipt({super.key, required this.s, required this.task});

  static const _ink = Color(0xFF1F2A44);
  static const _red = Color(0xFFC62828);

  @override
  Widget build(BuildContext context) {
    final d = PictureDetails.fromSeed(task.seed);
    const label = TextStyle(fontSize: 11, color: Color(0xFF55607A));
    const value = TextStyle(fontSize: 14, color: _ink, fontWeight: FontWeight.w700);
    Widget row(String name, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: label),
          Text(text, style: value),
        ],
      ),
    );
    return SizedBox(
      width: 360,
      child: DefaultTextStyle(
        style: const TextStyle(color: _ink, fontFamily: 'NotoSansGeorgian'),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFCF2),
            border: Border.all(color: const Color(0xFFB9B39F)),
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: Transform.rotate(
                    angle: -0.5,
                    child: Text(
                      s['ev_sample'].toUpperCase(),
                      style: TextStyle(fontSize: 56, fontWeight: FontWeight.w700, color: _red.withValues(alpha: 0.08)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(border: Border.all(color: _red, width: 1.5), borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          s['ev_sample_banner'],
                          style: const TextStyle(color: _red, fontWeight: FontWeight.w700, fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s['ev_receipt_title'],
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    const Divider(color: Color(0xFFB9B39F), height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: row(s['ev_receipt_number'], 'GC-${d.number}')),
                        Expanded(child: row(s['ev_receipt_when'], '${d.date}  ${d.time.substring(0, 5)}')),
                      ],
                    ),
                    row(s['ev_receipt_offence'], s['ev_offence_${d.offence}']),
                    if (d.offence == 0) row(s['ev_receipt_speed'], s.f('ev_speed_text', [d.speed, d.limit])),
                    Text(s['ev_receipt_place'], style: label),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF3FA),
                        border: Border.all(color: const Color(0xFF9AA8C4)),
                      ),
                      child: Text(
                        pictureCoords(task.shown, task.lat, task.lon),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFamily: 'Roboto'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    row(s['ev_receipt_amount'], s.f('ev_amount', [d.amount])),
                    SizedBox(height: 34, child: CustomPaint(painter: _Barcode(task.seed))),
                    const SizedBox(height: 6),
                    Text(
                      s['ev_receipt_note'],
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF55607A)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Barcode extends CustomPainter {
  final int seed;
  const _Barcode(this.seed);
  @override
  void paint(Canvas canvas, Size size) {
    final r = Random(seed ^ 0x5bd1e995);
    final paint = Paint()..color = FineReceipt._ink;
    var x = 0.0;
    while (x < size.width) {
      final w = 1.0 + r.nextInt(3);
      if (r.nextBool()) canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
      x += w + 1;
    }
  }

  @override
  bool shouldRepaint(_Barcode old) => old.seed != seed;
}

/// A drawn frame from a car's dashboard camera, with its stamp of time, speed and place.
class DashcamFrame extends StatelessWidget {
  final S s;
  final EvidenceTask task;
  const DashcamFrame({super.key, required this.s, required this.task});

  @override
  Widget build(BuildContext context) {
    final d = PictureDetails.fromSeed(task.seed);
    const shadow = [Shadow(blurRadius: 3), Shadow(offset: Offset(1, 1))];
    const stamp = TextStyle(
      color: Colors.white,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      fontFamily: 'Roboto',
      fontFeatures: [FontFeature.tabularFigures()],
      shadows: shadow,
    );
    return SizedBox(
      width: 640,
      height: 360,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _Road(d))),
            Positioned(
              left: 14,
              top: 10,
              child: Row(
                children: [
                  Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  const Text('REC', style: stamp),
                ],
              ),
            ),
            Positioned(right: 14, top: 10, child: Text('${d.date}  ${d.time}', style: stamp)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: const Color(0x66000000),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  children: [
                    Text('${d.speed} km/h', style: stamp),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Text(
                        pictureCoords(task.shown, task.lat, task.lon),
                        textAlign: TextAlign.right,
                        style: stamp,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 14,
              top: 36,
              child: Text(
                s['ev_sample_banner'],
                style: stamp.copyWith(fontSize: 12, fontFamily: 'NotoSansGeorgian', color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Road extends CustomPainter {
  final PictureDetails d;
  const _Road(this.d);

  static const _skies = [
    [Color(0xFF5B9BD5), Color(0xFFD4E6F5)],
    [Color(0xFF3D3B6E), Color(0xFFF2A65A)],
    [Color(0xFF7D8A96), Color(0xFFD5DBE0)],
  ];
  static const _far = [Color(0xFF7FA37A), Color(0xFF5B4B6B), Color(0xFF8A9A8C)];
  static const _near = [Color(0xFF4F7F3F), Color(0xFF3E3A4A), Color(0xFF5F7458)];
  static const _ground = [Color(0xFF6B8F4E), Color(0xFF4A4636), Color(0xFF6E7E5E)];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizon = h * 0.46;
    final light = d.light;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, horizon + 2),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: _skies[light])
          .createShader(Rect.fromLTWH(0, 0, w, horizon)),
    );

    // Two rows of hills, shaped by the seed.
    void hills(double height, double phase, Color color) {
      final path = Path()..moveTo(0, horizon);
      for (var x = 0.0; x <= w; x += 8) {
        final y = horizon -
            height * (0.55 + 0.25 * sin(x / w * pi * (2 + d.hills[0] * 3) + phase) + 0.2 * sin(x / w * pi * (5 + d.hills[1] * 4) + phase * 2));
        path.lineTo(x, y);
      }
      path
        ..lineTo(w, horizon + 1)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    hills(h * (0.14 + d.hills[2] * 0.08), d.hills[3] * 6, _far[light]);
    hills(h * (0.07 + d.hills[4] * 0.05), d.hills[5] * 6, _near[light]);
    canvas.drawRect(Rect.fromLTWH(0, horizon, w, h - horizon), Paint()..color = _ground[light]);

    // The road bends towards a vanishing point.
    final vx = w * (0.5 + d.curve * 0.12);
    final bend = w * d.curve * 0.18;
    Offset edge(double side, double t) {
      // t = 0 at the bottom of the picture, 1 at the horizon.
      final bottomX = w * (0.5 + side * 0.55);
      final x = bottomX + (vx - bottomX) * t + bend * t * (1 - t);
      return Offset(x + side * 2 * t, h + (horizon - h) * t);
    }

    Path strip(double side1, double side2) {
      final path = Path()..moveTo(edge(side1, 0).dx, h);
      for (var t = 0.0; t <= 1.0001; t += 0.02) {
        path.lineTo(edge(side1, t).dx, edge(side1, t).dy);
      }
      for (var t = 1.0; t >= -0.0001; t -= 0.02) {
        path.lineTo(edge(side2, t).dx, edge(side2, t).dy);
      }
      return path..close();
    }

    canvas.drawPath(strip(-1, 1), Paint()..color = light == 1 ? const Color(0xFF3B3B42) : const Color(0xFF55575C));
    final line = Paint()
      ..color = const Color(0xFFEDEDED)
      ..style = PaintingStyle.stroke;
    for (final side in [-0.94, 0.94]) {
      final path = Path()..moveTo(edge(side, 0).dx, h);
      for (var t = 0.0; t <= 1.0001; t += 0.02) {
        path.lineTo(edge(side, t).dx, edge(side, t).dy);
      }
      canvas.drawPath(path, line..strokeWidth = 3);
    }
    // Dashes in the middle, shorter and closer further away.
    final dash = Paint()..color = const Color(0xFFF5F5F5);
    var t = 0.0;
    while (t < 0.92) {
      final len = 0.06 * (1 - t) + 0.01;
      final a = edge(0, t), b = edge(0, t + len);
      final width = 6 * (1 - t) + 0.6;
      canvas.drawPath(
        Path()
          ..moveTo(a.dx - width, a.dy)
          ..lineTo(a.dx + width, a.dy)
          ..lineTo(b.dx + width * 0.8, b.dy)
          ..lineTo(b.dx - width * 0.8, b.dy)
          ..close(),
        dash,
      );
      t += len * 2.2;
    }

    // Posts along the right side.
    final post = Paint()..color = const Color(0xFFE8E8E8);
    for (var i = 0; i < 7; i++) {
      final tt = 1 - pow(0.62, i + 1).toDouble();
      final base = edge(1.18, tt);
      final tall = 46 * (1 - tt) + 2;
      canvas.drawRect(Rect.fromLTWH(base.dx, base.dy - tall, 4 * (1 - tt) + 1, tall), post);
    }

    // The car's bonnet.
    final hood = Path()
      ..moveTo(-w * 0.1, h)
      ..quadraticBezierTo(w * 0.5, h * 0.78, w * 1.1, h)
      ..close();
    canvas.drawPath(hood, Paint()..color = const Color(0xFF1C1F24));
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.2, h * 0.93)
        ..quadraticBezierTo(w * 0.5, h * 0.83, w * 0.8, h * 0.93),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // The windscreen darkens towards the corners.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..shader = const RadialGradient(radius: 0.9, colors: [Color(0x00000000), Color(0x55000000)])
          .createShader(Rect.fromLTWH(0, 0, w, h)),
    );
  }

  @override
  bool shouldRepaint(_Road old) => old.d != d;
}

/// The boxes of an answer in one format. The boxes are what joinBoxes reads.
class CoordBoxes extends StatelessWidget {
  final S s;
  final String format;
  final List<TextEditingController> boxes; // six
  final bool south, west;
  final int? zone;
  const CoordBoxes({
    super.key,
    required this.s,
    required this.format,
    required this.boxes,
    this.south = false,
    this.west = false,
    this.zone,
  });

  Widget _row(BuildContext context, String title, int first, List<(String, bool, int)> parts) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 4),
      Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: boxes[first + i],
                keyboardType: TextInputType.numberWithOptions(decimal: parts[i].$2),
                textInputAction: TextInputAction.next,
                maxLength: parts[i].$3,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(parts[i].$2 ? r'[0-9.,]' : r'[0-9]'))],
                decoration: InputDecoration(
                  suffixIcon: Align(widthFactor: 1, child: Text(parts[i].$1)),
                  suffixIconConstraints: const BoxConstraints(minWidth: 28),
                  counterText: '',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final lat = s.f('play_lat', [south ? 'S' : 'N']);
    final lon = s.f('play_lon', [west ? 'W' : 'E']);
    final (first, second) = switch (format) {
      'dms' => (
        _row(context, lat, 0, [('°', false, 3), ('′', false, 2), ('″', true, 5)]),
        _row(context, lon, 3, [('°', false, 3), ('′', false, 2), ('″', true, 5)]),
      ),
      'dm' => (
        _row(context, lat, 0, [('°', false, 3), ('′', true, 7)]),
        _row(context, lon, 2, [('°', false, 3), ('′', true, 7)]),
      ),
      'utm' => (
        _row(context, s.f('ev_easting', [zone == null ? '?' : '${zone}N']), 0, [('m', true, 9)]),
        _row(context, s['ev_northing'], 1, [('m', true, 10)]),
      ),
      _ => (_row(context, lat, 0, [('°', true, 10)]), _row(context, lon, 1, [('°', true, 10)])),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [first, const SizedBox(height: 8), second]);
  }
}
