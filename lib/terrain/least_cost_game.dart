import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'least_cost.dart';
import 'map_workspace.dart';
import 'viewshed_game.dart' show GridCell;

/// As worker/src/games/least_cost.ts: A and B at least this many cells apart, and the corners a route may have.
const routeMinApart = 10, routeCornersMax = 100;

/// The session's settings. [steps] (the best route) and [best] (its cost) only on the teacher's side and in the
/// reply to an answer.
class LeastCostGameSettings {
  final String areaId;
  final int areaVersion;
  final CostModel model;
  final GridCell start, end;
  final String? steps;
  final double? best;

  const LeastCostGameSettings(this.areaId, this.areaVersion, this.model, this.start, this.end, {this.steps, this.best});

  factory LeastCostGameSettings.fromJson(Map<String, dynamic> j) {
    try {
      final area = j['area'] as Map<String, dynamic>;
      return LeastCostGameSettings(
        area['id'] as String,
        area['version'] as int,
        CostModel.fromJson(j['model'] as Map<String, dynamic>),
        GridCell.fromJson(j['start'] as Map<String, dynamic>),
        GridCell.fromJson(j['end'] as Map<String, dynamic>),
        steps: j['steps'] as String?,
        best: (j['best'] as num?)?.toDouble(),
      );
    } on TypeError {
      throw const FormatException('bad least-cost settings');
    }
  }

  /// What the teacher's app sends: the server costs the route itself, from the area's heights.
  Map<String, dynamic> toJson() => {
    'area': {'id': areaId, 'version': areaVersion},
    'model': model.toJson(),
    'start': start.toJson(),
    'end': end.toJson(),
    'steps': ?steps,
  };
}

/// A cost as the pages write it: kilometres of flat walking for the slope model, minutes for Tobler's.
String costText(S s, CostModel model, double cost) => model.isSlope
    ? s.f('route_cost_slope', [(cost / 1000).toStringAsFixed(1)])
    : s.f('route_cost_tobler', [cost.round()]);

/// Kilometres with one decimal.
String routeKm(double m) => (m / 1000).toStringAsFixed(1);

/// The colour of the best route on the map.
const routeBestColour = Color(0xff2e7d32);

int cellIndex(ElevationGrid g, GridCell c) => c.row * g.width + c.col;
GridCell cellAt(ElevationGrid g, int i) => GridCell(i ~/ g.width, i % g.width);

/// A route through cells as a line on the map, through the cells' centres.
Widget routeLayer(ElevationGrid g, List<int> cells, Color colour, {double width = 4, bool dotted = false}) =>
    PolylineLayer(
      polylines: [
        Polyline(
          points: [for (final i in cells) cellAt(g, i).centre(g)],
          color: colour,
          strokeWidth: width,
          pattern: dotted ? StrokePattern.dotted() : const StrokePattern.solid(),
        ),
      ],
    );

/// A and B on the map, and the student's corners as small dots.
Widget endsLayer(ElevationGrid g, GridCell? a, GridCell? b, ColorScheme scheme) => MarkerLayer(
  markers: [
    for (final (label, c) in [('A', a), ('B', b)])
      if (c != null)
        Marker(
          point: c.centre(g),
          width: 32,
          height: 32,
          child: Container(
            key: Key('route_$label'),
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.bold),
            ),
          ),
        ),
  ],
);

Widget cornersLayer(ElevationGrid g, List<GridCell> corners, Color colour) => CircleLayer(
  circles: [
    for (final c in corners)
      CircleMarker(point: c.centre(g), radius: 5, color: colour, borderColor: Colors.white, borderStrokeWidth: 1.5),
  ],
);

/// A route's numbers as the pages show them: cost, length, climb, steepest slope.
String routeSummary(S s, CostSurface surface, List<int> cells, double cost) {
  final st = routeStats(surface, cells);
  return s.f('route_summary', [
    costText(s, surface.model, cost),
    routeKm(st.length),
    st.climb.round(),
    st.steepest.round(),
  ]);
}

/// Cost surfaces kept for the page's life, one per grid and model.
class CostCache {
  ElevationGrid? _grid;
  CostModel? _model;
  CostSurface? _surface;

  CostSurface of(ElevationGrid g, CostModel model) {
    if (!identical(g, _grid) || model != _model) {
      _grid = g;
      _model = model;
      _surface = CostSurface(g, model);
    }
    return _surface!;
  }
}

/// The teacher's setup: pick an area and a cost model, touch A and B; the best route is found and shown.
class LeastCostSetupPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;
  const LeastCostSetupPage({super.key, required this.s, this.loader});

  @override
  State<LeastCostSetupPage> createState() => _LeastCostSetupPageState();
}

class _LeastCostSetupPageState extends State<LeastCostSetupPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  final _costs = CostCache();
  AreaSummary? _area;
  ElevationGrid? _grid;
  CostModel _model = const CostModel.slope(15);
  GridCell? _a, _b;

  /// The best route for the current A, B and model, worked out when they change.
  ({List<int> cells, double cost})? _best;
  String? _error;

  S get s => widget.s;

  void _route() {
    final g = _grid, a = _a, b = _b;
    _best = null;
    if (g == null || a == null || b == null) return;
    if ((a.row - b.row).abs() < routeMinApart && (a.col - b.col).abs() < routeMinApart) {
      _error = 'route_too_close';
      return;
    }
    _best = leastCostRoute(_costs.of(g, _model), cellIndex(g, a), cellIndex(g, b));
    if (_best == null) _error = 'route_none';
  }

  void _tap(ElevationGrid g, LatLng p) {
    final cell = GridCell.at(g, p);
    if (cell == null) return;
    setState(() {
      _error = null;
      if (!_costs.of(g, _model).passable(cellIndex(g, cell))) {
        _error = 'route_need_ground';
        return;
      }
      // A first, then B; a touch after both starts again at A.
      if (_a == null || _b != null) {
        _a = cell;
        _b = null;
      } else {
        _b = cell;
      }
      _route();
    });
  }

  void _create() {
    final g = _grid, best = _best;
    if (g == null || best == null) return;
    final settings = LeastCostGameSettings(
      _area!.id,
      _area!.version,
      _model,
      _a!,
      _b!,
      steps: stepsOf(best.cells, g.width),
    );
    Navigator.of(context).pop({'leastCost': settings.toJson()});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s['game_least-cost']),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(onPressed: _best == null ? null : _create, child: Text(s['create'])),
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
                        _a = _b = null;
                        _best = null;
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
    final best = _best;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      onTap: (p, _) => _tap(grid, p),
      layers: [if (best != null) routeLayer(grid, best.cells, routeBestColour), endsLayer(grid, _a, _b, scheme)],
    );
    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              s[_error!],
              key: const Key('route_error'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        Text(s['route_setup_hint'], style: text.bodyMedium),
        const SizedBox(height: 12),
        Text(s['route_model'], style: text.titleSmall),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final m in [for (final t in costThetas) CostModel.slope(t), const CostModel.tobler()])
              ChoiceChip(
                label: Text(m.isSlope ? s.f('route_model_slope', [m.theta.round()]) : s['route_model_tobler']),
                selected: _model == m,
                onSelected: (_) => setState(() {
                  _model = m;
                  _error = null;
                  _route();
                }),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(s[_model.isSlope ? 'route_explain_slope' : 'route_explain_tobler'], style: text.bodySmall),
        const SizedBox(height: 12),
        if (best != null)
          Text(
            routeSummary(s, _costs.of(grid, _model), best.cells, best.cost),
            key: const Key('route_best'),
            style: text.titleSmall,
          )
        else
          Text(s[_a == null ? 'route_need_a' : 'route_need_b'], style: text.bodyMedium),
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
