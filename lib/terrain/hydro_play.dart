import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../games/game.dart';
import '../l10n.dart';
import '../queue.dart';
import '../student_message.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'viewshed_game.dart' show GridCell;
import 'watershed.dart';
import 'watershed_game.dart';

/// The five steps of level 2, in order.
const hydroSteps = ['dem', 'path', 'acc', 'pour', 'compare'];

/// How far (in cells) a pour point moves to the nearest stream cell when snapping is on: 300 m, enough for a
/// finger on the whole area's map, short enough that a point clearly off the river stays off it.
const hydroSnapCells = 10;

/// Colour of the teacher's basin after the answer, and of a drop's way down.
const outletBasinColour = 0xffef6c00, pathColour = 0xff6a1b9a;

/// A drop's way down as the page reports it: cells, length on the ground, and the height lost.
class FlowPathInfo {
  final List<int> cells;
  final double length, drop;
  const FlowPathInfo(this.cells, this.length, this.drop);

  factory FlowPathInfo.of(ElevationGrid g, FlowGrid f, GridCell start) {
    final cells = flowPath(f, start.row, start.col);
    final pts = [for (final i in cells) cellCentre(g, i)];
    const geodesic = Vincenty();
    var length = 0.0;
    for (var k = 0; k + 1 < pts.length; k++) {
      length += geodesic.distance(pts[k], pts[k + 1]);
    }
    final top = g.heightAt(pts.first), bottom = g.heightAt(pts.last);
    return FlowPathInfo(cells, length, top == null || bottom == null ? 0 : top - bottom);
  }
}

LatLng cellCentre(ElevationGrid g, int i) => latLngOf(g, (row: i ~/ g.width + 0.5, col: i % g.width + 0.5));

/// The student's side of watershed level 2: the basin derived from the DEM in five steps. The DEM; a drop's
/// way down by D8; the flow accumulation and the stream threshold; the pour point and its basin; the
/// delineated basin against the one drawn by hand in level 1 (or here). The answer is the pour point; the
/// teacher's basin shows once it is sent.
class HydroPlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const HydroPlay({super.key, required this.ctx, this.loader});

  @override
  State<HydroPlay> createState() => _HydroPlayState();
}

class _HydroPlayState extends State<HydroPlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  final _cache = WatershedCache();
  Timer? _retry;

  WatershedGameSettings? _settings;
  bool _loaded = false;
  String _participant = '';

  int _step = 0;
  GridCell? _pathStart;
  int? _threshold; // the area's stream threshold until the student moves the slider
  double? _sliding; // the slider while it moves, before the streams are drawn again
  GridCell? _pour;
  bool _snap = true, _missed = false;
  List<GridPoint> _poly = const [];
  bool _fromLevel1 = false;

  bool _sent = false, _busy = false;
  int? _score;
  List<List<int>>? _basin;
  String? _error;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      _settings = WatershedGameSettings.fromJson(widget.ctx.settings);
    } on FormatException {
      _settings = null;
    }
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  GridCell? _cell(Object? j) => j == null ? null : GridCell.fromJson(j as Map<String, dynamic>);

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      try {
        final d = jsonDecode(saved) as Map<String, dynamic>;
        if (d['resetAt'] == widget.ctx.resetAt) {
          _step = (d['step'] as int).clamp(0, hydroSteps.length - 1);
          _pathStart = _cell(d['path']);
          _threshold = d['threshold'] as int?;
          _pour = _cell(d['pour']);
          _snap = d['snap'] as bool;
          _poly = polyFromJson(d['poly'] as List);
          _fromLevel1 = d['level1'] as bool;
          _sent = d['sent'] as bool;
          _score = d['score'] as int?;
          final b = d['basin'] as List?;
          _basin = b == null ? null : runsFromJson(b);
        }
      } on Object {
        // A damaged save starts again.
      }
    }
    // The level-1 drawing of the same basin, if this device sent one.
    final settings = _settings;
    if (_poly.isEmpty && settings != null) {
      final drawn = prefs.getString(drawingKey(settings));
      if (drawn != null) {
        try {
          _poly = polyFromJson(jsonDecode(drawn) as List);
          _fromLevel1 = _poly.length >= shedVerticesMin;
        } on Object {
          _poly = const [];
        }
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'step': _step,
      'path': _pathStart?.toJson(),
      'threshold': _threshold,
      'pour': _pour?.toJson(),
      'snap': _snap,
      'poly': polyToJson(_poly),
      'level1': _fromLevel1,
      'sent': _sent,
      'score': _score,
      'basin': _basin,
      'resetAt': widget.ctx.resetAt,
    }),
  );

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    if (item['token'] != widget.ctx.token) return;
    _replies[item['submissionId'] as String] = reply;
    _take(reply);
  }

  void _take(Map<String, dynamic> reply) {
    if (reply['score'] is num) _score = (reply['score'] as num).toInt();
    if (reply['basin'] is List) _basin = runsFromJson(reply['basin'] as List);
  }

  Future<bool> _send() async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return false;
    if (refused == 'session_paused' || refused == 'session_closed') {
      widget.ctx.onStopped(refused!.replaceFirst('session_', ''));
      return false;
    }
    setState(() {
      if (refused != null) _error = refused;
    });
    await _save();
    if (pending > 0) _retry = Timer(const Duration(seconds: 15), _send);
    return true;
  }

  bool get _polyReady => _poly.length >= shedVerticesMin && isSimplePolygon(_poly);

  Future<void> _answerNow(ElevationGrid grid, int threshold) async {
    final pour = _pour;
    if (_busy || _sent || pour == null) return;
    final at = pour.centre(grid);
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = randomId();
    await _queue.add({
      'token': widget.ctx.token,
      'submissionId': id,
      'participantId': _participant,
      'round': 0,
      'answer': {'pour': pour.toJson(), 'threshold': threshold, if (_polyReady) 'poly': polyToJson(_poly)},
      'lat': at.latitude,
      'lon': at.longitude,
    });
    final accepted = await _send();
    if (!mounted) return;
    _busy = false;
    if (!accepted) return;
    setState(() {
      _sent = true;
      final reply = _replies.remove(id);
      if (reply != null) _take(reply);
    });
    await _save();
  }

  void _change(VoidCallback f) {
    setState(f);
    _save();
  }

  void _tap(ElevationGrid g, FlowGrid f, int threshold, LatLng p) {
    final cell = GridCell.at(g, p);
    if (cell == null) return;
    switch (hydroSteps[_step]) {
      case 'path':
        _change(() => _pathStart = cell);
      case 'pour':
        if (_sent) return;
        final snapped = _snap
            ? snapToStream(f, _cache.accOf(f), cell.row, cell.col, radius: hydroSnapCells, minCells: threshold)
            : null;
        _change(() {
          _missed = _snap && snapped == null;
          _pour = snapped == null ? cell : GridCell(snapped.row, snapped.col);
        });
      case 'compare':
        if (_sent || _fromLevel1 || _poly.length >= shedVerticesMax) return;
        final q = gridPointOf(g, p);
        _change(
          () => _poly = [
            ..._poly,
            roundPoint((row: q.row.clamp(0, g.height.toDouble()), col: q.col.clamp(0, g.width.toDouble()))),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return StudentMessage(Icons.error_outline, s['profile_bad_session']);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return AreaMap(
      loader: _loader,
      id: settings.areaId,
      version: settings.areaVersion,
      s: s,
      builder: (context, grid) => FlowMap(
        loader: _loader,
        id: settings.areaId,
        version: settings.areaVersion,
        s: s,
        builder: (context, flow) => _game(grid, flow, settings),
      ),
    );
  }

  Widget _game(ElevationGrid grid, FlowGrid flow, WatershedGameSettings settings) {
    final scheme = Theme.of(context).colorScheme;
    final acc = _cache.accOf(flow);
    final threshold = _threshold ?? flow.streamCells;
    final step = hydroSteps[_step];
    final pour = _pour;
    final pourMask = pour == null ? null : _cache.basinOf(flow, pour);
    final path = step == 'path' && _pathStart != null ? FlowPathInfo.of(grid, flow, _pathStart!) : null;
    final basin = _sent ? _basin : null;
    Widget streams() => gridOverlay(
      grid.outline,
      GridImage(grid, 'streams/$threshold', () => streamPixels(acc, threshold)),
      opacity: 0.85,
    );
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: step == 'dem' || step == 'path',
      doubleTapZoom: step != 'compare',
      onTap: (p, _) => _tap(grid, flow, threshold, p),
      layers: [
        if (step == 'acc')
          gridOverlay(grid.outline, GridImage(grid, 'accumulation', () => accumulationPixels(acc)), opacity: 0.9),
        if (basin != null && (step == 'pour' || step == 'compare'))
          gridOverlay(
            grid.outline,
            GridImage(
              grid,
              'basin/outlet',
              () => maskPixels(runsMask(basin, grid.width, grid.height), colour: outletBasinColour),
            ),
            opacity: 0.35,
          ),
        if (pourMask != null && (step == 'pour' || step == 'compare'))
          basinLayer(grid, 'pour/${pour!.row}/${pour.col}', pourMask),
        if (step == 'acc' || step == 'pour' || step == 'path') streams(),
        if (path != null)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [for (final i in path.cells) cellCentre(grid, i)],
                color: const Color(pathColour),
                strokeWidth: 3.5,
              ),
            ],
          ),
        if (step == 'compare')
          ...drawnLayers(grid, _poly, scheme.tertiary, closed: _sent || _fromLevel1 || _poly.length >= 3),
        outletLayer(grid, settings.outlet, scheme),
        if (pour != null && (step == 'pour' || step == 'compare'))
          MarkerLayer(
            markers: [
              Marker(
                point: pour.centre(grid),
                width: 22,
                height: 22,
                child: Container(
                  key: const Key('hydro_pour'),
                  decoration: BoxDecoration(
                    color: const Color(basinColour),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
    final panel = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final (i, k) in hydroSteps.indexed)
              ChoiceChip(
                key: Key('hydro_step_$k'),
                label: Text('${i + 1}. ${s['hydro_step_$k']}'),
                selected: _step == i,
                onSelected: (_) => _change(() => _step = i),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(s['hydro_title_$step'], style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(s['hydro_hint_$step'], style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        ..._stepBody(grid, flow, acc, threshold, step, path, pourMask, settings),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s[_error!], style: TextStyle(color: scheme.error)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (_step > 0)
              OutlinedButton(
                key: const Key('hydro_back'),
                onPressed: () => _change(() => _step--),
                child: Text(s['hydro_back']),
              ),
            const Spacer(),
            if (_step < hydroSteps.length - 1)
              FilledButton.tonal(
                key: const Key('hydro_next'),
                onPressed: () => _change(() => _step++),
                child: Text(s['hydro_next']),
              ),
          ],
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 900
          ? Row(
              children: [
                Expanded(child: map),
                SizedBox(width: 400, child: Material(elevation: 2, child: panel)),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 5, child: map),
                Expanded(flex: 4, child: Material(elevation: 2, child: panel)),
              ],
            ),
    );
  }

  List<Widget> _stepBody(
    ElevationGrid grid,
    FlowGrid flow,
    Int32List acc,
    int threshold,
    String step,
    FlowPathInfo? path,
    Uint8List? pourMask,
    WatershedGameSettings settings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final at = settings.outlet.centre(grid);
    switch (step) {
      case 'dem':
        final m = grid.meta;
        return [
          Text(
            s.f('hydro_dem_info', [grid.cell.round(), m.min.round(), m.max.round(), grid.width, grid.height]),
            key: const Key('hydro_dem_info'),
          ),
        ];
      case 'path':
        if (path == null) return [Text(s['hydro_path_none'])];
        return [
          Text(
            s.f('hydro_path_info', [path.cells.length, km(path.length), path.drop.round()]),
            key: const Key('hydro_path_info'),
          ),
        ];
      case 'acc':
        final shown = _sliding == null ? threshold : thresholdAt(_sliding!);
        return [
          Text(s.f('hydro_threshold', [shown, km2(cellsArea(grid, shown, at))]), key: const Key('hydro_threshold')),
          Slider(
            key: const Key('hydro_slider'),
            value: _sliding ?? thresholdPosition(threshold),
            onChanged: (v) => setState(() => _sliding = v),
            onChangeEnd: (v) => _change(() {
              _threshold = thresholdAt(v);
              _sliding = null;
              _missed = false;
            }),
          ),
          Text(s['hydro_acc_legend'], style: text.bodySmall),
        ];
      case 'pour':
        final pour = _pour;
        final cells = pourMask == null ? 0 : runCells(maskRuns(pourMask, flow.width));
        return [
          SwitchListTile(
            key: const Key('hydro_snap'),
            contentPadding: EdgeInsets.zero,
            title: Text(s['hydro_snap']),
            value: _snap,
            onChanged: _sent ? null : (v) => _change(() => _snap = v),
          ),
          if (_missed) Text(s['hydro_snap_missed'], style: TextStyle(color: scheme.error)),
          if (pour == null)
            Text(s['hydro_pour_none'])
          else ...[
            Text(
              s.f('hydro_pour_info', [
                km2(cellsArea(grid, cells, pour.centre(grid))),
                acc[pour.row * flow.width + pour.col],
              ]),
              key: const Key('hydro_pour_info'),
            ),
            if (pourMask != null && touchesEdge(pourMask, flow.width, flow.height))
              Text(s['hydro_pour_edge'], style: TextStyle(color: scheme.error)),
          ],
        ];
      default:
        return _compare(grid, flow, threshold, pourMask, settings);
    }
  }

  List<Widget> _compare(
    ElevationGrid grid,
    FlowGrid flow,
    int threshold,
    Uint8List? pourMask,
    WatershedGameSettings settings,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pour = _pour;
    final out = <Widget>[];
    if (pour == null || pourMask == null) {
      out.add(Text(s['hydro_pour_none']));
    } else if (_polyReady) {
      final c = BasinComparison.of(grid, _poly, maskRuns(pourMask, flow.width), pour);
      String signed(double v) => '${v >= 0 ? '+' : '-'}${v.abs().round()}';
      final drawnRuns = polygonRuns(_poly, maxRow: grid.height);
      out.addAll([
        Text(s[_fromLevel1 ? 'hydro_from_level1' : 'hydro_drawn_here'], style: text.bodySmall),
        Text(s.f('shed_result_drawn', [km2(c.drawnArea), km(c.drawnPerimeter)]), key: const Key('hydro_cmp_drawn')),
        Text(s.f('hydro_cmp_basin', [km2(c.basinArea), km(c.basinPerimeter)]), key: const Key('hydro_cmp_basin')),
        Text(
          s.f('hydro_cmp_overlap', [basinScore(drawnRuns, maskRuns(pourMask, flow.width)), signed(c.areaError)]),
          key: const Key('hydro_cmp_overlap'),
        ),
        Text(s['hydro_cmp_hint'], style: text.bodySmall),
      ]);
    } else {
      out.add(Text(s.f('hydro_draw_hint', [_poly.length]), key: const Key('hydro_draw_hint')));
      if (_poly.length >= 3) out.add(Text(s['shed_crossing'], style: TextStyle(color: scheme.error)));
    }
    if (!_sent && !_fromLevel1) {
      out.add(
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              key: const Key('hydro_undo'),
              onPressed: _poly.isEmpty ? null : () => _change(() => _poly = _poly.sublist(0, _poly.length - 1)),
              icon: const Icon(Icons.undo),
              label: Text(s['shed_undo']),
            ),
            TextButton.icon(
              key: const Key('hydro_clear'),
              onPressed: _poly.isEmpty ? null : () => _change(() => _poly = const []),
              icon: const Icon(Icons.delete_outline),
              label: Text(s['shed_clear']),
            ),
          ],
        ),
      );
    }
    out.add(const SizedBox(height: 8));
    if (!_sent) {
      out.add(
        FilledButton.icon(
          key: const Key('hydro_answer'),
          onPressed: _busy || pour == null ? null : () => _answerNow(grid, threshold),
          icon: const Icon(Icons.check),
          label: Text(s['hydro_hand_in']),
        ),
      );
    } else if (_score == null) {
      out.add(Text(s['play_checked_later']));
    } else {
      final basin = _basin;
      out.addAll([
        Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        if (basin != null)
          Text(
            s.f('hydro_outlet_basin', [km2(cellsArea(grid, runCells(basin), settings.outlet.centre(grid)))]),
            key: const Key('hydro_outlet_basin'),
          ),
        Text(s['hydro_result_hint'], style: text.bodySmall),
      ]);
    }
    return out;
  }
}
