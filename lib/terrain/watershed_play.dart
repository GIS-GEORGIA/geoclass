import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../games/game.dart';
import '../l10n.dart';
import '../queue.dart';
import '../student_message.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'watershed.dart';
import 'watershed_game.dart';

/// The student's side of the watershed game: the outlet on the relief map with the streams; the student draws
/// the basin draining to it, vertex by vertex. One answer; the basin shows only after it is sent.
class WatershedPlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const WatershedPlay({super.key, required this.ctx, this.loader});

  @override
  State<WatershedPlay> createState() => _WatershedPlayState();
}

class _WatershedPlayState extends State<WatershedPlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  final _cache = WatershedCache();
  Timer? _retry;

  WatershedGameSettings? _settings;
  bool _loaded = false;
  String _participant = '';

  List<GridPoint> _poly = const [];
  bool _sent = false;
  int? _score;
  List<List<int>>? _basin;
  String? _error;
  bool _busy = false;

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

  // Reopening the link shows the polygon and the answer already given; the teacher's reset starts again.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        if (data['resetAt'] == widget.ctx.resetAt) {
          _poly = polyFromJson(data['poly'] as List);
          _sent = data['sent'] as bool;
          _score = data['score'] as int?;
          final b = data['basin'] as List?;
          _basin = b == null ? null : runsFromJson(b);
        }
      } on Object {
        // A damaged save starts the drawing again.
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'poly': polyToJson(_poly),
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

  bool get _ready => _poly.length >= shedVerticesMin && isSimplePolygon(_poly);

  Future<void> _answerNow(ElevationGrid grid) async {
    if (_busy || _sent || !_ready) return;
    final at = _settings!.outlet.centre(grid);
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
      'answer': {'poly': polyToJson(_poly)},
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
    // Kept for level 2 of the same basin, which compares it with the delineated one.
    await (await SharedPreferences.getInstance()).setString(drawingKey(_settings!), jsonEncode(polyToJson(_poly)));
  }

  void _edit(List<GridPoint> poly) {
    if (_sent) return;
    setState(() {
      _poly = poly;
      _error = null;
    });
    _save();
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
    final text = Theme.of(context).textTheme;
    final basin = _sent ? _basin : null;
    final mine = scheme.tertiary;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      // Vertices go down with quick touches one after another.
      doubleTapZoom: false,
      onTap: (p, _) {
        if (_sent || _poly.length >= shedVerticesMax) return;
        final q = gridPointOf(grid, p);
        _edit([
          ..._poly,
          roundPoint((row: q.row.clamp(0, grid.height.toDouble()), col: q.col.clamp(0, grid.width.toDouble()))),
        ]);
      },
      layers: [
        // The basin would give the answer away: shown only once the answer is sent.
        if (basin != null) basinLayer(grid, 'answer', runsMask(basin, grid.width, grid.height)),
        streamsLayer(grid, flow, _cache.accOf(flow)),
        ...drawnLayers(grid, _poly, mine, closed: _sent || _poly.length >= 3),
        outletLayer(grid, settings.outlet, scheme),
      ],
    );
    final pts = [for (final p in _poly) latLngOf(grid, p)];
    final crossing = _poly.length >= 3 && !isSimplePolygon(_poly);
    final panel = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s['shed_question'], style: text.titleMedium),
          const SizedBox(height: 4),
          if (!_sent) ...[
            Text(s['shed_play_hint'], style: text.bodySmall),
            const SizedBox(height: 4),
            Text(
              _poly.length < 3
                  ? s.f('shed_vertices', [_poly.length])
                  : s.f('shed_drawn', [_poly.length, km2(geodesicArea(pts)), km(geodesicPerimeter(pts))]),
              key: const Key('shed_progress'),
            ),
            if (crossing)
              Text(
                s['shed_crossing'],
                key: const Key('shed_crossing'),
                style: TextStyle(color: scheme.error),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('shed_undo'),
                  onPressed: _poly.isEmpty ? null : () => _edit(_poly.sublist(0, _poly.length - 1)),
                  icon: const Icon(Icons.undo),
                  label: Text(s['shed_undo']),
                ),
                OutlinedButton.icon(
                  key: const Key('shed_clear'),
                  onPressed: _poly.isEmpty ? null : () => _edit(const []),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(s['shed_clear']),
                ),
                FilledButton.icon(
                  key: const Key('shed_answer'),
                  onPressed: _busy || !_ready ? null : () => _answerNow(grid),
                  icon: const Icon(Icons.check),
                  label: Text(s['play_answer']),
                ),
              ],
            ),
          ] else if (_score == null || basin == null)
            Text(s['play_checked_later'])
          else
            ..._result(grid, settings, basin, text),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(s[_error!], style: TextStyle(color: scheme.error)),
            ),
        ],
      ),
    );
    return Column(
      children: [
        Expanded(child: map),
        Material(elevation: 2, child: panel),
      ],
    );
  }

  List<Widget> _result(ElevationGrid grid, WatershedGameSettings settings, List<List<int>> basin, TextTheme text) {
    final c = BasinComparison.of(grid, _poly, basin, settings.outlet);
    String signed(double v) => '${v >= 0 ? '+' : '-'}${v.abs().round()}';
    return [
      Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      Text(s.f('shed_result_drawn', [km2(c.drawnArea), km(c.drawnPerimeter)]), key: const Key('shed_result_drawn')),
      Text(s.f('shed_result_basin', [km2(c.basinArea), km(c.basinPerimeter)]), key: const Key('shed_result_basin')),
      Text(s.f('shed_result_error', [signed(c.areaError), c.outside.round()]), key: const Key('shed_result_error')),
      Text(s['shed_result_hint'], style: text.bodySmall),
    ];
  }
}
