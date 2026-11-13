import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../coords.dart';
import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'slope_game.dart';
import 'viewshed.dart';

/// The observer heights a teacher can pick, in metres above the ground: a person, a house's roof or a small
/// tower, a lookout tower. worker/src/games/viewshed.ts has the same list.
const viewHeights = [1.7, 10.0, 30.0];

/// Targets per session, as the server allows them.
const viewTargetsMin = 3, viewTargetsMax = 8;

/// One cell of an area's grid.
class GridCell {
  final int row, col;
  const GridCell(this.row, this.col);

  factory GridCell.fromJson(Map<String, dynamic> j) => GridCell(j['row'] as int, j['col'] as int);
  Map<String, dynamic> toJson() => {'row': row, 'col': col};

  /// The cell under a point of the map, or null outside the grid.
  static GridCell? at(ElevationGrid g, LatLng p) {
    final u = toUtm(p.latitude, p.longitude, zone: g.meta.zone);
    final c = cellAtUtm(g, u.easting, u.northing);
    return c == null ? null : GridCell(c.row, c.col);
  }

  /// The cell's centre on the map.
  LatLng centre(ElevationGrid g) {
    final c = g.cellCentre(row, col);
    return fromUtm(g.meta.zone, c.x, c.y);
  }

  int distance(GridCell o) => (row - o.row).abs() > (col - o.col).abs() ? (row - o.row).abs() : (col - o.col).abs();

  @override
  bool operator ==(Object other) => other is GridCell && other.row == row && other.col == col;
  @override
  int get hashCode => Object.hash(row, col);
}

/// Whether each target is seen: null when one of them is on a cell without data.
List<bool>? targetsSeen(ElevationGrid g, Uint8List seen, List<GridCell> targets) {
  final out = <bool>[];
  for (final t in targets) {
    final v = seen[t.row * g.width + t.col];
    if (v == viewNone) return null;
    out.add(v == viewSeen);
  }
  return out;
}

/// Which squares of [box] are seen: those where more than half the cells are. Null when the box leaves the
/// grid or has cells without data, since those can't be judged.
List<bool>? squaresSeen(ElevationGrid g, Uint8List seen, SlopeBox box) {
  if (box.row < 0 || box.col < 0 || box.row + box.side > g.height || box.col + box.side > g.width) return null;
  final out = List.filled(box.n * box.n, false);
  for (var k = 0; k < box.n * box.n; k++) {
    final r0 = box.row + (k ~/ box.n) * box.cells, c0 = box.col + (k % box.n) * box.cells;
    var n = 0;
    for (var r = r0; r < r0 + box.cells; r++) {
      for (var c = c0; c < c0 + box.cells; c++) {
        final v = seen[r * g.width + c];
        if (v == viewNone) return null;
        if (v == viewSeen) n++;
      }
    }
    out[k] = n * 2 > box.cells * box.cells;
  }
  return out;
}

/// The share of targets judged right, × 100, as worker/src/games/viewshed.ts scores it.
int targetScore(List<bool> said, List<bool> answer) {
  var right = 0;
  for (var i = 0; i < answer.length; i++) {
    if (i < said.length && said[i] == answer[i]) right++;
  }
  return answer.isEmpty ? 0 : (100 * right / answer.length).round();
}

/// The session's settings. [answer] only on the teacher's side and in the reply to an answer.
class ViewshedGameSettings {
  final String areaId;
  final int areaVersion;
  final GridCell observer;
  final double height;

  /// 'targets' or 'squares'.
  final String kind;
  final List<GridCell> targets;
  final SlopeBox? box;
  final List<bool>? answer;

  const ViewshedGameSettings(
    this.areaId,
    this.areaVersion,
    this.observer,
    this.height, {
    this.kind = 'targets',
    this.targets = const [],
    this.box,
    this.answer,
  });

  bool get byTargets => kind == 'targets';

  /// How many things the student judges: targets, or squares.
  int get count => byTargets ? targets.length : box!.n * box!.n;

  factory ViewshedGameSettings.fromJson(Map<String, dynamic> j) {
    try {
      final area = j['area'] as Map<String, dynamic>;
      final kind = j['kind'] as String;
      final answer = j['answer'] as String?;
      final s = ViewshedGameSettings(
        area['id'] as String,
        area['version'] as int,
        GridCell.fromJson(j['observer'] as Map<String, dynamic>),
        (j['height'] as num).toDouble(),
        kind: kind,
        targets: kind == 'targets'
            ? [for (final t in j['targets'] as List) GridCell.fromJson(t as Map<String, dynamic>)]
            : const [],
        box: kind == 'squares' ? SlopeBox.fromJson(j['box'] as Map<String, dynamic>) : null,
        answer: answer == null ? null : marksFromString(answer),
      );
      if (kind != 'targets' && kind != 'squares') throw const FormatException('bad viewshed kind');
      if (s.answer != null && s.answer!.length != s.count) throw const FormatException('bad viewshed answer');
      return s;
    } on TypeError {
      throw const FormatException('bad viewshed settings');
    }
  }

  Map<String, dynamic> toJson() => {
    'area': {'id': areaId, 'version': areaVersion},
    'observer': observer.toJson(),
    'height': height,
    'kind': kind,
    if (byTargets) 'targets': [for (final t in targets) t.toJson()] else 'box': box!.toJson(),
    if (answer != null) 'answer': marksToString(answer!),
  };
}

/// What the observer sees, worked out once per observer and height and kept for the page's life.
class ViewshedCache {
  ElevationGrid? _grid;
  String? _key;
  Uint8List? _seen;

  Uint8List? of(ElevationGrid g, GridCell observer, double height) {
    final key = '${observer.row}/${observer.col}/$height';
    if (!identical(g, _grid) || key != _key) {
      _grid = g;
      _key = key;
      _seen = viewshed(g, observer.row, observer.col, observer: height);
    }
    return _seen;
  }
}

/// The seen ground as a map layer.
Widget viewshedLayer(ElevationGrid g, GridCell observer, double height, Uint8List seen) => gridOverlay(
  g.outline,
  GridImage(g, 'viewshed/${observer.row}/${observer.col}/$height', () => viewshedPixels(seen)),
  opacity: 0.45,
);

/// The observer on the map: an eye in a circle.
Widget observerLayer(ElevationGrid g, GridCell observer, ColorScheme scheme) => MarkerLayer(
  markers: [
    Marker(
      point: observer.centre(g),
      width: 34,
      height: 34,
      child: Container(
        key: const Key('view_observer'),
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(Icons.visibility, size: 18, color: scheme.onPrimary),
      ),
    ),
  ],
);

/// The targets on the map, numbered from 1. [colour] fills each (null: the theme's surface: not judged), [ring] draws a thick white ring round it (the right answer, after the student's).
Widget targetsLayer(
  ElevationGrid g,
  List<GridCell> targets,
  ColorScheme scheme, {
  Color? Function(int i)? colour,
  bool Function(int i)? ring,
  void Function(int i)? onTap,
}) => MarkerLayer(
  markers: [
    for (var i = 0; i < targets.length; i++)
      Marker(
        point: targets[i].centre(g),
        width: 40,
        height: 40,
        child: GestureDetector(
          onTap: onTap == null ? null : () => onTap(i),
          child: Container(
            key: Key('view_target_$i'),
            margin: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: colour?.call(i) ?? scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(
                color: ring?.call(i) == true ? Colors.white : scheme.outline,
                width: ring?.call(i) == true ? 4 : 1.5,
              ),
            ),
            alignment: Alignment.center,
            // The number always shows, so the map and the list of targets below it match.
            child: Text(
              '${i + 1}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colour?.call(i) == null ? scheme.onSurface : Colors.white,
              ),
            ),
          ),
        ),
      ),
  ],
);

/// Colour of a seen target or square: the viewshed's green; a hidden one is grey.
const viewSeenFill = Color(viewSeenColour);
const viewHiddenFill = Color(0xff616161);

/// The teacher's setup: pick an area, place the observer, pick its height, and either put targets or the box.
/// Returns the settings for the new session, with what is seen worked out from the area's grid.
class ViewshedSetupPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;

  /// Squares per box side, and the square sizes offered (in grid cells).
  final int n;
  final List<int> sizes;

  const ViewshedSetupPage({
    super.key,
    required this.s,
    this.loader,
    this.n = slopeBoxSquares,
    this.sizes = slopeSquareCells,
  });

  @override
  State<ViewshedSetupPage> createState() => _ViewshedSetupPageState();
}

class _ViewshedSetupPageState extends State<ViewshedSetupPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  final _cache = ViewshedCache();
  AreaSummary? _area;
  ElevationGrid? _grid;
  GridCell? _observer;
  double _height = viewHeights[1];
  String _kind = 'targets';

  /// What a touch on the map places: the observer, or the targets or the box.
  bool _placingObserver = true;
  final _targets = <GridCell>[];
  LatLng? _centre;
  late int _cells = widget.sizes[widget.sizes.length ~/ 2];
  bool _showSeen = true;
  String? _error;

  S get s => widget.s;

  Uint8List? get _seen {
    final g = _grid, o = _observer;
    return g == null || o == null ? null : _cache.of(g, o, _height);
  }

  SlopeBox? get _box =>
      _grid == null || _centre == null ? null : SlopeBox.around(_grid!, _centre!, cells: _cells, n: widget.n);

  List<bool>? get _answer {
    final g = _grid, seen = _seen;
    if (g == null || seen == null) return null;
    if (_kind == 'targets') return targetsSeen(g, seen, _targets);
    final box = _box;
    return box == null ? null : squaresSeen(g, seen, box);
  }

  String? _problem() {
    if (_observer == null) return 'view_need_observer';
    if (_kind == 'targets') {
      if (_targets.length < viewTargetsMin) return 'view_need_targets';
      if (_answer == null) return 'view_need_data';
    } else {
      if (_box == null) return 'slope_need_box';
      final a = _answer;
      if (a == null) return 'view_need_inside';
      if (!a.contains(true)) return 'view_need_seen';
    }
    return null;
  }

  void _create() {
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final settings = ViewshedGameSettings(
      _area!.id,
      _area!.version,
      _observer!,
      _height,
      kind: _kind,
      targets: List.of(_targets),
      box: _kind == 'squares' ? _box : null,
      answer: _answer,
    );
    Navigator.of(context).pop({'viewshed': settings.toJson()});
  }

  void _tap(ElevationGrid g, LatLng p, double? height) {
    final cell = GridCell.at(g, p);
    if (cell == null) return;
    setState(() {
      _error = null;
      if (_placingObserver) {
        if (height == null) {
          _error = 'view_need_data';
          return;
        }
        _observer = cell;
        _targets.remove(cell);
        _placingObserver = false;
      } else if (_kind == 'squares') {
        _centre = p;
      } else {
        // A touch by a target takes it away; elsewhere, adds one.
        final near = _targets.indexWhere((t) => t.distance(cell) <= 2);
        if (near >= 0) {
          _targets.removeAt(near);
        } else if (cell == _observer) {
          return;
        } else if (_targets.length < viewTargetsMax) {
          _targets.add(cell);
        } else {
          _error = 'view_targets_full';
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s['game_viewshed']),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(onPressed: _observer == null ? null : _create, child: Text(s['create'])),
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
                        _observer = null;
                        _targets.clear();
                        _centre = null;
                        _placingObserver = true;
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
    final seen = _seen;
    final answer = _answer;
    final box = _kind == 'squares' ? _box : null;
    final observer = _observer;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      // Targets go down with quick touches one after another.
      doubleTapZoom: false,
      onTap: (p, h) => _tap(grid, p, h),
      layers: [
        if (seen != null && _showSeen && observer != null) viewshedLayer(grid, observer, _height, seen),
        if (box != null)
          ...slopeBoxLayers(
            grid,
            box,
            scheme,
            fill: (k) => answer != null && answer[k] ? viewSeenFill.withValues(alpha: 0.4) : null,
          ),
        if (_kind == 'targets')
          targetsLayer(
            grid,
            _targets,
            scheme,
            colour: (i) => answer == null ? null : (answer[i] ? viewSeenFill : viewHiddenFill),
          ),
        if (observer != null) observerLayer(grid, observer, scheme),
      ],
    );
    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // At the top, where the teacher sees it without scrolling.
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              s[_error!],
              key: const Key('view_error'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        Text(s['view_setup_hint'], style: text.bodyMedium),
        const SizedBox(height: 12),
        Text(s['view_kind'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final k in const ['targets', 'squares'])
              ChoiceChip(
                label: Text(s['view_kind_$k']),
                selected: _kind == k,
                onSelected: (_) => setState(() {
                  _kind = k;
                  _error = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(s['view_place'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              key: const Key('view_place_observer'),
              avatar: const Icon(Icons.visibility, size: 18),
              label: Text(s['view_observer']),
              selected: _placingObserver,
              onSelected: (_) => setState(() => _placingObserver = true),
            ),
            ChoiceChip(
              key: const Key('view_place_second'),
              avatar: Icon(_kind == 'targets' ? Icons.place : Icons.grid_on, size: 18),
              label: Text(s[_kind == 'targets' ? 'view_targets' : 'view_box']),
              selected: !_placingObserver,
              onSelected: _observer == null ? null : (_) => setState(() => _placingObserver = false),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(s['view_height'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final h in viewHeights)
              ChoiceChip(
                label: Text(s.f('view_metres', [viewMetres(h)])),
                selected: _height == h,
                onSelected: (_) => setState(() => _height = h),
              ),
          ],
        ),
        if (_kind == 'squares') ...[
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
        ],
        SwitchListTile(
          key: const Key('view_show_seen'),
          contentPadding: EdgeInsets.zero,
          title: Text(s['view_show_seen']),
          value: _showSeen,
          onChanged: (v) => setState(() => _showSeen = v),
        ),
        if (answer != null)
          Text(
            s.f(_kind == 'targets' ? 'view_targets_seen' : 'view_squares_seen', [
              answer.where((x) => x).length,
              answer.length,
            ]),
            key: const Key('view_seen_count'),
            style: text.bodyMedium,
          ),
        const SizedBox(height: 4),
        Text(s[_kind == 'targets' ? 'view_scoring_targets' : 'view_scoring_squares'], style: text.bodySmall),
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

/// The observer's height as the pages write it: 1.7, 10, 30.
String viewMetres(double h) => h == h.roundToDouble() ? '${h.round()}' : '$h';
