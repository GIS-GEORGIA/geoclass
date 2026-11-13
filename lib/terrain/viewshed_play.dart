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
import 'slope_game.dart';
import 'viewshed_game.dart';

/// The student's side of the viewshed game: the observer on the relief map, and either targets to judge seen
/// or not, or squares to mark where it sees. One answer; what is seen shows only after it is sent.
class ViewshedPlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const ViewshedPlay({super.key, required this.ctx, this.loader});

  @override
  State<ViewshedPlay> createState() => _ViewshedPlayState();
}

class _ViewshedPlayState extends State<ViewshedPlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  final _cache = ViewshedCache();
  Timer? _retry;

  ViewshedGameSettings? _settings;
  bool _loaded = false;
  String _participant = '';

  /// Per target or square: true seen, false not; for targets, null until judged.
  List<bool?> _said = const [];
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
      final settings = ViewshedGameSettings.fromJson(widget.ctx.settings);
      _settings = settings;
      _said = List.filled(settings.count, settings.byTargets ? null : false);
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

  static String _encode(List<bool?> said) => said.map((v) => v == null ? '-' : (v ? '1' : '0')).join();
  static List<bool?> _decode(String s) => [for (var i = 0; i < s.length; i++) s[i] == '-' ? null : s[i] == '1'];

  // Reopening the link shows the answer already given; the teacher's reset starts everyone again.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['resetAt'] == widget.ctx.resetAt && (data['said'] as String).length == _said.length) {
        _said = _decode(data['said'] as String);
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
      'said': _encode(_said),
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
    if (_busy || _sent || _said.contains(null)) return;
    final at = _settings!.observer.centre(grid);
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
      'answer': {'seen': _encode(_said)},
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

  /// A target goes unjudged → seen → not seen → seen; a square marked or not.
  void _toggle(int i) {
    if (_sent) return;
    final settings = _settings!;
    setState(() => _said = List.of(_said)..[i] = settings.byTargets ? !(_said[i] ?? false) : !_said[i]!);
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

  Widget _game(ElevationGrid grid, ViewshedGameSettings settings) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final answer = _sent ? _answer : null;
    // What is seen would give the answer away: worked out and shown only once the answer is sent.
    final seen = answer == null ? null : _cache.of(grid, settings.observer, settings.height);
    final mine = scheme.tertiary.withValues(alpha: 0.55);
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      doubleTapZoom: settings.byTargets,
      onTap: (p, _) {
        if (_sent || settings.byTargets) return;
        final k = settings.box!.squareAt(grid, p);
        if (k != null) _toggle(k);
      },
      layers: [
        if (seen != null) viewshedLayer(grid, settings.observer, settings.height, seen),
        if (!settings.byTargets)
          ...slopeBoxLayers(grid, settings.box!, scheme, fill: (k) => _said[k] == true ? mine : null, right: answer),
        if (settings.byTargets)
          targetsLayer(
            grid,
            settings.targets,
            scheme,
            colour: (i) => _said[i] == null ? null : (_said[i]! ? viewSeenFill : viewHiddenFill),
            ring: answer == null ? null : (i) => answer[i] == _said[i],
            onTap: _sent ? null : _toggle,
          ),
        observerLayer(grid, settings.observer, scheme),
      ],
    );
    final judged = _said.where((v) => v != null).length;
    final marked = _said.where((v) => v == true).length;
    final panel = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.f(settings.byTargets ? 'view_question_targets' : 'view_question_squares', [viewMetres(settings.height)]),
            style: text.titleMedium,
          ),
          const SizedBox(height: 4),
          if (settings.byTargets)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var i = 0; i < _said.length; i++)
                  ActionChip(
                    key: Key('view_chip_$i'),
                    // After the answer: whether this one was judged right (the marker still shows the guess).
                    avatar: Icon(
                      answer != null
                          ? (answer[i] == _said[i] ? Icons.check_circle : Icons.cancel)
                          : _said[i] == null
                          ? Icons.help_outline
                          : (_said[i]! ? Icons.visibility : Icons.visibility_off),
                      size: 18,
                    ),
                    label: Text('${i + 1}'),
                    onPressed: _sent ? null : () => _toggle(i),
                  ),
              ],
            ),
          if (!_sent) ...[
            Text(s[settings.byTargets ? 'view_play_hint_targets' : 'view_play_hint_squares'], style: text.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    settings.byTargets
                        ? s.f('view_judged', [judged, _said.length])
                        : s.f('slope_marked', [marked, _said.length]),
                    key: const Key('view_progress'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _busy || _said.contains(null) ? null : () => _answerNow(grid),
                  icon: const Icon(Icons.check),
                  label: Text(s['play_answer']),
                ),
              ],
            ),
          ] else if (_score == null)
            Text(s['play_checked_later'])
          else ...[
            Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(
              s[settings.byTargets ? 'view_result_hint_targets' : 'view_result_hint_squares'],
              style: text.bodySmall,
            ),
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
