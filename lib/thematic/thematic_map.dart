import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../l10n.dart';
import '../puzzle.dart' show GeoUnit, GeoUnits, mercator;
import 'ramps.dart';
import 'thematic.dart';

/// Grey for units without data and for the parts of Georgia a level doesn't divide.
const thematicNoData = Color(0xffd9d9d9);
const _fixedFill = Color(0xffeeeeee);
const _ink = Color(0xff1b1f23);

/// The units of a session in its order, their areas, and the grey surround, worked out once per page.
class ThematicBase {
  final List<GeoUnit?> units; // as the settings list them; null for an id the app doesn't know
  final List<double> areas; // km², 0 for unknown units
  final List<GeoUnit> others; // the level's units the table has no row for
  final List<GeoUnit> fixed;
  const ThematicBase(this.units, this.areas, this.others, this.fixed);

  factory ThematicBase.of(GeoUnits all, ThematicSettings s) {
    final level = levelUnits(all, s.level);
    final byId = {for (final u in level) u.id: u};
    final units = [for (final id in s.units) byId[id]];
    final listed = s.units.toSet();
    return ThematicBase(
      units,
      [for (final u in units) u == null ? 0.0 : unitAreaKm2(u)],
      [
        for (final u in level)
          if (!listed.contains(u.id)) u,
      ],
      levelFixed(all, s.level),
    );
  }
}

/// A choice drawn: the fill of each unit, the legend's rows and the field's caption.
class ThematicView {
  final ThematicBase base;
  final ThematicSettings settings;
  final ThematicChoice choice;
  final Classified? classified;
  const ThematicView(this.base, this.settings, this.choice, this.classified);

  factory ThematicView.of(ThematicBase base, ThematicSettings s, ThematicChoice c) =>
      ThematicView(base, s, c, classify(s, c, base.areas));

  List<Color> get colours => thematicRamps[choice.ramp]![classified?.uppers.length.clamp(3, 7) ?? choice.classes]!;

  Color fillOf(int i) {
    final k = classified?.classOfUnit[i];
    return k == null ? thematicNoData : colours[math.min(k, colours.length - 1)];
  }

  /// The field's name, with "per km²" when shown so.
  String caption(S s) {
    final name = settings.fields[choice.field].name;
    return choice.normalise == 'area' ? s.f('thematic_per_area', [name]) : name;
  }

  /// One row per class: its range and how many units are in it; then "no data" if any unit has none.
  List<({Color colour, String label})> legend(S s) {
    final c = classified;
    if (c == null) return [(colour: thematicNoData, label: s['thematic_no_data'])];
    final rows = <({Color colour, String label})>[];
    for (var i = 0; i < c.uppers.length; i++) {
      final lo = i == 0 ? c.range[0] : c.uppers[i - 1];
      rows.add((
        colour: colours[math.min(i, colours.length - 1)],
        label: '${legendNumber(lo)} – ${legendNumber(c.uppers[i])} (${c.counts[i]})',
      ));
    }
    final gaps = c.classOfUnit.where((k) => k == null).length;
    if (gaps > 0) rows.add((colour: thematicNoData, label: '${s['thematic_no_data']} ($gaps)'));
    return rows;
  }

  /// The method as a line: "Quantile, 5 classes".
  String methodText(S s) => s.f('thematic_method_line', [s['thematic_method_${choice.method}'], choice.classes]);
}

/// The units' outlines placed in a box: Web Mercator, fitted with a margin, nothing stretched.
class _Placed {
  final List<Path> units, others, fixed;
  const _Placed(this.units, this.others, this.fixed);

  factory _Placed.of(ThematicBase b, Rect box) {
    final all = [...b.units.whereType<GeoUnit>(), ...b.others, ...b.fixed];
    final pts = [
      for (final u in all)
        for (final r in u.rings)
          for (final p in r) mercator(p, 0),
    ];
    if (pts.isEmpty) return const _Placed([], [], []);
    var bounds = Rect.fromLTRB(
      pts.map((p) => p.dx).reduce(math.min),
      pts.map((p) => p.dy).reduce(math.min),
      pts.map((p) => p.dx).reduce(math.max),
      pts.map((p) => p.dy).reduce(math.max),
    );
    bounds = bounds.inflate(math.max(bounds.width, bounds.height) * 0.02);
    final k = math.min(box.width / bounds.width, box.height / bounds.height);
    final offset = box.center - bounds.center * k;
    Path path(GeoUnit? u) {
      final p = Path()..fillType = PathFillType.evenOdd;
      if (u == null) return p;
      for (final r in u.rings) {
        p.addPolygon([for (final q in r) mercator(q, 0) * k + offset], true);
      }
      return p;
    }

    return _Placed([for (final u in b.units) path(u)], [for (final u in b.others) path(u)], [
      for (final u in b.fixed) path(u),
    ]);
  }
}

void _paintMap(Canvas canvas, Rect box, ThematicView v, _Placed placed, double px, {int? selected}) {
  final fill = Paint()..style = PaintingStyle.fill;
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xff555555)
    ..strokeWidth = 0.6 * px
    ..strokeJoin = StrokeJoin.round;
  for (final p in placed.fixed) {
    canvas.drawPath(p, fill..color = _fixedFill);
    canvas.drawPath(p, line);
  }
  for (final p in placed.others) {
    canvas.drawPath(p, fill..color = thematicNoData);
    canvas.drawPath(p, line);
  }
  for (var i = 0; i < placed.units.length; i++) {
    canvas.drawPath(placed.units[i], fill..color = v.fillOf(i));
    canvas.drawPath(placed.units[i], line);
  }
  if (selected != null && selected < placed.units.length) {
    canvas.drawPath(
      placed.units[selected],
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _ink
        ..strokeWidth = 2.5 * px,
    );
  }
}

class _MapPainter extends CustomPainter {
  final ThematicView view;
  final int? selected;
  _Placed? _placed;
  Size? _size;
  _MapPainter(this.view, this.selected);

  _Placed placed(Size size) {
    if (_placed == null || _size != size) {
      _placed = _Placed.of(view.base, Offset.zero & size);
      _size = size;
    }
    return _placed!;
  }

  @override
  void paint(Canvas canvas, Size size) =>
      _paintMap(canvas, Offset.zero & size, view, placed(size), 1, selected: selected);

  @override
  bool shouldRepaint(_MapPainter old) => old.view != view || old.selected != selected;
}

/// The choropleth on screen. A touch on a unit shows its name and value.
class ChoroplethView extends StatefulWidget {
  final ThematicView view;
  final S s;
  final String lang;
  const ChoroplethView({super.key, required this.view, required this.s, required this.lang});

  @override
  State<ChoroplethView> createState() => _ChoroplethViewState();
}

class _ChoroplethViewState extends State<ChoroplethView> {
  int? _selected;
  late _MapPainter _painter = _MapPainter(widget.view, _selected);

  @override
  void didUpdateWidget(ChoroplethView old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) _painter = _MapPainter(widget.view, _selected);
  }

  void _tap(Offset at, Size size) {
    final placed = _painter.placed(size);
    final hit = placed.units.indexWhere((p) => p.contains(at));
    setState(() {
      _selected = hit < 0 || hit == _selected ? null : hit;
      _painter = _MapPainter(widget.view, _selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view, s = widget.s;
    final i = _selected;
    final value = i == null ? null : v.classified?.values[i];
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          GestureDetector(
            onTapUp: (d) => _tap(d.localPosition, box.biggest),
            child: CustomPaint(key: const Key('thematic_map'), size: box.biggest, painter: _painter),
          ),
          if (i != null)
            Positioned(
              left: 8,
              top: 8,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    '${v.base.units[i]?.name(widget.lang) ?? v.settings.units[i]}: '
                    '${value == null ? s['thematic_no_data'] : legendNumber(value)}',
                    key: const Key('thematic_unit'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The legend as a column of swatches.
class ThematicLegend extends StatelessWidget {
  final ThematicView view;
  final S s;
  const ThematicLegend({super.key, required this.view, required this.s});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(view.caption(s), style: text.titleSmall),
        Text(view.methodText(s), style: text.bodySmall),
        const SizedBox(height: 4),
        for (final row in view.legend(s))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 14,
                  decoration: BoxDecoration(
                    color: row.colour,
                    border: Border.all(color: const Color(0xff555555), width: 0.5),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(row.label, style: text.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}

void _text(Canvas canvas, String t, Offset at, double size, {bool bold = false, double? width, Color colour = _ink}) {
  final p = TextPainter(
    text: TextSpan(
      text: t,
      style: TextStyle(color: colour, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width ?? double.infinity);
  p.paint(canvas, at);
}

/// The map as an A4 landscape page: title, the map, the legend, the method and the sources.
void paintThematicPage(Canvas canvas, Size size, ThematicView v, S s, String title) {
  final px = size.width / 1000;
  canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  _text(canvas, title.isEmpty ? v.caption(s) : title, Offset(30 * px, 22 * px), 30 * px, bold: true, width: 940 * px);
  final mapBox = Rect.fromLTWH(30 * px, 80 * px, 680 * px, size.height - 140 * px);
  _paintMap(canvas, mapBox, v, _Placed.of(v.base, mapBox), px);
  var y = 90 * px;
  final x = 735 * px;
  _text(canvas, v.caption(s), Offset(x, y), 16 * px, bold: true, width: 240 * px);
  y += 44 * px;
  _text(canvas, v.methodText(s), Offset(x, y), 13 * px, width: 240 * px);
  y += 30 * px;
  for (final row in v.legend(s)) {
    final r = Rect.fromLTWH(x, y, 34 * px, 20 * px);
    canvas.drawRect(r, Paint()..color = row.colour);
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xff555555)
        ..strokeWidth = 0.8 * px,
    );
    _text(canvas, row.label, Offset(x + 44 * px, y + 1 * px), 13 * px, width: 200 * px);
    y += 28 * px;
  }
  _text(
    canvas,
    s['thematic_pdf_sources'],
    Offset(30 * px, size.height - 44 * px),
    10 * px,
    width: 940 * px,
    colour: const Color(0xff555555),
  );
}

/// The page as a PDF, painted at about 200 dpi.
Future<Uint8List> thematicPdf(ThematicView v, S s, String title) async {
  const width = 2339.0;
  final size = Size(width, width * 210 / 297);
  final recorder = ui.PictureRecorder();
  paintThematicPage(Canvas(recorder, Offset.zero & size), size, v, s, title);
  final image = recorder.endRecording().toImageSync(size.width.round(), size.height.round());
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  final doc = pw.Document(title: title.isEmpty ? 'GeoClass' : title, creator: 'GeoClass');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.FullPage(ignoreMargins: true, child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill)),
    ),
  );
  return doc.save();
}

/// What a student chooses: the field, per km² or not, the method, the classes and the ramp; manual breaks.
class ThematicChoiceEditor extends StatefulWidget {
  final ThematicSettings settings;
  final ThematicBase base;
  final ThematicChoice choice;
  final ValueChanged<ThematicChoice> onChanged;
  final S s;

  /// The teacher's target: no manual breaks.
  final bool target;
  const ThematicChoiceEditor({
    super.key,
    required this.settings,
    required this.base,
    required this.choice,
    required this.onChanged,
    required this.s,
    this.target = false,
  });

  @override
  State<ThematicChoiceEditor> createState() => _ThematicChoiceEditorState();
}

class _ThematicChoiceEditorState extends State<ThematicChoiceEditor> {
  S get s => widget.s;
  ThematicChoice get c => widget.choice;
  final _breaks = <TextEditingController>[];
  String? _breakError;

  @override
  void dispose() {
    for (final t in _breaks) {
      t.dispose();
    }
    super.dispose();
  }

  /// Manual breaks start from equal intervals of what is shown.
  List<double> _startBreaks(ThematicChoice c) {
    final k = classify(widget.settings, c.copyWith(method: 'equal'), widget.base.areas);
    if (k == null) return List.generate(c.classes - 1, (i) => i + 1.0);
    return [for (final b in k.uppers.take(c.classes - 1)) double.parse(b.toStringAsPrecision(3))];
  }

  void _change(ThematicChoice next) {
    if (next.method == 'manual' &&
        (c.method != 'manual' ||
            next.classes != c.classes ||
            next.field != c.field ||
            next.normalise != c.normalise ||
            next.breaks == null)) {
      final b = _startBreaks(next);
      next = next.copyWith(breaks: b);
      for (final t in _breaks) {
        t.dispose();
      }
      _breaks
        ..clear()
        ..addAll([for (final x in b) TextEditingController(text: legendNumber(x))]);
      _breakError = null;
    }
    widget.onChanged(next);
  }

  void _typed() {
    final b = [for (final t in _breaks) parseNumber(t.text)];
    final ok =
        b.every((x) => x != null && !x.isNaN) && [for (var i = 1; i < b.length; i++) b[i]! > b[i - 1]!].every((x) => x);
    setState(() => _breakError = ok ? null : s['thematic_breaks_bad']);
    if (ok) widget.onChanged(c.copyWith(breaks: [for (final x in b) x!]));
  }

  Widget _chips<T>(
    String label,
    List<T> options,
    T selected,
    String Function(T) name,
    ValueChanged<T> pick,
    String key,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final o in options)
              ChoiceChip(
                key: Key('${key}_$o'),
                label: Text(name(o)),
                selected: o == selected,
                onSelected: (_) => pick(o),
              ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final fields = widget.settings.fields;
    final methods = widget.target ? thematicMethods.where((m) => m != 'manual').toList() : thematicMethods;
    final counts = fields[c.field].kind == 'count' && c.normalise == 'none';
    if (c.method == 'manual' && _breaks.length != c.classes - 1) {
      final b = c.breaks ?? _startBreaks(c);
      _breaks
        ..clear()
        ..addAll([for (final x in b) TextEditingController(text: legendNumber(x))]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chips(
          s['thematic_field'],
          [for (var i = 0; i < fields.length; i++) i],
          c.field,
          (i) => fields[i].name,
          (i) => _change(c.copyWith(field: i)),
          'thematic_field',
        ),
        _chips(
          s['thematic_normalise'],
          thematicNormalisations,
          c.normalise,
          (n) => s['thematic_normalise_$n'],
          (n) => _change(c.copyWith(normalise: n)),
          'thematic_normalise',
        ),
        if (counts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s['thematic_warn_counts'],
              key: const Key('thematic_warn_counts'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        _chips(
          s['thematic_method'],
          methods,
          c.method,
          (m) => s['thematic_method_$m'],
          (m) => _change(c.copyWith(method: m)),
          'thematic_method',
        ),
        _chips(
          s['thematic_classes'],
          [for (var k = thematicClassesMin; k <= thematicClassesMax; k++) k],
          c.classes,
          (k) => '$k',
          (k) => _change(c.copyWith(classes: k)),
          'thematic_classes',
        ),
        if (c.method == 'manual')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(s['thematic_breaks']),
                for (var i = 0; i < _breaks.length; i++)
                  SizedBox(
                    width: 90,
                    child: TextField(
                      key: Key('thematic_break_$i'),
                      controller: _breaks[i],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                      onChanged: (_) => _typed(),
                    ),
                  ),
                if (_breakError != null)
                  Text(_breakError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        Text(s['thematic_ramp'], style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final r in thematicRamps.keys)
              ChoiceChip(
                key: Key('thematic_ramp_$r'),
                selected: r == c.ramp,
                onSelected: (_) => _change(c.copyWith(ramp: r)),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (final col in thematicRamps[r]![5]!) Container(width: 10, height: 14, color: col)],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The same data in three classifications side by side, as the lesson compares them.
class ThematicCompare extends StatelessWidget {
  final ThematicBase base;
  final ThematicSettings settings;
  final ThematicChoice choice;
  final S s;
  final String lang;
  const ThematicCompare({
    super.key,
    required this.base,
    required this.settings,
    required this.choice,
    required this.s,
    required this.lang,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 700;
      final cards = [
        for (final m in ['equal', 'quantile', 'jenks'])
          () {
            final v = ThematicView.of(base, settings, choice.copyWith(method: m));
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s['thematic_method_$m'], style: Theme.of(context).textTheme.titleSmall),
                    SizedBox(
                      height: 200,
                      child: ChoroplethView(view: v, s: s, lang: lang),
                    ),
                    ThematicLegend(view: v, s: s),
                  ],
                ),
              ),
            );
          }(),
      ];
      return wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final c in cards) Expanded(child: c)],
            )
          : Column(children: cards);
    },
  );
}
