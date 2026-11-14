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
import 'least_cost.dart';
import 'least_cost_game.dart';
import 'map_workspace.dart';
import 'viewshed_game.dart' show GridCell;

/// The student's side of the least-cost game: A and B on the relief map; the student puts the corners of a
/// route between them. One answer; the best route shows only after it is sent.
class LeastCostPlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const LeastCostPlay({super.key, required this.ctx, this.loader});

  @override
  State<LeastCostPlay> createState() => _LeastCostPlayState();
}

class _LeastCostPlayState extends State<LeastCostPlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  final _costs = CostCache();
  Timer? _retry;

  LeastCostGameSettings? _settings;
  bool _loaded = false;
  String _participant = '';

  List<GridCell> _via = const [];
  bool _sent = false;
  int? _score;
  String? _steps;
  double? _best;
  String? _error;
  bool _busy = false;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      _settings = LeastCostGameSettings.fromJson(widget.ctx.settings);
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

  // Reopening the link shows the route and the answer already given; the teacher's reset starts again.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        if (data['resetAt'] == widget.ctx.resetAt) {
          _via = [for (final p in data['via'] as List) GridCell((p as List)[0] as int, p[1] as int)];
          _sent = data['sent'] as bool;
          _score = data['score'] as int?;
          _steps = data['steps'] as String?;
          _best = (data['best'] as num?)?.toDouble();
        }
      } on Object {
        // A damaged save starts the route again.
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  List<List<int>> get _viaJson => [
    for (final c in _via) [c.row, c.col],
  ];

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'via': _viaJson,
      'sent': _sent,
      'score': _score,
      'steps': _steps,
      'best': _best,
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
    if (reply['steps'] is String) _steps = reply['steps'] as String;
    if (reply['best'] is num) _best = (reply['best'] as num).toDouble();
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

  List<int> _cells(ElevationGrid g, LeastCostGameSettings st) => routeThrough([
    for (final c in [st.start, ..._via, st.end]) cellIndex(g, c),
  ], g.width);

  Future<void> _answerNow(ElevationGrid grid) async {
    final st = _settings!;
    if (_busy || _sent || routeCost(_costs.of(grid, st.model), _cells(grid, st)) == null) return;
    final at = st.start.centre(grid);
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
      'answer': {'via': _viaJson},
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

  void _edit(List<GridCell> via) {
    if (_sent) return;
    setState(() {
      _via = via;
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
      builder: (context, grid) => _game(grid, settings),
    );
  }

  Widget _game(ElevationGrid grid, LeastCostGameSettings st) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final surface = _costs.of(grid, st.model);
    final cells = _cells(grid, st);
    final cost = routeCost(surface, cells);
    final best = _sent && _steps != null ? cellsOf(cellIndex(grid, st.start), _steps!, grid.width) : null;
    final mine = scheme.tertiary;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      // Corners go down with quick touches one after another.
      doubleTapZoom: false,
      onTap: (p, _) {
        if (_sent || _via.length >= routeCornersMax) return;
        final c = GridCell.at(grid, p);
        if (c != null) _edit([..._via, c]);
      },
      layers: [
        // The best route would give the answer away: shown only once the answer is sent.
        if (best != null) routeLayer(grid, best, routeBestColour, width: 5),
        routeLayer(grid, cells, mine, width: 3),
        cornersLayer(grid, _via, mine),
        endsLayer(grid, st.start, st.end, scheme),
      ],
    );
    final panel = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s['route_question'], style: text.titleMedium),
          Text(s[st.model.isSlope ? 'route_explain_slope' : 'route_explain_tobler'], style: text.bodySmall),
          const SizedBox(height: 4),
          if (!_sent) ...[
            Text(s['route_play_hint'], style: text.bodySmall),
            const SizedBox(height: 4),
            if (cost == null)
              Text(
                s['route_blocked'],
                key: const Key('route_blocked'),
                style: TextStyle(color: scheme.error),
              )
            else
              Text(
                '${s.f('route_corners', [_via.length])} · ${routeSummary(s, surface, cells, cost)}',
                key: const Key('route_progress'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  key: const Key('route_undo'),
                  onPressed: _via.isEmpty ? null : () => _edit(_via.sublist(0, _via.length - 1)),
                  icon: const Icon(Icons.undo),
                  label: Text(s['shed_undo']),
                ),
                OutlinedButton.icon(
                  key: const Key('route_clear'),
                  onPressed: _via.isEmpty ? null : () => _edit(const []),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(s['shed_clear']),
                ),
                FilledButton.icon(
                  key: const Key('route_answer'),
                  onPressed: _busy || cost == null ? null : () => _answerNow(grid),
                  icon: const Icon(Icons.check),
                  label: Text(s['play_answer']),
                ),
              ],
            ),
          ] else if (_score == null || best == null || _best == null || cost == null)
            Text(s['play_checked_later'])
          else ...[
            Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(
              s.f('route_result_mine', [routeSummary(s, surface, cells, cost)]),
              key: const Key('route_result_mine'),
            ),
            Text(
              s.f('route_result_best', [routeSummary(s, surface, best, _best!)]),
              key: const Key('route_result_best'),
            ),
            Text(s['route_result_hint'], style: text.bodySmall),
          ],
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
}
