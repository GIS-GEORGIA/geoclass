import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'puzzle.dart' show GeoUnit, GeoUnits, insideRings, mercator;

/// The colours a legend gives out: twelve that stay apart from each other, on screen and on paper.
const layoutPalette = [
  Color(0xFFE6194B),
  Color(0xFF3CB44B),
  Color(0xFFFFE119),
  Color(0xFF4363D8),
  Color(0xFFF58231),
  Color(0xFF911EB4),
  Color(0xFF42D4F4),
  Color(0xFFF032E6),
  Color(0xFFBFEF45),
  Color(0xFFFABED4),
  Color(0xFF469990),
  Color(0xFF9A6324),
];

const layoutElements = ['title', 'north', 'legend', 'scale'];
const layoutGrids = [0.0, 1.0, 0.5];

/// A4 landscape, 297 × 210 mm: the page is 1 wide and this tall.
const pageAspect = 210 / 297;
const _pageWidthM = 0.297;

/// Where the map sits on the page, in parts of its width and height.
const mapFrame = Rect.fromLTWH(0.03, 0.13, 0.70, 0.83);

/// What the teacher chose: the area and the colour of each unit.
class LayoutSpec {
  final String area;
  final List<int> legend; // per unit, an index into [layoutPalette]
  const LayoutSpec(this.area, this.legend);

  factory LayoutSpec.fromSettings(Map<String, dynamic> j) =>
      LayoutSpec(j['area'] as String? ?? 'georgia', [for (final v in j['legend'] as List? ?? const []) v as int]);

  Map<String, dynamic> toJson() => {'area': area, 'legend': legend};
}

/// The units a sheet is coloured by: Georgia's regions, or one region's municipalities.
List<GeoUnit> layoutUnits(GeoUnits units, String area) =>
    area == 'georgia' ? units.regions : units.municipalitiesOf(area);

/// Regions whose municipalities fit the legend: two to twelve of them.
List<GeoUnit> layoutRegions(GeoUnits units) => [
  for (final r in units.regions)
    if (units.municipalitiesOf(r.id).length >= 2 && units.municipalitiesOf(r.id).length <= layoutPalette.length) r,
];

/// A fresh legend: every unit its own colour, in a random order.
List<int> makeLegend(int count, Random random) =>
    ([for (var i = 0; i < layoutPalette.length; i++) i]..shuffle(random)).take(count).toList();

/// An element on the page: its place and size in parts of the page's width (x, w) and height (y, h).
class SheetElement {
  final String kind;
  Rect rect;
  SheetElement(this.kind, this.rect);

  /// Elements keep their shape when resized; these are their first sizes.
  static SheetElement initial(String kind, int units) => SheetElement(kind, switch (kind) {
    'title' => const Rect.fromLTWH(0.25, 0.02, 0.5, 0.08),
    'north' => const Rect.fromLTWH(0.66, 0.16, 0.05, 0.1),
    'legend' => Rect.fromLTWH(0.76, 0.2, 0.21, min(0.75, 0.06 + 0.045 * units)),
    _ => const Rect.fromLTWH(0.5, 0.86, 0.22, 0.07),
  });

  Map<String, dynamic> toJson() => {'kind': kind, 'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height};

  factory SheetElement.fromJson(Map<String, dynamic> j) => SheetElement(
    j['kind'] as String,
    Rect.fromLTWH(
      (j['x'] as num).toDouble(),
      (j['y'] as num).toDouble(),
      (j['w'] as num).toDouble(),
      (j['h'] as num).toDouble(),
    ),
  );
}

/// A student's sheet: the colour of each unit (-1 for none), the elements, the grid step in degrees (0 for none), the title.
class Sheet {
  final List<int> fills;
  final List<SheetElement> elements;
  double grid;
  String title;
  Sheet(this.fills, this.elements, {this.grid = 0, this.title = ''});

  factory Sheet.empty(int units) => Sheet(List.filled(units, -1), []);

  SheetElement? element(String kind) => elements.where((e) => e.kind == kind).firstOrNull;

  Map<String, dynamic> toJson() => {
    'fills': fills,
    'elements': [for (final e in elements) e.toJson()],
    'grid': grid == grid.roundToDouble() ? grid.round() : grid,
    'title': title,
  };

  factory Sheet.fromJson(Map<String, dynamic> j, int units) {
    final fills = [for (final v in j['fills'] as List? ?? const []) v as int];
    return Sheet(
      fills.length == units ? fills : List.filled(units, -1),
      [
        for (final e in j['elements'] as List? ?? const [])
          if (layoutElements.contains((e as Map<String, dynamic>)['kind'])) SheetElement.fromJson(e),
      ],
      grid: (j['grid'] as num? ?? 0).toDouble(),
      title: j['title'] as String? ?? '',
    );
  }
}

/// The same score the server gives: 70 for the colouring, 6 for each element on the page and 6 for the grid.
int layoutScore(List<int> legend, Sheet sheet) {
  var right = 0;
  for (var i = 0; i < legend.length; i++) {
    if (i < sheet.fills.length && sheet.fills[i] == legend[i]) right++;
  }
  final placed = sheet.elements.where((e) {
    final c = e.rect.center;
    return c.dx >= 0 && c.dx <= 1 && c.dy >= 0 && c.dy <= 1 && (e.kind != 'title' || sheet.title.isNotEmpty);
  }).length;
  return (70 * right / max(1, legend.length)).round() + 6 * placed + (sheet.grid > 0 ? 6 : 0);
}

/// The map of the sheet: the units and the fixed areas projected into the map frame, and its real scale.
class SheetMap {
  final List<GeoUnit> units;
  final List<List<List<Offset>>> rings; // per unit, in page units (width 1)
  final List<List<List<Offset>>> fixed;
  final Rect frame; // in page units
  final Rect world; // the frame in Mercator pixels at zoom 0
  final double scaleDenominator; // 1 : n on A4

  const SheetMap(this.units, this.rings, this.fixed, this.frame, this.world, this.scaleDenominator);

  factory SheetMap.of(GeoUnits all, String area) {
    final units = layoutUnits(all, area);
    final fixedUnits = area == 'georgia' ? all.fixed : const <GeoUnit>[];
    final frame = Rect.fromLTWH(mapFrame.left, mapFrame.top * pageAspect, mapFrame.width, mapFrame.height * pageAspect);
    final points = [
      for (final u in [...units, ...fixedUnits])
        for (final r in u.rings)
          for (final p in r) mercator(p, 0),
    ];
    var b = Rect.fromLTRB(
      points.map((p) => p.dx).reduce(min),
      points.map((p) => p.dy).reduce(min),
      points.map((p) => p.dx).reduce(max),
      points.map((p) => p.dy).reduce(max),
    );
    b = b.inflate(max(b.width, b.height) * 0.04);
    // The world seen in the frame: the area's box widened to the frame's shape, so nothing is stretched.
    final k = min(frame.width / b.width, frame.height / b.height);
    final world = Rect.fromCenter(center: b.center, width: frame.width / k, height: frame.height / k);
    Offset place(Offset lonLat) => frame.topLeft + (mercator(lonLat, 0) - world.topLeft) * k;
    List<List<Offset>> project(GeoUnit u) => [
      for (final r in u.rings) [for (final p in r) place(p)],
    ];
    // Metres on the ground per Mercator pixel at the middle latitude, and so the scale on paper.
    final lat = _latitude(world.center.dy);
    final metresPerPixel = 40075016.686 * cos(lat * pi / 180) / 256;
    final scale = metresPerPixel / k / _pageWidthM;
    return SheetMap(
      units,
      [for (final u in units) project(u)],
      [for (final u in fixedUnits) project(u)],
      frame,
      world,
      scale,
    );
  }

  /// Which unit is at a point of the page, if any.
  int? unitAt(Offset page) {
    if (!frame.contains(page)) return null;
    for (var i = 0; i < rings.length; i++) {
      if (insideRings(page, rings[i])) return i;
    }
    return null;
  }

  /// Page position of a longitude and latitude.
  Offset place(Offset lonLat) => frame.topLeft + (mercator(lonLat, 0) - world.topLeft) * (frame.width / world.width);

  Rect get lonLatBounds {
    final tl = _lonLat(world.topLeft), br = _lonLat(world.bottomRight);
    return Rect.fromLTRB(tl.dx, br.dy, br.dx, tl.dy);
  }
}

double _latitude(double y) => (2 * atan(exp(pi * (1 - 2 * y / 256))) - pi / 2) * 180 / pi;
Offset _lonLat(Offset world) => Offset(world.dx / 256 * 360 - 180, _latitude(world.dy));

/// A round number of kilometres for a scale bar no longer than [maxKm].
double niceKm(double maxKm) {
  final p = pow(10, (log(maxKm) / ln10).floor()).toDouble();
  for (final f in const [5, 2, 1]) {
    if (f * p <= maxKm) return f * p;
  }
  return p;
}

String formatScale(double n) {
  final step = n > 1e6 ? 100000.0 : 10000.0;
  final r = (n / step).round() * step;
  final digits = r.round().toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return '1 : $out';
}

/// Draws a whole sheet. The same painting goes on screen, to the teacher and into the PDF.
class SheetPainter extends CustomPainter {
  final SheetMap map;
  final Sheet sheet;
  final List<int> legend;
  final String lang;
  final String? selected; // an element with handles, on screen only
  SheetPainter({required this.map, required this.sheet, required this.legend, required this.lang, this.selected});

  @override
  void paint(Canvas canvas, Size size) => paintSheet(canvas, size, map, sheet, legend, lang, selected: selected);

  @override
  bool shouldRepaint(SheetPainter old) => true;
}

const _ink = Color(0xFF1B1F23);

void paintSheet(
  Canvas canvas,
  Size size,
  SheetMap map,
  Sheet sheet,
  List<int> legend,
  String lang, {
  String? selected,
}) {
  final w = size.width;
  // Page units to pixels: the page is 1 wide; elements are in parts of the width and of the height.
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  canvas.save();
  canvas.scale(w);
  final px = 1 / w;
  final frame = map.frame;

  canvas.save();
  canvas.clipRect(frame);
  canvas.drawRect(frame, Paint()..color = const Color(0xFFF4F6F8));
  for (final r in map.fixed) {
    canvas.drawPath(_path(r), Paint()..color = const Color(0xFFD9DCE0));
  }
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2 * px
    ..strokeJoin = StrokeJoin.round
    ..color = _ink;
  for (var i = 0; i < map.rings.length; i++) {
    final f = sheet.fills[i];
    final path = _path(map.rings[i]);
    canvas.drawPath(path, Paint()..color = f >= 0 && f < layoutPalette.length ? layoutPalette[f] : Colors.white);
    canvas.drawPath(path, line);
  }
  for (final r in map.fixed) {
    canvas.drawPath(_path(r), line..color = const Color(0xFF6B7280));
  }
  if (sheet.grid > 0) _grid(canvas, map, sheet.grid, px);
  canvas.restore();
  canvas.drawRect(
    frame,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * px
      ..color = _ink,
  );
  if (sheet.grid > 0) _gridLabels(canvas, map, sheet.grid, px);

  // The outlines are OpenStreetMap data: the credit goes on every sheet and every print.
  _text(
    canvas,
    '© OpenStreetMap contributors',
    Rect.fromLTWH(frame.right - 0.3, frame.bottom + 0.002, 0.3, 0.018),
    size: 0.011,
    color: const Color(0xFF6B7280),
    align: TextAlign.right,
  );

  for (final e in sheet.elements) {
    final r = Rect.fromLTWH(e.rect.left, e.rect.top * pageAspect, e.rect.width, e.rect.height * pageAspect);
    switch (e.kind) {
      case 'title':
        _text(
          canvas,
          sheet.title.isEmpty ? '…' : sheet.title,
          r,
          size: r.height * 0.6,
          bold: true,
          color: sheet.title.isEmpty ? const Color(0xFF9AA0A6) : _ink,
        );
      case 'north':
        _north(canvas, r, px);
      case 'legend':
        _legend(canvas, r, map, legend, lang, px);
      case 'scale':
        _scale(canvas, r, map, px);
    }
    if (selected == e.kind) {
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * px
          ..color = const Color(0xFF1E88E5),
      );
    }
  }
  canvas.restore();
}

Path _path(List<List<Offset>> rings) {
  final p = Path()..fillType = PathFillType.evenOdd;
  for (final r in rings) {
    p.addPolygon(r, true);
  }
  return p;
}

Iterable<double> _steps(double from, double to, double step) sync* {
  for (var v = (from / step).ceil() * step; v <= to; v += step) {
    yield v;
  }
}

void _grid(Canvas canvas, SheetMap map, double step, double px) {
  final b = map.lonLatBounds;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8 * px
    ..color = const Color(0x993C6E9E);
  for (final lon in _steps(b.left, b.right, step)) {
    canvas.drawLine(map.place(Offset(lon, b.top)), map.place(Offset(lon, b.bottom)), paint);
  }
  for (final lat in _steps(b.top, b.bottom, step)) {
    canvas.drawLine(map.place(Offset(b.left, lat)), map.place(Offset(b.right, lat)), paint);
  }
}

String _degrees(double v) => v == v.roundToDouble() ? '${v.round()}°' : '${v.floor()}°30′';

void _gridLabels(Canvas canvas, SheetMap map, double step, double px) {
  final b = map.lonLatBounds;
  final f = map.frame;
  final size = 9 * px * 1.2;
  for (final lon in _steps(b.left, b.right, step)) {
    final x = map.place(Offset(lon, b.top)).dx;
    if (x < f.left + 0.01 || x > f.right - 0.01) continue;
    _text(
      canvas,
      '${_degrees(lon)}E',
      Rect.fromCenter(center: Offset(x, f.top - size), width: 0.06, height: size * 1.6),
      size: size,
    );
  }
  for (final lat in _steps(b.top, b.bottom, step)) {
    final y = map.place(Offset(b.left, lat)).dy;
    if (y < f.top + 0.01 || y > f.bottom - 0.01) continue;
    _text(
      canvas,
      '${_degrees(lat)}N',
      Rect.fromLTWH(f.right + 0.003, y - size, 0.05, size * 2),
      size: size,
      align: TextAlign.left,
    );
  }
}

void _text(
  Canvas canvas,
  String text,
  Rect r, {
  required double size,
  bool bold = false,
  Color color = _ink,
  TextAlign align = TextAlign.center,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        height: 1.15,
      ),
    ),
    textAlign: align,
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: r.width);
  final dx = switch (align) {
    TextAlign.left => r.left,
    TextAlign.right => r.right - painter.width,
    _ => r.left + (r.width - painter.width) / 2,
  };
  painter.paint(canvas, Offset(dx, r.top + (r.height - painter.height) / 2));
  painter.dispose();
}

void _north(Canvas canvas, Rect r, double px) {
  final s = min(r.width, r.height);
  final c = Offset(r.center.dx, r.top + r.height * 0.6);
  final h = r.height * 0.62;
  final half = s * 0.3;
  final left = Path()
    ..moveTo(c.dx, c.dy - h / 2)
    ..lineTo(c.dx - half, c.dy + h / 2)
    ..lineTo(c.dx, c.dy + h / 4)
    ..close();
  final right = Path()
    ..moveTo(c.dx, c.dy - h / 2)
    ..lineTo(c.dx + half, c.dy + h / 2)
    ..lineTo(c.dx, c.dy + h / 4)
    ..close();
  canvas.drawPath(left, Paint()..color = _ink);
  canvas.drawPath(right, Paint()..color = Colors.white);
  canvas.drawPath(
    right,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * px
      ..color = _ink,
  );
  _text(canvas, 'N', Rect.fromLTWH(r.left, r.top, r.width, r.height * 0.28), size: r.height * 0.22, bold: true);
}

void _legend(Canvas canvas, Rect r, SheetMap map, List<int> legend, String lang, double px) {
  canvas.drawRect(r, Paint()..color = Colors.white);
  canvas.drawRect(
    r,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 * px
      ..color = _ink,
  );
  final rows = legend.length + 1;
  final row = r.height / rows;
  final size = row * 0.55;
  _text(
    canvas,
    lang == 'ka' ? 'პირობითი ნიშნები' : 'Legend',
    Rect.fromLTWH(r.left, r.top, r.width, row),
    size: size,
    bold: true,
  );
  for (var i = 0; i < legend.length; i++) {
    final y = r.top + row * (i + 1);
    final box = Rect.fromLTWH(r.left + row * 0.35, y + row * 0.18, row * 1.1, row * 0.64);
    canvas.drawRect(box, Paint()..color = layoutPalette[legend[i] % layoutPalette.length]);
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 * px
        ..color = _ink,
    );
    _text(
      canvas,
      map.units[i].name(lang),
      Rect.fromLTRB(box.right + row * 0.3, y, r.right - row * 0.2, y + row),
      size: size,
      align: TextAlign.left,
    );
  }
}

void _scale(Canvas canvas, Rect r, SheetMap map, double px) {
  // The ground under the element's width, and a round number of kilometres that fits in it.
  final km = r.width * _pageWidthM * map.scaleDenominator / 1000;
  final bar = niceKm(km * 0.85);
  final length = r.width * bar / km;
  final y = r.top + r.height * 0.55;
  final left = r.left + (r.width - length) / 2;
  final thick = r.height * 0.14;
  for (var i = 0; i < 4; i++) {
    canvas.drawRect(
      Rect.fromLTWH(left + length * i / 4, y - thick / 2, length / 4, thick),
      Paint()..color = i.isEven ? _ink : Colors.white,
    );
  }
  canvas.drawRect(
    Rect.fromLTWH(left, y - thick / 2, length, thick),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * px
      ..color = _ink,
  );
  final size = r.height * 0.24;
  String n(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
  _text(
    canvas,
    '0',
    Rect.fromCenter(center: Offset(left, y + thick * 1.8), width: 0.04, height: size * 1.4),
    size: size,
  );
  _text(
    canvas,
    '${n(bar)} km',
    Rect.fromCenter(center: Offset(left + length, y + thick * 1.8), width: 0.08, height: size * 1.4),
    size: size,
  );
  _text(canvas, formatScale(map.scaleDenominator), Rect.fromLTWH(r.left, r.top, r.width, r.height * 0.34), size: size);
}

/// The sheet as an A4 PDF: the page painted at about 200 dpi, filling a landscape page.
Future<Uint8List> sheetPdf(SheetMap map, Sheet sheet, List<int> legend, String lang) async {
  const width = 2339.0;
  final size = Size(width, width * pageAspect);
  final recorder = ui.PictureRecorder();
  paintSheet(Canvas(recorder, Offset.zero & size), size, map, sheet, legend, lang);
  final image = recorder.endRecording().toImageSync(size.width.round(), size.height.round());
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  final doc = pw.Document(title: sheet.title.isEmpty ? 'GeoClass' : sheet.title, creator: 'GeoClass');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.FullPage(ignoreMargins: true, child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill)),
    ),
  );
  return doc.save();
}
