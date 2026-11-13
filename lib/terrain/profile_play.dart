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
import 'profile.dart';
import 'profile_chart.dart';
import 'profile_game.dart';

/// The student's side of the terrain profile game: the line on the map, its profile without the numbers,
/// and one question at a time. The server scores each answer and sends the right one back.
class ProfilePlay extends StatefulWidget {
  final PlayContext ctx;
  final DemLoader? loader;
  const ProfilePlay({super.key, required this.ctx, this.loader});

  @override
  State<ProfilePlay> createState() => _ProfilePlayState();
}

/// What the student learnt about one answered question.
class _Result {
  final int score;
  final double? answer;
  final double value;
  const _Result(this.score, this.answer, this.value);

  Map<String, dynamic> toJson() => {'score': score, 'answer': answer, 'value': value};
  factory _Result.fromJson(Map<String, dynamic> j) =>
      _Result(j['score'] as int, (j['answer'] as num?)?.toDouble(), (j['value'] as num).toDouble());
}

class _ProfilePlayState extends State<ProfilePlay> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  final _input = TextEditingController();
  Timer? _retry;

  ProfileGameSettings? _settings;
  ElevationGrid? _grid;
  TerrainProfile? _profile;
  bool _loaded = false;
  String _participant = '';
  int _round = 0;
  final _results = <int, _Result?>{}; // null: sent, but its score isn't back yet
  bool _showResult = false;
  ProfileSample? _cursor, _picked;
  int? _section;
  String? _error;
  bool _busy = false;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';
  List<ProfileQuestion> get _questions => _settings?.questions ?? const [];
  ProfileQuestion? get _question => _round < _questions.length ? _questions[_round] : null;

  @override
  void initState() {
    super.initState();
    try {
      _settings = ProfileGameSettings.fromJson(widget.ctx.settings);
    } on FormatException {
      _settings = null;
    }
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _input.dispose();
    super.dispose();
  }

  // Reopening the link continues where the student stopped; the teacher's reset starts everyone again.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['resetAt'] == widget.ctx.resetAt) {
        _round = data['round'] as int;
        for (final e in (data['results'] as Map<String, dynamic>).entries) {
          _results[int.parse(e.key)] = e.value == null ? null : _Result.fromJson(e.value as Map<String, dynamic>);
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
      'round': _round,
      'results': {for (final e in _results.entries) '${e.key}': e.value?.toJson()},
      'resetAt': widget.ctx.resetAt,
    }),
  );

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    if (item['token'] != widget.ctx.token) return;
    _replies[item['submissionId'] as String] = reply;
    // An answer that went out late, after a lost connection: its score arrives now.
    final round = item['round'] as int;
    if (_results.containsKey(round) && _results[round] == null && reply['score'] is num) {
      final value = ((item['answer'] as Map)['value'] as num).toDouble();
      _results[round] = _Result((reply['score'] as num).toInt(), (reply['answer'] as num?)?.toDouble(), value);
    }
  }

  /// Returns false when the session stopped taking answers.
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

  /// The student's answer to the question on screen, or null with [_error] set.
  double? _value(ProfileQuestion q) {
    switch (q.kind) {
      case 'steepest':
        if (_section == null) _error = 'profile_need_section';
        return _section?.toDouble();
      case 'where_max':
        if (_picked == null) _error = 'profile_need_pick';
        return _picked?.distance;
      default:
        final n = double.tryParse(_input.text.trim().replaceAll(',', '.'));
        if (n == null || !n.isFinite) {
          _error = 'profile_need_number';
          return null;
        }
        return q.kind == 'length' ? n * 1000 : n;
    }
  }

  Future<void> _answer() async {
    final q = _question;
    if (q == null || _busy) return;
    final value = _value(q);
    if (value == null) {
      setState(() {});
      return;
    }
    final line = _settings!.line;
    final at = q.kind == 'where_max' && _profile != null ? _profile!.positionOf(_picked!) : line.first;
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = randomId();
    await _queue.add({
      'token': widget.ctx.token,
      'submissionId': id,
      'participantId': _participant,
      'round': _round,
      'answer': {'kind': q.kind, 'value': value},
      'lat': at.latitude,
      'lon': at.longitude,
    });
    _results[_round] = null;
    final accepted = await _send();
    if (!mounted) return;
    _busy = false;
    if (!accepted) {
      _results.remove(_round);
      return;
    }
    final reply = _replies.remove(id);
    setState(() {
      if (reply != null && reply['score'] is num) {
        _results[_round] = _Result((reply['score'] as num).toInt(), (reply['answer'] as num?)?.toDouble(), value);
      }
      _showResult = true;
    });
    await _save();
  }

  void _next() {
    setState(() {
      _showResult = false;
      _round++;
      _input.clear();
      _section = null;
      _picked = null;
      _cursor = null;
      _error = null;
    });
    _save();
  }

  int get _total => _results.values.fold(0, (sum, r) => sum + (r?.score ?? 0));

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return StudentMessage(Icons.error_outline, s['profile_bad_session']);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_question == null && !_showResult) return _finished();
    return AreaMap(
      loader: _loader,
      id: settings.areaId,
      version: settings.areaVersion,
      s: s,
      builder: (context, grid) {
        if (!identical(_grid, grid)) {
          _grid = grid;
          _profile = TerrainProfile.along(grid, settings.line);
        }
        return _game(grid, _profile!);
      },
    );
  }

  Widget _finished() {
    final waiting = _results.values.where((r) => r == null).length;
    return StudentMessage(
      Icons.emoji_events,
      s['done_title'],
      body: [
        s.f('done_total', [_total, _questions.length * 100]),
        if (waiting > 0) s['done_pending'],
      ].join('\n\n'),
    );
  }

  void _tapMap(LatLng p, double? _) {
    final profile = _profile;
    if (profile == null || _showResult) return;
    final near = profile.closestTo(p, within: 300);
    if (near == null) return;
    setState(() {
      _cursor = near;
      if (_question?.kind == 'where_max') _picked = near;
    });
  }

  void _chartCursor(ProfileSample? c) {
    if (_showResult) return;
    setState(() {
      _cursor = c ?? _picked;
      if (c != null && _question?.kind == 'where_max') _picked = c;
    });
  }

  Widget _game(ElevationGrid grid, TerrainProfile profile) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _showResult ? _results[_round] : null;
    // After a "where is the top" answer the true place shows too.
    final rightPlace = shown != null && _question?.kind == 'where_max' && shown.answer != null
        ? profile.nearest(shown.answer!)
        : null;
    final cursor = rightPlace ?? _picked ?? _cursor;
    final map = MapWorkspace(
      grid: grid,
      s: s,
      showHeight: false,
      onTap: _tapMap,
      layers: profileLineLayers(_settings!.line, scheme, cursor: cursor == null ? null : profile.positionOf(cursor)),
    );
    final chart = ProfileChart(
      profile: profile,
      s: s,
      marks: false,
      cursor: cursor,
      height: 150,
      onCursor: _chartCursor,
    );
    final side = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        chart,
        if (cursor != null && !_showResult)
          Text(
            s.f('profile_at', [profileDistance(cursor.distance, s)]),
            key: const Key('profile_at'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        _showResult ? _resultCard() : _questionCard(profile),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 900
          ? Row(
              children: [
                Expanded(child: map),
                SizedBox(width: 420, child: side),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 2, child: map),
                Expanded(flex: 3, child: side),
              ],
            ),
    );
  }

  Widget _questionCard(TerrainProfile profile) {
    final q = _question!;
    final text = Theme.of(context).textTheme;
    final input = switch (q.kind) {
      'steepest' => Wrap(
        spacing: 8,
        children: [
          for (var k = 0; k < profile.sections.length; k++)
            ChoiceChip(
              label: Text(s.f('profile_section', [k + 1])),
              selected: _section == k,
              onSelected: (_) => setState(() => _section = k),
            ),
        ],
      ),
      'where_max' => Text(
        _picked == null ? s['profile_pick_hint'] : s.f('profile_picked', [profileDistance(_picked!.distance, s)]),
        style: text.bodyMedium,
      ),
      _ => TextField(
        key: const Key('profile_input'),
        controller: _input,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: s['profile_your_answer'],
          suffixText: q.kind == 'length' ? s.f('profile_km', ['']).trim() : s.f('profile_m', ['']).trim(),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _answer(),
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.f('play_task', [_round + 1, _questions.length]), style: text.labelMedium),
            const SizedBox(height: 4),
            Text(q.title(s), style: text.titleMedium),
            if (q.tolerance != null) Text(s.f('profile_within', [q.tolerance!.round()]), style: text.bodySmall),
            const SizedBox(height: 12),
            input,
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s[_error!], style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _answer,
              icon: const Icon(Icons.check),
              label: Text(s['play_answer']),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard() {
    final q = _question!;
    final r = _results[_round];
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(q.title(s), style: text.titleMedium),
            const SizedBox(height: 8),
            if (r == null)
              Text(s['play_checked_later'])
            else ...[
              Text(s.f('result_score', [r.score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              Text(s.f('profile_yours', [profileValue(q.kind, r.value, s)])),
              if (r.answer != null) Text(s.f('profile_right', [profileValue(q.kind, r.answer!, s)])),
            ],
            const SizedBox(height: 12),
            FilledButton(onPressed: _next, child: Text(s['next'])),
          ],
        ),
      ),
    );
  }
}
