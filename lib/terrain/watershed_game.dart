import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'viewshed_game.dart' show GridCell;
import 'watershed.dart';

/// As worker/src/games/watershed.ts: the smallest basin, the most runs one may have, and the polygon's vertices.
const shedMinCells = 100, shedMaxRuns = 20000;
const shedVerticesMin = 3, shedVerticesMax = 100;

/// The session's settings. [runs] (the basin) only on the teacher's side and in the reply to an answer.
class WatershedGameSettings {
  final String areaId;
  final int areaVersion;
  final GridCell outlet;
  final List<List<int>>? runs;

  const WatershedGameSettings(this.areaId, this.areaVersion, this.outlet, {this.runs});

  factory WatershedGameSettings.fromJson(Map<String, dynamic> j) {
    try {
      final area = j['area'] as Map<String, dynamic>;
      final runs = j['runs'] as List?;
      return WatershedGameSettings(
        area['id'] as String,
        area['version'] as int,
        GridCell.fromJson(j['outlet'] as Map<String, dynamic>),
        runs: runs == null ? null : runsFromJson(runs),
      );
    } on TypeError {
      throw const FormatException('bad watershed settings');
    }
  }

  /// What the teacher's app sends: the server works the basin out itself from the area's flow directions.
  Map<String, dynamic> toJson() => {
    'area': {'id': areaId, 'version': areaVersion},
    'outlet': outlet.toJson(),
  };
}

List<List<int>> runsFromJson(List raw) => [
  for (final r in raw) [for (final v in r as List) (v as num).toInt()],
];

/// Vertices as the server keeps them: two decimals of a cell. The app rounds the same way before sending,
/// so what it shows is what is scored.
GridPoint roundPoint(GridPoint p) => (row: (p.row * 100).round() / 100, col: (p.col * 100).round() / 100);

List<List<double>> polyToJson(List<GridPoint> poly) => [
  for (final p in poly) [p.row, p.col],
];

List<GridPoint> polyFromJson(List raw) => [
  for (final p in raw) (row: ((p as List)[0] as num).toDouble(), col: (p[1] as num).toDouble()),
];

/// Accumulation and basins, worked out once per flow grid and outlet and kept for the page's life.
class WatershedCache {
  FlowGrid? _flow;
  Int32List? _acc;
  String? _key;
  Uint8List? _mask;

  Int32List accOf(FlowGrid f) {
    if (!identical(f, _flow)) {
      _flow = f;
      _acc = accumulation(f);
      _key = null;
    }
    return _acc!;
  }

  Uint8List basinOf(FlowGrid f, GridCell outlet) {
    accOf(f);
    final key = '${outlet.row}/${outlet.col}';
    if (key != _key) {
      _key = key;
      _mask = basinMask(f, outlet.row, outlet.col);
    }
    return _mask!;
  }
}

/// Why a basin can't be played, as a translation key, or null when it can. As the server checks it.
String? basinProblem(Uint8List mask, FlowGrid f) {
  final runs = maskRuns(mask, f.width);
  if (runCells(runs) < shedMinCells) return 'shed_basin_small';
  if (runs.length > shedMaxRuns) return 'shed_basin_large';
  if (touchesEdge(mask, f.width, f.height)) return 'shed_basin_edge';
  return null;
}

/// The streams as a map layer: cells with at least the area's stream threshold of upstream cells.
Widget streamsLayer(ElevationGrid g, FlowGrid f, Int32List acc) => gridOverlay(
  g.outline,
  GridImage(g, 'streams/${f.streamCells}', () => streamPixels(acc, f.streamCells)),
  opacity: 0.85,
);

/// A basin as a map layer. [key] names it for the image cache.
Widget basinLayer(ElevationGrid g, String key, Uint8List mask) =>
    gridOverlay(g.outline, GridImage(g, 'basin/$key', () => maskPixels(mask)), opacity: 0.4);

/// The outlet on the map: a drop in a circle.
Widget outletLayer(ElevationGrid g, GridCell outlet, ColorScheme scheme) => MarkerLayer(
  markers: [
    Marker(
      point: outlet.centre(g),
      width: 32,
      height: 32,
      child: Container(
        key: const Key('shed_outlet'),
        decoration: BoxDecoration(
          color: const Color(streamColour),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(Icons.water_drop, size: 17, color: Colors.white),
      ),
    ),
  ],
);

/// A drawn polygon on the map, with its vertices as dots; closed when [closed].
List<Widget> drawnLayers(ElevationGrid g, List<GridPoint> poly, Color colour, {bool closed = true}) {
  final pts = [for (final p in poly) latLngOf(g, p)];
  return [
    if (closed && pts.length >= 3)
      PolygonLayer(
        polygons: [
          Polygon(points: pts, color: colour.withValues(alpha: 0.18), borderColor: colour, borderStrokeWidth: 2.5),
        ],
      )
    else if (pts.length >= 2)
      PolylineLayer(
        polylines: [Polyline(points: pts, color: colour, strokeWidth: 2.5)],
      ),
    CircleLayer(
      circles: [
        for (final p in pts)
          CircleMarker(point: p, radius: 4, color: colour, borderColor: Colors.white, borderStrokeWidth: 1.5),
      ],
    ),
  ];
}

/// Areas as the pages write them: km² with two decimals under 10, one above.
String km2(double m2) => (m2 / 1e6).toStringAsFixed(m2 < 1e7 ? 2 : 1);

/// Lengths as the pages write them: km with one decimal.
String km(double m) => (m / 1000).toStringAsFixed(1);

/// The length of a basin's outline along its cell edges, in metres on the ground. Longer than a drawn line
/// round the same ground, because it steps along the grid.
double basinOutline(ElevationGrid g, List<List<int>> runs, LatLng at) {
  final mask = runsMask(runs, g.width, g.height);
  var edges = 0;
  bool on(int r, int c) => r >= 0 && c >= 0 && r < g.height && c < g.width && mask[r * g.width + c] != 0;
  for (final run in runs) {
    final r = run[0];
    for (var c = run[1]; c < run[2]; c++) {
      if (!on(r - 1, c)) edges++;
      if (!on(r + 1, c)) edges++;
      if (!on(r, c - 1)) edges++;
      if (!on(r, c + 1)) edges++;
    }
  }
  return edges * g.cell / utmScale(at.latitude, at.longitude, g.meta.zone);
}

/// How a drawn polygon compares with the basin: both areas and outlines, the area's error, and the share of
/// the drawn cells outside the basin.
class BasinComparison {
  final double drawnArea, drawnPerimeter, basinArea, basinPerimeter;

  /// (drawn − basin) / basin, in per cent.
  final double areaError;

  /// Drawn cells outside the basin, per cent of the drawn cells.
  final double outside;

  const BasinComparison(
    this.drawnArea,
    this.drawnPerimeter,
    this.basinArea,
    this.basinPerimeter,
    this.areaError,
    this.outside,
  );

  factory BasinComparison.of(ElevationGrid g, List<GridPoint> poly, List<List<int>> basin, GridCell outlet) {
    final at = outlet.centre(g);
    final pts = [for (final p in poly) latLngOf(g, p)];
    final drawnArea = geodesicArea(pts);
    final basinArea = cellsArea(g, runCells(basin), at);
    final drawn = polygonRuns(poly, maxRow: g.height);
    final cells = runCells(drawn);
    return BasinComparison(
      drawnArea,
      geodesicPerimeter(pts),
      basinArea,
      basinOutline(g, basin, at),
      100 * (drawnArea - basinArea) / basinArea,
      cells == 0 ? 0 : 100 * (cells - runsOverlap(drawn, basin)) / cells,
    );
  }
}

/// The teacher's setup: pick an area, touch a stream to put the outlet there, and see its basin.
/// Returns the settings for the new session; the server works the basin out again from the same directions.
class WatershedSetupPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;
  const WatershedSetupPage({super.key, required this.s, this.loader});

  @override
  State<WatershedSetupPage> createState() => _WatershedSetupPageState();
}

class _WatershedSetupPageState extends State<WatershedSetupPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  final _cache = WatershedCache();
  AreaSummary? _area;
  GridCell? _outlet;
  bool _showStreams = true, _showBasin = true;

  /// Why the outlet's basin can't be played, and whether the last touch found no stream.
  String? _problem;
  bool _missed = false;

  S get s => widget.s;

  void _tap(ElevationGrid g, FlowGrid f, LatLng p) {
    final cell = GridCell.at(g, p);
    if (cell == null) return;
    final snapped = snapToStream(f, _cache.accOf(f), cell.row, cell.col);
    setState(() {
      // A touch that finds no stream leaves the outlet where it was.
      _missed = snapped == null;
      if (snapped == null) return;
      final outlet = GridCell(snapped.row, snapped.col);
      _outlet = outlet;
      _problem = basinProblem(_cache.basinOf(f, outlet), f);
    });
  }

  void _create() {
    final area = _area, outlet = _outlet;
    if (area == null || outlet == null || _problem != null) return;
    Navigator.of(context).pop({'watershed': WatershedGameSettings(area.id, area.version, outlet).toJson()});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s['game_watershed']),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: _outlet == null || _problem != null ? null : _create,
            child: Text(s['create']),
          ),
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
                        _outlet = null;
                        _problem = null;
                        _missed = false;
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
                      builder: (context, grid) => FlowMap(
                        loader: _loader,
                        id: area.id,
                        version: area.version,
                        s: s,
                        builder: (context, flow) => _workspace(grid, flow),
                      ),
                    ),
            ),
          ],
        );
      },
    ),
  );

  Widget _workspace(ElevationGrid grid, FlowGrid flow) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final acc = _cache.accOf(flow);
    final outlet = _outlet;
    final mask = outlet == null ? null : _cache.basinOf(flow, outlet);
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      onTap: (p, _) => _tap(grid, flow, p),
      layers: [
        if (mask != null && _showBasin) basinLayer(grid, '${outlet!.row}/${outlet.col}', mask),
        if (_showStreams) streamsLayer(grid, flow, acc),
        if (outlet != null) outletLayer(grid, outlet, scheme),
      ],
    );
    final cells = mask == null ? 0 : runCells(maskRuns(mask, flow.width));
    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final e in [if (_missed) 'shed_need_stream', ?_problem])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              s[e],
              key: Key('shed_error_$e'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        Text(s['shed_setup_hint'], style: text.bodyMedium),
        const SizedBox(height: 8),
        if (outlet != null)
          Text(
            s.f('shed_basin_area', [km2(cellsArea(grid, cells, outlet.centre(grid)))]),
            key: const Key('shed_basin_area'),
            style: text.titleSmall,
          ),
        SwitchListTile(
          key: const Key('shed_show_streams'),
          contentPadding: EdgeInsets.zero,
          title: Text(s['shed_show_streams']),
          value: _showStreams,
          onChanged: (v) => setState(() => _showStreams = v),
        ),
        SwitchListTile(
          key: const Key('shed_show_basin'),
          contentPadding: EdgeInsets.zero,
          title: Text(s['shed_show_basin']),
          value: _showBasin,
          onChanged: (v) => setState(() => _showBasin = v),
        ),
        Text(s['shed_scoring'], style: text.bodySmall),
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

/// Loads an area's flow directions, then shows [builder]; a spinner meanwhile, the reason and a retry if it fails.
class FlowMap extends StatefulWidget {
  final DemLoader loader;
  final String id;
  final int version;
  final S s;
  final Widget Function(BuildContext context, FlowGrid flow) builder;
  const FlowMap({
    super.key,
    required this.loader,
    required this.id,
    required this.version,
    required this.s,
    required this.builder,
  });

  @override
  State<FlowMap> createState() => _FlowMapState();
}

class _FlowMapState extends State<FlowMap> {
  late Future<FlowGrid> _flow = widget.loader.loadFlow(widget.id, widget.version);

  @override
  Widget build(BuildContext context) => FutureBuilder<FlowGrid>(
    future: _flow,
    builder: (context, snap) {
      final f = snap.data;
      if (f != null) return widget.builder(context, f);
      if (snap.hasError) {
        final e = snap.error;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.s[e is DemError ? e.key : 'dem_bad_data']),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => setState(() {
                  _flow = widget.loader.loadFlow(widget.id, widget.version);
                }),
                child: Text(widget.s['retry']),
              ),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    },
  );
}
