import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'geo_map.dart' show BaseMap, baseSources;

/// A region or municipality of Georgia with its real outline, from assets/ge_units.json (OpenStreetMap).
class GeoUnit {
  final String id, ka, en;
  final String? region; // a municipality's region
  final List<List<Offset>> rings; // (lon, lat); outer and inner rings alike, filled even-odd
  const GeoUnit(this.id, this.ka, this.en, this.region, this.rings);

  String name(String lang) => lang == 'ka' ? ka : en;

  factory GeoUnit.fromJson(Map<String, dynamic> j) =>
      GeoUnit(j['id'] as String, j['ka'] as String, j['en'] as String, j['region'] as String?, [
        for (final r in j['rings'] as List)
          [for (final p in r as List) Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
      ]);
}

class GeoUnits {
  final List<GeoUnit> regions, municipalities;

  /// Parts of Georgia OSM doesn't divide into Georgian units: shown in place, never a piece.
  final List<GeoUnit> fixed;
  const GeoUnits(this.regions, this.municipalities, this.fixed);

  GeoUnit? region(String id) => regions.where((r) => r.id == id).firstOrNull;
  List<GeoUnit> municipalitiesOf(String region) => [
    for (final m in municipalities)
      if (m.region == region) m,
  ];

  /// Regions that can be cut into their municipalities: two at least.
  List<GeoUnit> get divisible => [
    for (final r in regions)
      if (municipalitiesOf(r.id).length >= 2) r,
  ];
}

GeoUnits parseGeoUnits(String text) {
  final j = jsonDecode(text) as Map<String, dynamic>;
  List<GeoUnit> list(String key) => [for (final u in j[key] as List) GeoUnit.fromJson(u as Map<String, dynamic>)];
  return GeoUnits(list('regions'), list('municipalities'), list('fixed'));
}

Future<GeoUnits>? _loading;
Future<GeoUnits> loadGeoUnits() => _loading ??= rootBundle.loadString('assets/ge_units.json').then(parseGeoUnits);

const puzzleKinds = ['regions', 'municipalities', 'grid'];
const puzzleRotations = ['none', 'quarter', 'any'];
const puzzleHelps = ['outline', 'frame', 'none'];
const puzzleLooks = ['map', 'color'];
const puzzleBases = ['osm', 'topo'];
const puzzleSizes = [9, 16, 25, 36, 49, 64];

/// What the teacher chose. Every student's device cuts the same pieces from it.
class PuzzleSpec {
  final String kind, area, rotation, help, look, base;
  final int rows, cols, seed, pieces;
  final bool names;
  const PuzzleSpec({
    required this.kind,
    this.area = 'georgia',
    this.rows = 0,
    this.cols = 0,
    this.rotation = 'none',
    this.help = 'outline',
    this.names = false,
    this.look = 'map',
    this.base = 'osm',
    required this.seed,
    this.pieces = 0,
  });

  bool get grid => kind == 'grid';

  /// How far one tap turns a piece, in degrees; 0 when pieces don't turn.
  int get step => switch (rotation) {
    'quarter' => 90,
    'any' => 30,
    _ => 0,
  };

  factory PuzzleSpec.fromSettings(Map<String, dynamic> j) => PuzzleSpec(
    kind: j['kind'] as String? ?? 'regions',
    area: j['area'] as String? ?? 'georgia',
    rows: j['rows'] as int? ?? 0,
    cols: j['cols'] as int? ?? 0,
    rotation: j['rotation'] as String? ?? 'none',
    help: j['help'] as String? ?? 'outline',
    names: j['names'] == true,
    look: j['look'] as String? ?? 'map',
    base: j['base'] as String? ?? 'osm',
    seed: j['seed'] as int? ?? 0,
    pieces: j['pieces'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'area': area,
    'rows': rows,
    'cols': cols,
    'rotation': rotation,
    'help': help,
    'names': names,
    'look': look,
    'base': base,
    'seed': seed,
    'pieces': pieces,
  };

  PuzzleSpec copyWith({int? rows, int? cols, int? pieces}) => PuzzleSpec(
    kind: kind,
    area: area,
    rows: rows ?? this.rows,
    cols: cols ?? this.cols,
    rotation: rotation,
    help: help,
    names: names,
    look: look,
    base: base,
    seed: seed,
    pieces: pieces ?? this.pieces,
  );
}

/// Web Mercator, the projection of the map tiles: world pixels at a zoom level.
Offset mercator(Offset lonLat, int zoom) {
  final size = 256.0 * (1 << zoom);
  final lat = lonLat.dy.clamp(-85.0, 85.0) * pi / 180;
  return Offset((lonLat.dx + 180) / 360 * size, (1 - log(tan(lat) + 1 / cos(lat)) / pi) / 2 * size);
}

/// One piece, in the board's pixels.
class PuzzlePiece {
  final int index;
  final String id, ka, en;
  final List<List<Offset>> rings;
  final Rect bounds;
  final Path path;
  final Offset labelAt;
  Color color;
  PuzzlePiece(this.index, this.id, this.ka, this.en, this.rings, {this.color = Colors.grey})
    : bounds = _bounds(rings),
      path = _path(rings),
      labelAt = _labelPoint(rings);

  Offset get center => bounds.center;
  String name(String lang) => lang == 'ka' ? ka : en;
}

Rect _bounds(List<List<Offset>> rings) {
  var (x0, y0, x1, y1) = (double.infinity, double.infinity, -double.infinity, -double.infinity);
  for (final p in rings.expand((r) => r)) {
    x0 = min(x0, p.dx);
    y0 = min(y0, p.dy);
    x1 = max(x1, p.dx);
    y1 = max(y1, p.dy);
  }
  return Rect.fromLTRB(x0, y0, x1, y1);
}

Path _path(List<List<Offset>> rings) {
  final path = Path()..fillType = PathFillType.evenOdd;
  for (final r in rings) {
    path.addPolygon(r, true);
  }
  return path;
}

bool _inside(Offset p, List<Offset> ring) {
  var c = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) c = !c;
  }
  return c;
}

bool insideRings(Offset p, List<List<Offset>> rings) => rings.fold(false, (c, r) => c != _inside(p, r));

/// A point well inside the piece, for its name: of a grid of inner points, the one farthest from the edge.
Offset _labelPoint(List<List<Offset>> rings) {
  final b = _bounds(rings);
  final edge = rings.expand((r) => r).toList();
  var best = b.center;
  var bestDistance = -1.0;
  for (var i = 1; i < 16; i++) {
    for (var j = 1; j < 16; j++) {
      final p = Offset(b.left + b.width * i / 16, b.top + b.height * j / 16);
      if (!insideRings(p, rings)) continue;
      var d = double.infinity;
      for (final q in edge) {
        d = min(d, (p - q).distanceSquared);
      }
      if (d > bestDistance) (best, bestDistance) = (p, d);
    }
  }
  return best;
}

/// The cut puzzle: the board's size in pixels, where it lies on the map, its pieces and what stays fixed.
class PuzzleBoard {
  final PuzzleSpec spec;
  final Size size;
  final int zoom;
  final Offset origin; // the board's top left corner, in world pixels at [zoom]
  final List<PuzzlePiece> pieces;
  final List<PuzzlePiece> fixed;

  /// For the plain-colour look of a classic jigsaw: the units the picture shows.
  final List<PuzzlePiece> picture;
  const PuzzleBoard(this.spec, this.size, this.zoom, this.origin, this.pieces, this.fixed, this.picture);

  Rect get rect => Offset.zero & size;
}

const _maxBoardPx = 1600.0;

/// Cuts the puzzle. The same settings give the same pieces on every device.
PuzzleBoard buildBoard(GeoUnits units, PuzzleSpec spec) {
  final georgia = spec.area == 'georgia';
  final region = georgia ? null : units.region(spec.area);
  final cover = georgia ? [...units.regions, ...units.fixed] : [?region];
  if (cover.isEmpty) throw ArgumentError('unknown area ${spec.area}');

  final List<GeoUnit> cut = switch (spec.kind) {
    'regions' => units.regions,
    // Abkhazia has no Georgian municipalities in OSM: there it stays one piece.
    'municipalities' when georgia => [
      ...units.municipalities,
      ...units.regions.where((r) => units.municipalitiesOf(r.id).isEmpty),
    ],
    'municipalities' => units.municipalitiesOf(spec.area),
    _ => const [],
  };
  final fixedUnits = georgia ? units.fixed : const <GeoUnit>[];

  // The largest zoom at which the area still fits the board.
  final all = cover.expand((u) => u.rings).expand((r) => r).toList();
  Rect worldBounds(int z) => _bounds([
    [for (final p in all) mercator(p, z)],
  ]);
  final b0 = worldBounds(0);
  final zoom = (log(_maxBoardPx / 1.08 / max(b0.width, b0.height)) / ln2).floor().clamp(4, 13);
  final bz = worldBounds(zoom);
  final margin = max(bz.width, bz.height) * 0.03;
  final origin = Offset((bz.left - margin).floorToDouble(), (bz.top - margin).floorToDouble());
  final size = Size((bz.width + 2 * margin).ceilToDouble(), (bz.height + 2 * margin).ceilToDouble());

  PuzzlePiece piece(int i, GeoUnit u) => PuzzlePiece(i, u.id, u.ka, u.en, [
    for (final r in u.rings) [for (final p in r) mercator(p, zoom) - origin],
  ]);

  final fixed = [for (final (i, u) in fixedUnits.indexed) piece(-1 - i, u)];
  if (spec.grid) {
    final pictureUnits = georgia ? units.regions : units.municipalitiesOf(spec.area);
    final picture = [for (final (i, u) in (pictureUnits.isEmpty ? cover : pictureUnits).indexed) piece(i, u)];
    _colour(picture);
    return PuzzleBoard(spec, size, zoom, origin, jigsaw(size, spec.rows, spec.cols, spec.seed), fixed, picture);
  }
  final pieces = [for (final (i, u) in cut.indexed) piece(i, u)];
  _colour(pieces);
  return PuzzleBoard(spec, size, zoom, origin, pieces, fixed, const []);
}

/// How many rows and columns give about [count] pieces of a board's shape, 3 to 8 each way.
(int rows, int cols) gridFor(Size size, int count) {
  final cols = sqrt(count * size.width / size.height).round().clamp(3, 8);
  final rows = sqrt(count * size.height / size.width).round().clamp(3, 8);
  return (rows, cols);
}

const _palette = [
  Color(0xFFF4C27A),
  Color(0xFF9FD3A8),
  Color(0xFFA9C8F0),
  Color(0xFFE8A6B8),
  Color(0xFFD5C2EE),
  Color(0xFFF2E38B),
  Color(0xFF8FD6D0),
  Color(0xFFF0B097),
];

/// Neighbours get different colours. They share their border points exactly, as in OSM, so a shared point means a neighbour.
void _colour(List<PuzzlePiece> pieces) {
  final byPoint = <Offset, Set<int>>{};
  for (final (i, p) in pieces.indexed) {
    for (final q in p.rings.expand((r) => r)) {
      (byPoint[q] ??= {}).add(i);
    }
  }
  final neighbours = [for (final _ in pieces) <int>{}];
  for (final ids in byPoint.values) {
    for (final i in ids) {
      neighbours[i].addAll(ids.where((j) => j != i));
    }
  }
  final colours = List<int>.filled(pieces.length, -1);
  for (var i = 0; i < pieces.length; i++) {
    final taken = {for (final j in neighbours[i]) colours[j]};
    var c = 0;
    while (taken.contains(c) && c < _palette.length - 1) {
      c++;
    }
    colours[i] = c;
    pieces[i].color = _palette[c];
  }
}

/// A classic jigsaw: a grid whose inner edges get a knob, out or in, from the seed.
List<PuzzlePiece> jigsaw(Size size, int rows, int cols, int seed) {
  final random = Random(seed);
  final cw = size.width / cols, ch = size.height / rows;
  final h = min(cw, ch);
  // Knobs of the edges between rows (horizontal) and between columns (vertical): direction and a little shift.
  final across = [
    for (var r = 0; r <= rows; r++)
      [for (var c = 0; c < cols; c++) (random.nextBool() ? 1.0 : -1.0, (random.nextDouble() - 0.5) * 0.12)],
  ];
  final down = [
    for (var r = 0; r < rows; r++)
      [for (var c = 0; c <= cols; c++) (random.nextBool() ? 1.0 : -1.0, (random.nextDouble() - 0.5) * 0.12)],
  ];

  /// The points of an edge from [a] towards [b], [b] itself left out: the next edge starts there.
  List<Offset> edge(Offset a, Offset b, (double, double)? knob) {
    if (knob == null) return [a];
    final d = b - a;
    final n = Offset(-d.dy, d.dx) / d.distance * h * knob.$1;
    // The knob sits a little off the middle, by the seed.
    Offset at(double u, double v) => a + d * (u + knob.$2) + n * v;
    final out = <Offset>[a];
    // In units of the edge: along it, and out from it.
    const curves = [
      [Offset(0.37, 0), Offset(0.43, 0), Offset(0.30, 0.22), Offset(0.5, 0.24)],
      [Offset(0.5, 0.24), Offset(0.70, 0.22), Offset(0.57, 0), Offset(0.63, 0)],
    ];
    for (final c in curves) {
      for (var i = 0; i <= 10; i++) {
        final t = i / 10, s = 1 - t;
        final p = c[0] * (s * s * s) + c[1] * (3 * s * s * t) + c[2] * (3 * s * t * t) + c[3] * (t * t * t);
        out.add(at(p.dx, p.dy));
      }
    }
    return out;
  }

  final pieces = <PuzzlePiece>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final tl = Offset(c * cw, r * ch), tr = Offset((c + 1) * cw, r * ch);
      final bl = Offset(c * cw, (r + 1) * ch), br = Offset((c + 1) * cw, (r + 1) * ch);
      final top = edge(tl, tr, r == 0 ? null : across[r][c]);
      final right = edge(tr, br, c == cols - 1 ? null : down[r][c + 1]);
      // The other two edges are walked backwards: the same points, so neighbours fit exactly.
      final bottom = [br, ...edge(bl, br, r == rows - 1 ? null : across[r + 1][c]).skip(1).toList().reversed];
      final left = [bl, ...edge(tl, bl, c == 0 ? null : down[r][c]).skip(1).toList().reversed];
      final ring = [...top, ...right, ...bottom, ...left];
      final label = '${String.fromCharCode(65 + r)}${c + 1}';
      pieces.add(PuzzlePiece(r * cols + c, label, label, label, [ring]));
    }
  }
  return pieces;
}

/// The picture the pieces are cut from, drawn in plain colours: no network needed.
ui.Image colourArt(PuzzleBoard board, {Color background = const Color(0xFFE9EEF2)}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, board.rect);
  canvas.drawRect(board.rect, Paint()..color = background);
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = max(1.0, board.size.longestSide / 900)
    ..color = const Color(0x88384850);
  for (final p in board.spec.grid ? board.picture : board.pieces) {
    canvas.drawPath(p.path, Paint()..color = p.color);
    canvas.drawPath(p.path, line);
  }
  for (final p in board.fixed) {
    canvas.drawPath(p.path, Paint()..color = const Color(0xFFD3D6DA));
  }
  return recorder.endRecording().toImageSync(board.size.width.round(), board.size.height.round());
}

/// The picture from the live map tiles. Tiles that don't load stay grey; with none at all this fails.
Future<ui.Image> mapArt(PuzzleBoard board, {http.Client? client}) async {
  final source = baseSources[board.spec.base == 'topo' ? BaseMap.topo : BaseMap.osm]!;
  final zoom = board.zoom;
  final x0 = (board.origin.dx / 256).floor(), y0 = (board.origin.dy / 256).floor();
  final x1 = ((board.origin.dx + board.size.width) / 256).floor();
  final y1 = ((board.origin.dy + board.size.height) / 256).floor();
  final http.Client c = client ?? http.Client();
  // The tile servers ask apps to say who they are; browsers send their own User-Agent.
  final headers = kIsWeb ? const <String, String>{} : const {'User-Agent': 'GeoClass (ge.qgis.geoclass)'};
  final tiles = <(int, int), ui.Image>{};
  try {
    final jobs = [
      for (var x = x0; x <= x1; x++)
        for (var y = y0; y <= y1; y++) (x, y),
    ];
    // A few at a time, as a map view would ask.
    for (var i = 0; i < jobs.length; i += 6) {
      await Future.wait([
        for (final (x, y) in jobs.skip(i).take(6))
          () async {
            try {
              final url = source.url.replaceAll('{z}', '$zoom').replaceAll('{x}', '$x').replaceAll('{y}', '$y');
              final res = await c.get(Uri.parse(url), headers: headers);
              if (res.statusCode != 200) return;
              final codec = await ui.instantiateImageCodec(res.bodyBytes);
              tiles[(x, y)] = (await codec.getNextFrame()).image;
            } on Exception {
              // Left grey.
            }
          }(),
      ]);
    }
  } finally {
    if (client == null) c.close();
  }
  if (tiles.isEmpty) throw const MapArtError();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, board.rect);
  canvas.drawRect(board.rect, Paint()..color = const Color(0xFFDDDDDD));
  for (final MapEntry(key: (x, y), value: image) in tiles.entries) {
    canvas.drawImage(image, Offset(x * 256 - board.origin.dx, y * 256 - board.origin.dy), Paint());
  }
  for (final image in tiles.values) {
    image.dispose();
  }
  return recorder.endRecording().toImageSync(board.size.width.round(), board.size.height.round());
}

class MapArtError implements Exception {
  const MapArtError();
}

/// The look the teacher chose; the plain-colour picture if the map can't load.
Future<(ui.Image, bool)> puzzleArt(PuzzleBoard board, {http.Client? client}) async {
  if (board.spec.look == 'map') {
    try {
      return (await mapArt(board, client: client), true);
    } on MapArtError {
      // Falls through to colours.
    }
  }
  return (colourArt(board), false);
}

/// Paints one piece: the picture cut along its edge.
class PiecePainter extends CustomPainter {
  final PuzzlePiece piece;
  final ui.Image? art;
  final double scale;
  final Color? tint; // a wrong drop flashes
  PiecePainter(this.piece, this.art, this.scale, {this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    canvas.translate(-piece.bounds.left, -piece.bounds.top);
    paintPiece(canvas, piece, art, 1 / scale, tint: tint);
  }

  @override
  bool shouldRepaint(PiecePainter old) =>
      old.piece != piece || old.art != art || old.scale != scale || old.tint != tint;
}

/// Draws a piece in board coordinates; [px] is one screen pixel in board pixels, for the lines.
void paintPiece(Canvas canvas, PuzzlePiece piece, ui.Image? art, double px, {Color? tint}) {
  canvas.save();
  canvas.clipPath(piece.path);
  if (art == null) {
    canvas.drawPath(piece.path, Paint()..color = piece.color);
  } else {
    canvas.drawImage(art, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
  }
  if (tint != null) canvas.drawPath(piece.path, Paint()..color = tint);
  canvas.restore();
  canvas.drawPath(
    piece.path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * px
      ..color = const Color(0xCC263238),
  );
}

/// A piece on its own, scaled and turned.
class PieceView extends StatelessWidget {
  final PuzzlePiece piece;
  final ui.Image? art;
  final double scale;
  final int angle; // degrees
  final Color? tint;
  const PieceView({super.key, required this.piece, required this.art, required this.scale, this.angle = 0, this.tint});

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: angle * pi / 180,
    child: CustomPaint(
      size: piece.bounds.size * scale,
      painter: PiecePainter(piece, art, scale, tint: tint),
    ),
  );
}

/// The board: the help the teacher chose, the fixed areas, and the pieces already in place with their names.
class BoardPainter extends CustomPainter {
  final PuzzleBoard board;
  final ui.Image? art;
  final Set<int> placed;
  final String lang;
  final Color background, ink;
  final double scale;
  final bool names;
  BoardPainter({
    required this.board,
    required this.art,
    required this.placed,
    required this.lang,
    required this.background,
    required this.ink,
    required this.scale,
    this.names = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    final px = 1 / scale;
    canvas.drawRect(board.rect, Paint()..color = background);
    final help = board.spec.help;
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..color = ink.withValues(alpha: 0.45);
    if (help == 'outline') {
      guide.strokeWidth = 1 * px;
      for (final p in board.pieces) {
        canvas.drawPath(p.path, guide);
      }
    } else if (help == 'frame') {
      if (board.spec.grid) {
        canvas.drawRect(board.rect.deflate(px), guide..strokeWidth = 2 * px);
      } else {
        // A thick line round every piece, then the pieces filled over it: only the outer edge is left.
        guide.strokeWidth = 4 * px;
        for (final p in [...board.pieces, ...board.fixed]) {
          canvas.drawPath(p.path, guide);
        }
        for (final p in [...board.pieces, ...board.fixed]) {
          canvas.drawPath(p.path, Paint()..color = background);
        }
      }
    }
    for (final p in board.fixed) {
      canvas.drawPath(p.path, Paint()..color = ink.withValues(alpha: 0.12));
      canvas.drawPath(
        p.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = px
          ..color = ink.withValues(alpha: 0.4),
      );
    }
    for (final p in board.pieces) {
      if (placed.contains(p.index)) paintPiece(canvas, p, art, px);
    }
    if (!names || board.spec.grid) return;
    for (final p in [...board.fixed, ...board.pieces.where((p) => placed.contains(p.index))]) {
      _label(canvas, p.name(lang), p.labelAt, px);
    }
  }

  void _label(Canvas canvas, String text, Offset at, double px) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11 * px,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF1B1F23),
          shadows: [
            for (final o in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)])
              Shadow(color: const Color(0xDDFFFFFF), offset: o * px, blurRadius: 1.5 * px),
          ],
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 140 * px);
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(BoardPainter old) =>
      old.board != board ||
      old.art != art ||
      old.placed.length != placed.length ||
      old.scale != scale ||
      old.background != background ||
      old.lang != lang;
}

/// The map credit, always on screen with a map picture.
class PuzzleCredit extends StatelessWidget {
  final PuzzleSpec spec;
  final bool map; // false when the picture fell back to plain colours
  const PuzzleCredit({super.key, required this.spec, required this.map});

  @override
  Widget build(BuildContext context) => Text(
    map && spec.base == 'topo'
        ? '© OpenStreetMap contributors, © OpenTopoMap (CC BY-SA)'
        : '© OpenStreetMap contributors',
    textAlign: TextAlign.center,
    style: Theme.of(context).textTheme.labelSmall,
  );
}

/// One placement a student sent: a piece put in its place, or dropped in a wrong one.
class PuzzleTry {
  final String participantId;
  final bool ok;
  final int piece, createdAt;
  const PuzzleTry(this.participantId, this.ok, this.piece, this.createdAt);

  factory PuzzleTry.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return PuzzleTry(j['participantId'] as String, a['ok'] as bool, a['piece'] as int? ?? -1, j['createdAt'] as int);
  }
}

class PuzzleRow {
  final String participantId;
  final int placed, mistakes;
  final int? seconds; // how long the whole puzzle took, once finished
  const PuzzleRow(this.participantId, this.placed, this.mistakes, this.seconds);
}

/// Who finished, how fast and with how many wrong placements; then who has placed the most.
List<PuzzleRow> puzzleLeaderboard(List<PuzzleTry> tries, int pieces, int? startedAt) {
  final placed = <String, Set<int>>{}, mistakes = <String, int>{}, last = <String, int>{}, first = <String, int>{};
  for (final t in tries) {
    placed.putIfAbsent(t.participantId, () => {});
    mistakes.putIfAbsent(t.participantId, () => 0);
    first[t.participantId] = min(first[t.participantId] ?? t.createdAt, t.createdAt);
    if (t.ok) {
      placed[t.participantId]!.add(t.piece);
      last[t.participantId] = max(last[t.participantId] ?? 0, t.createdAt);
    } else {
      mistakes[t.participantId] = mistakes[t.participantId]! + 1;
    }
  }
  final rows = [
    for (final id in placed.keys)
      PuzzleRow(
        id,
        placed[id]!.length,
        mistakes[id]!,
        pieces > 0 && placed[id]!.length >= pieces ? max(0, last[id]! - (startedAt ?? first[id]!)) : null,
      ),
  ];
  rows.sort((a, b) {
    if (a.seconds != null || b.seconds != null) {
      if (a.seconds == null) return 1;
      if (b.seconds == null) return -1;
      final bySpeed = a.seconds!.compareTo(b.seconds!);
      if (bySpeed != 0) return bySpeed;
    }
    final byPlaced = b.placed.compareTo(a.placed);
    if (byPlaced != 0) return byPlaced;
    return a.mistakes.compareTo(b.mistakes);
  });
  return rows;
}

/// For each piece: how many students placed it and how many wrong drops it had, hardest first.
List<({int piece, int placed, int mistakes})> hardestPieces(List<PuzzleTry> tries, int pieces) {
  final placed = List.filled(pieces, 0), mistakes = List.filled(pieces, 0);
  final seen = <(String, int)>{};
  for (final t in tries) {
    if (t.piece < 0 || t.piece >= pieces) continue;
    if (!t.ok) {
      mistakes[t.piece]++;
    } else if (seen.add((t.participantId, t.piece))) {
      placed[t.piece]++;
    }
  }
  final out = [for (var i = 0; i < pieces; i++) (piece: i, placed: placed[i], mistakes: mistakes[i])];
  out.sort((a, b) => b.mistakes.compareTo(a.mistakes));
  return out;
}
