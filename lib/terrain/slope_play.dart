import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../games/game.dart';
import '../l10n.dart';
import '../queue.dart';
import '../student_message.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'slope_game.dart';

/// The student's side of the slope game: the box on the relief map, squares marked by touch, one answer.
/// The slope classes and the right squares show only after the answer is sent.
class SlopePlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const SlopePlay({super.key, required this.ctx, this.loader});

  @override
  State<SlopePlay> createState() => _SlopePlayState();
}

class _SlopePlayState extends State<SlopePlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  Timer? _retry;

  SlopeGameSettings? _settings;
  bool _loaded = false;
  String _participant = '';
  List<bool> _marks = const [];
  bool _sent = false;
  int? _score;
  List<bool>? _answer;
  String? _error;
  bool _busy = false;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      _settings = SlopeGameSettings.fromJson(widget.ctx.settings);
      _marks = List.filled(_settings!.box.n * _settings!.box.n, false);
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

  // Reopening the link shows the answer already given; the teacher's reset starts everyone again.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['resetAt'] == widget.ctx.resetAt && (data['marks'] as String).length == _marks.length) {
        _marks = marksFromString(data['marks'] as String);
        _sent = data['sent'] as bool;
        _score = data['score'] as int?;
        final a = data['answer'] as String?;
        _answer = a == null ? null : marksFromString(a);
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'marks': marksToString(_marks),
      'sent': _sent,
      'score': _score,
      'answer': _answer == null ? null : marksToString(_answer!),
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
    if (reply['answer'] is String) _answer = marksFromString(reply['answer'] as String);
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

  Future<void> _answerNow(ElevationGrid grid) async {
    if (_busy || _sent) return;
    final box = _settings!.box;
    final centre = box.outline(grid);
    final at = LatLng(
      centre.map((p) => p.latitude).reduce((a, b) => a + b) / 4,
      centre.map((p) => p.longitude).reduce((a, b) => a + b) / 4,
    );
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
      'answer': {'marks': marksToString(_marks)},
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

  Widget _game(ElevationGrid grid, SlopeGameSettings settings) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final answer = _answer;
    final mine = scheme.tertiary.withValues(alpha: 0.55);
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      // The slope classes would give the answer away: offered only once it is sent.
      slope: _sent && answer != null ? true : null,
      onTap: (p, _) {
        if (_sent) return;
        final k = settings.box.squareAt(grid, p);
        if (k == null) return;
        setState(() => _marks = List.of(_marks)..[k] = !_marks[k]);
        _save();
      },
      layers: slopeBoxLayers(
        grid,
        settings.box,
        scheme,
        fill: (k) => _marks[k] ? mine : null,
        right: _sent ? answer : null,
      ),
    );
    final marked = _marks.where((m) => m).length;
    final panel = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.f('slope_question', [settings.threshold]), style: text.titleMedium),
          const SizedBox(height: 4),
          if (!_sent) ...[
            Text(s['slope_play_hint'], style: text.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text(s.f('slope_marked', [marked, _marks.length]), key: const Key('slope_marked'))),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _answerNow(grid),
                  icon: const Icon(Icons.check),
                  label: Text(s['play_answer']),
                ),
              ],
            ),
          ] else if (_score == null)
            Text(s['play_checked_later'])
          else ...[
            Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(s['slope_result_hint'], style: text.bodySmall),
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
