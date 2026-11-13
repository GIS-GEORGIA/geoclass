import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../coords.dart';
import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'slope.dart';

/// The steepness thresholds a teacher can pick, in degrees. worker/src/games/slope.ts has the same list.
const slopeThresholds = [5, 15, 30];

/// The box of n × n squares on an area's grid, each square [cells] × [cells] grid cells, its top-left cell at
/// [row], [col]. Squares are numbered row by row from the north-west corner.
class SlopeBox {
  final int row, col, cells, n;
  const SlopeBox(this.row, this.col, this.cells, this.n);

  factory SlopeBox.fromJson(Map<String, dynamic> j) =>
      SlopeBox(j['row'] as int, j['col'] as int, j['cells'] as int, j['n'] as int);

  Map<String, dynamic> toJson() => {'row': row, 'col': col, 'cells': cells, 'n': n};

  int get side => cells * n;

  /// A box of [n] squares of [cells] cells centred as near [centre] as the grid allows, a cell clear of its
  /// edge (where there is no slope). Null when the grid is too small for it.
  static SlopeBox? around(ElevationGrid g, LatLng centre, {required int cells, required int n}) {
    final side = cells * n;
    if (side + 2 > g.width || side + 2 > g.height) return null;
    final u = toUtm(centre.latitude, centre.longitude, zone: g.meta.zone);
    final col = ((u.easting - g.meta.bounds[0]) / g.cell - side / 2).round().clamp(1, g.width - 1 - side);
    final row = ((g.meta.bounds[3] - u.northing) / g.cell - side / 2).round().clamp(1, g.height - 1 - side);
    return SlopeBox(row, col, cells, n);
  }

  LatLng _corner(ElevationGrid g, int r, int c) =>
      fromUtm(g.meta.zone, g.meta.bounds[0] + c * g.cell, g.meta.bounds[3] - r * g.cell);

  /// The corners of square [k] on the map, north-west first, clockwise.
  List<LatLng> square(ElevationGrid g, int k) {
    final r = row + (k ~/ n) * cells, c = col + (k % n) * cells;
    return [_corner(g, r, c), _corner(g, r, c + cells), _corner(g, r + cells, c + cells), _corner(g, r + cells, c)];
  }

  /// The whole box's corners on the map.
  List<LatLng> outline(ElevationGrid g) => [
    _corner(g, row, col),
    _corner(g, row, col + side),
    _corner(g, row + side, col + side),
    _corner(g, row + side, col),
  ];

  /// The square under a point of the map, or null outside the box.
  int? squareAt(ElevationGrid g, LatLng p) {
    final u = toUtm(p.latitude, p.longitude, zone: g.meta.zone);
    final fc = (u.easting - g.meta.bounds[0]) / g.cell - col;
    final fr = (g.meta.bounds[3] - u.northing) / g.cell - row;
    if (fc < 0 || fr < 0 || fc >= side || fr >= side) return null;
    return (fr ~/ cells) * n + fc ~/ cells;
  }

  /// Which squares are steeper than [threshold] degrees: those where more than half the cells are. Null when
  /// the box has cells without slope (off the grid, or by an empty cell), since those can't be judged.
  List<bool>? steep(ElevationGrid g, Float32List degrees, int threshold) {
    if (row < 1 || col < 1 || row + side > g.height - 1 || col + side > g.width - 1) return null;
    final out = List.filled(n * n, false);
    for (var k = 0; k < n * n; k++) {
      final r0 = row + (k ~/ n) * cells, c0 = col + (k % n) * cells;
      var over = 0;
      for (var r = r0; r < r0 + cells; r++) {
        for (var c = c0; c < c0 + cells; c++) {
          final v = degrees[r * g.width + c];
          if (v.isNaN) return null;
          if (v > threshold) over++;
        }
      }
      out[k] = over * 2 > cells * cells;
    }
    return out;
  }
}

/// Squares as the server keeps them: one character each, '1' marked.
String marksToString(List<bool> marks) => marks.map((m) => m ? '1' : '0').join();
List<bool> marksFromString(String s) => [for (var i = 0; i < s.length; i++) s[i] == '1'];

/// Intersection over union, times 100, as worker/src/games/slope.ts scores it.
int overlapScore(List<bool> marks, List<bool> answer) {
  var both = 0, either = 0;
  for (var i = 0; i < answer.length; i++) {
    final a = i < marks.length && marks[i], b = answer[i];
    if (a && b) both++;
    if (a || b) either++;
  }
  return either == 0 ? 100 : (100 * both / either).round();
}

/// The session's settings. [answer] only on the teacher's side and in the reply to an answer.
class SlopeGameSettings {
  final String areaId;
  final int areaVersion;
  final SlopeBox box;
  final int threshold;
  final List<bool>? answer;
  const SlopeGameSettings(this.areaId, this.areaVersion, this.box, this.threshold, {this.answer});

  factory SlopeGameSettings.fromJson(Map<String, dynamic> j) {
    try {
      final area = j['area'] as Map<String, dynamic>;
      final answer = j['answer'] as String?;
      return SlopeGameSettings(
        area['id'] as String,
        area['version'] as int,
        SlopeBox.fromJson(j['box'] as Map<String, dynamic>),
        j['threshold'] as int,
        answer: answer == null ? null : marksFromString(answer),
      );
    } on TypeError {
      throw const FormatException('bad slope settings');
    }
  }

  Map<String, dynamic> toJson() => {
    'area': {'id': areaId, 'version': areaVersion},
    'box': box.toJson(),
    'threshold': threshold,
    if (answer != null) 'answer': marksToString(answer!),
  };
}

/// The box's squares as map polygons: [fill] colours each square (null leaves it clear), [right] outlines the
/// right ones in white.
List<Widget> slopeBoxLayers(
  ElevationGrid g,
  SlopeBox box,
  ColorScheme scheme, {
  Color? Function(int k)? fill,
  List<bool>? right,
}) => [
  PolygonLayer(
    polygons: [
      for (var k = 0; k < box.n * box.n; k++)
        Polygon(
          points: box.square(g, k),
          color: fill?.call(k),
          borderColor: Colors.white.withValues(alpha: 0.5),
          borderStrokeWidth: 0.5,
        ),
    ],
  ),
  if (right != null)
    PolygonLayer(
      polygons: [
        for (var k = 0; k < box.n * box.n; k++)
          if (right[k]) Polygon(points: box.square(g, k), borderColor: Colors.white, borderStrokeWidth: 3),
      ],
    ),
  PolylineLayer(
    polylines: [
      Polyline(points: [...box.outline(g), box.outline(g).first], color: scheme.primary, strokeWidth: 3),
    ],
  ),
];

/// The teacher's setup: pick an area, place the box, pick the threshold. Returns the settings for the new
/// session, with the right squares worked out from the area's grid.
class SlopeSetupPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;

  /// Squares per box side, and the square sizes offered (in grid cells).
  final int n;
  final List<int> sizes;

  const SlopeSetupPage({
    super.key,
    required this.s,
    this.loader,
    this.n = slopeBoxSquares,
    this.sizes = slopeSquareCells,
  });

  @override
  State<SlopeSetupPage> createState() => _SlopeSetupPageState();
}

/// Square sizes the teacher can pick, in grid cells (30 m): 300 m, 450 m and 600 m.
const slopeSquareCells = [10, 15, 20];
const slopeBoxSquares = 10;

class _SlopeSetupPageState extends State<SlopeSetupPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  AreaSummary? _area;
  ElevationGrid? _grid;
  LatLng? _centre;
  late int _cells = widget.sizes[widget.sizes.length ~/ 2];
  int _threshold = 15;
  String? _error;

  S get s => widget.s;

  SlopeBox? get _box =>
      _grid == null || _centre == null ? null : SlopeBox.around(_grid!, _centre!, cells: _cells, n: widget.n);

  List<bool>? get _answer {
    final g = _grid, box = _box;
    return g == null || box == null ? null : box.steep(g, slopeOf(g), _threshold);
  }

  String? _problem() {
    if (_box == null) return 'slope_need_box';
    final a = _answer;
    if (a == null) return 'slope_need_inside';
    if (!a.contains(true)) return 'slope_need_steep';
    return null;
  }

  void _create() {
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final settings = SlopeGameSettings(_area!.id, _area!.version, _box!, _threshold, answer: _answer);
    Navigator.of(context).pop({'slope': settings.toJson()});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s['game_slope']),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(onPressed: _box == null ? null : _create, child: Text(s['create'])),
        ),
      ],
    ),
    body: FutureBuilder<List<AreaSummary>>(
      future: _catalog,
      builder: (context, snap) {
        if (snap.hasError) {
          final e = snap.error;
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s[e is DemError ? e.key : 'dem_bad_data']),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() {
                    _catalog = _loader.catalog();
                  }),
                  child: Text(s['retry']),
                ),
              ],
            ),
          );
        }
        final areas = snap.data;
        if (areas == null) return const Center(child: CircularProgressIndicator());
        final area = _area ??= areas.isEmpty ? null : areas.first;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final a in areas)
                    ChoiceChip(
                      label: Text(a.name(s.lang)),
                      selected: a.id == area?.id,
                      onSelected: (_) => setState(() {
                        _area = a;
                        _grid = null;
                        _centre = null;
                        _error = null;
                      }),
                    ),
                ],
              ),
            ),
            Expanded(
              child: area == null
                  ? Center(child: Text(s['dem_not_found']))
                  : AreaMap(
                      key: ValueKey('${area.id}/${area.version}'),
                      loader: _loader,
                      id: area.id,
                      version: area.version,
                      s: s,
                      builder: (context, grid) {
                        _grid = grid;
                        return _workspace(grid);
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );

  Widget _workspace(ElevationGrid grid) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final box = _box;
    final answer = _answer;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      slope: false,
      doubleTapZoom: false,
      onTap: (p, _) => setState(() {
        _centre = p;
        _error = null;
      }),
      layers: box == null
          ? const []
          : slopeBoxLayers(
              grid,
              box,
              scheme,
              fill: (k) => answer != null && answer[k] ? const Color(0xffd32f2f).withValues(alpha: 0.35) : null,
            ),
    );
    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(s['slope_setup_hint'], style: text.bodyMedium),
        const SizedBox(height: 12),
        Text(s['slope_threshold'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final t in slopeThresholds)
              ChoiceChip(
                label: Text(s.f('slope_degrees', [t])),
                selected: _threshold == t,
                onSelected: (_) => setState(() => _threshold = t),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(s['slope_square_size'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final c in widget.sizes)
              ChoiceChip(
                label: Text(s.f('profile_m', [(c * grid.cell).round()])),
                selected: _cells == c,
                onSelected: (_) => setState(() => _cells = c),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (answer != null)
          Text(
            s.f('slope_steep_count', [answer.where((x) => x).length, answer.length]),
            key: const Key('slope_steep_count'),
            style: text.bodyMedium,
          ),
        const SizedBox(height: 4),
        Text(s['slope_scoring'], style: text.bodySmall),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(s[_error!], style: TextStyle(color: scheme.error)),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 900
          ? Row(
              children: [
                Expanded(child: map),
                SizedBox(width: 380, child: side),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 3, child: map),
                Expanded(flex: 2, child: side),
              ],
            ),
    );
  }
}
