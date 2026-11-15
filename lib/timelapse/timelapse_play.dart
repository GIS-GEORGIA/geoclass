import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../games/game.dart';
import '../l10n.dart';
import '../queue.dart';
import 'frame_map.dart';
import 'timelapse.dart';

/// What the server said about the answer: the score and the teacher's outlines, kept with the answer.
class TimelapseResult {
  final int score;
  final Outline truthA, truthB, mineA, mineB;
  const TimelapseResult(this.score, this.truthA, this.truthB, this.mineA, this.mineB);

  static TimelapseResult? fromReply(Map<String, dynamic> r, Outline mineA, Outline mineB) {
    final truth = r['truth'];
    if (r['score'] is! num || truth is! List || truth.length != 2) return null;
    try {
      return TimelapseResult(
        (r['score'] as num).toInt(),
        outlineFromJson(truth[0]),
        outlineFromJson(truth[1]),
        mineA,
        mineB,
      );
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'score': score,
    'truth': [outlineToJson(truthA), outlineToJson(truthB)],
    'a': outlineToJson(mineA),
    'b': outlineToJson(mineB),
  };
  static TimelapseResult? fromJson(Map<String, dynamic> j) =>
      fromReply(j, outlineFromJson(j['a']), outlineFromJson(j['b']));
}

/// The student's time-lapse: play the years, then outline the same thing on year A and on year B. The app
/// shows both areas and the change; the server scores how well each outline matches the teacher's.
class TimelapsePlay extends StatefulWidget {
  final PlayContext ctx;
  final FrameLoader? loader;
  const TimelapsePlay({super.key, required this.ctx, this.loader});
  @override
  State<TimelapsePlay> createState() => _TimelapsePlayState();
}

class _TimelapsePlayState extends State<TimelapsePlay> {
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  late final _loader = widget.loader ?? FrameLoader();
  final _map = MapController();
  final _replies = <String, Map<String, dynamic>>{};
  Timer? _retry;

  String _site = '', _participant = '';
  int _version = 0, _yearA = 0, _yearB = 0;
  SiteFrames? _frames;
  String? _error, _loadError;
  bool _bad = false, _busy = false;

  /// 0: watching the years, 1: drawing on year A, 2: on year B.
  int _mode = 0;
  int _year = 0;
  var _a = const OutlineDraft([], [], maxRings: maxAnswerRings, maxVertices: maxAnswerVertices);
  var _b = const OutlineDraft([], [], maxRings: maxAnswerRings, maxVertices: maxAnswerVertices);
  TimelapseResult? _result;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      final st = widget.ctx.settings;
      final years = st['years'] as List;
      _site = st['site'] as String;
      _version = (st['version'] as num).toInt();
      _yearA = (years[0] as num).toInt();
      _yearB = (years[1] as num).toInt();
      _year = _yearA;
    } on Object {
      _bad = true;
    }
    if (!_bad) _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _participant = await participantId(widget.ctx.token);
    final saved = (await SharedPreferences.getInstance()).getString(_progressKey);
    if (saved != null) {
      try {
        final d = jsonDecode(saved) as Map<String, dynamic>;
        if (d['resetAt'] == widget.ctx.resetAt) _result = TimelapseResult.fromJson(d['result'] as Map<String, dynamic>);
      } on Object {
        // A damaged save starts again; the server still has the answer.
      }
    }
    try {
      final frames = await _loader.site(_site, _version);
      if (mounted) setState(() => _frames = frames);
    } on Exception catch (e) {
      if (mounted) setState(() => _loadError = e is ApiError ? s[e.key] : s['no_connection']);
    }
    _send();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({'result': _result?.toJson(), 'resetAt': widget.ctx.resetAt}),
  );

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    if (item['token'] != widget.ctx.token) return;
    _replies[item['submissionId'] as String] = reply;
    final a = item['answer'] as Map<String, dynamic>;
    final r = TimelapseResult.fromReply(reply, outlineFromJson(a['a']), outlineFromJson(a['b']));
    if (r != null && mounted) {
      setState(() => _result = r);
      _save();
    }
  }

  Future<void> _send() async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return;
    if (refused == 'session_paused' || refused == 'session_closed') {
      widget.ctx.onStopped(refused!.replaceFirst('session_', ''));
      return;
    }
    if (refused != null) setState(() => _error = s[refused]);
    if (pending > 0) _retry = Timer(const Duration(seconds: 15), _send);
  }

  Future<void> _submit() async {
    final a = _a.outline, b = _b.outline;
    if (a.isEmpty || b.isEmpty) {
      setState(() => _error = s['timelapse_need_both']);
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = randomId();
    final centre = LatLngBounds.fromPoints(_frames!.corners).center;
    await _queue.add({
      'token': widget.ctx.token,
      'submissionId': id,
      'participantId': _participant,
      'round': 0,
      'answer': {'a': outlineToJson(a), 'b': outlineToJson(b)},
      'lat': centre.latitude,
      'lon': centre.longitude,
    });
    await _send();
    if (!mounted) return;
    setState(() {
      _busy = false;
      final reply = _replies.remove(id);
      final r = reply == null ? null : TimelapseResult.fromReply(reply, a, b);
      if (r != null) _result = r;
      if (r == null && _error == null) _error = s['emergency_queued'];
    });
    await _save();
  }

  void _set(OutlineDraft d) => setState(() => _mode == 1 ? _a = d : _b = d);

  void _tap(LatLng p) {
    if (_mode == 0 || _result != null) return;
    final d = _mode == 1 ? _a : _b;
    final near = d.draft.isNotEmpty && nearOnScreen(_map.camera, d.draft.first, p);
    _set(d.tap(p, near: near));
  }

  int get _shownYear => _mode == 1 ? _yearA : (_mode == 2 ? _yearB : _year);

  List<Widget> _layers() {
    final r = _result;
    final yearIsA = _shownYear == _yearA, yearIsB = _shownYear == _yearB;
    if (r != null) {
      return [
        if (yearIsA) ...[outlineLayer(r.truthA, Colors.white, dashed: true), outlineLayer(r.mineA, Colors.amber)],
        if (yearIsB) ...[outlineLayer(r.truthB, Colors.white, dashed: true), outlineLayer(r.mineB, Colors.cyanAccent)],
      ];
    }
    return [
      if (_mode == 1 || (_mode == 0 && yearIsA)) ...[
        outlineLayer(_a.rings, Colors.amber),
        if (_mode == 1) ...draftLayers(_a.draft, Colors.amber),
      ],
      if (_mode == 2 || (_mode == 0 && yearIsB)) ...[
        outlineLayer(_b.rings, Colors.cyanAccent),
        if (_mode == 2) ...draftLayers(_b.draft, Colors.cyanAccent),
      ],
    ];
  }

  Widget _controls(SiteFrames frames) {
    final r = _result;
    final theme = Theme.of(context);
    final mineA = r?.mineA ?? _a.outline, mineB = r?.mineB ?? _b.outline;
    final areaA = outlineArea(mineA), areaB = outlineArea(mineB);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(widget.ctx.settings['name'] as String? ?? '', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(s.f(r == null ? 'timelapse_task' : 'timelapse_task_done', [_yearA, _yearB])),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          key: const Key('timelapse_mode'),
          segments: [
            ButtonSegment(value: 0, icon: const Icon(Icons.slideshow), label: Text(s['timelapse_watch'])),
            ButtonSegment(value: 1, label: Text('$_yearA')),
            ButtonSegment(value: 2, label: Text('$_yearB')),
          ],
          selected: {_mode},
          onSelectionChanged: (v) => setState(() => _mode = v.first),
        ),
        const SizedBox(height: 8),
        if (_mode == 0) YearPlayer(s: s, frames: frames.frames, year: _year, onYear: (y) => setState(() => _year = y)),
        if (_mode != 0) ...[
          if (frames.frameOf(_shownYear) case final f?) Text(frameLabel(f), style: theme.textTheme.bodySmall),
          if (r == null) ...[
            const SizedBox(height: 4),
            Text(s['timelapse_draw_hint']),
            drawTools(s, _mode == 1 ? _a : _b, _set),
          ],
        ],
        const Divider(),
        Text('$_yearA: ${km2Text(areaA)} km²', key: const Key('timelapse_area_a')),
        Text('$_yearB: ${km2Text(areaB)} km²', key: const Key('timelapse_area_b')),
        Text(s.f('timelapse_change', [changeText(areaA, areaB)]), key: const Key('timelapse_change')),
        const SizedBox(height: 12),
        if (r == null)
          FilledButton.icon(
            key: const Key('timelapse_send'),
            onPressed: _busy ? null : _submit,
            icon: const Icon(Icons.send),
            label: Text(s['timelapse_send']),
          )
        else ...[
          Text(s.f('points', [r.score]), key: const Key('timelapse_score'), style: theme.textTheme.headlineSmall),
          Text(
            s.f('timelapse_match', [
              _yearA,
              (iou(r.truthA, r.mineA) * 100).round(),
              _yearB,
              (iou(r.truthB, r.mineB) * 100).round(),
            ]),
          ),
          const SizedBox(height: 4),
          Text(s.f('timelapse_truth_change', [changeText(outlineArea(r.truthA), outlineArea(r.truthB))])),
          Text(s['timelapse_legend'], style: theme.textTheme.bodySmall),
        ],
        if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        const SizedBox(height: 8),
        Text(frames.attribution.join(' · '), style: theme.textTheme.bodySmall),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_bad) return Center(child: Text(s['session_unreadable']));
    if (_loadError != null) return Center(child: Text(_loadError!));
    final frames = _frames;
    if (frames == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, box) {
        final map = FrameMap(
          controller: _map,
          site: frames,
          frame: frames.frameOf(_shownYear),
          onTap: _tap,
          layers: _layers(),
        );
        return box.maxWidth >= 900
            ? Row(
                children: [
                  Expanded(child: map),
                  SizedBox(width: 380, child: _controls(frames)),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 3, child: map),
                  Expanded(flex: 2, child: _controls(frames)),
                ],
              );
      },
    );
  }
}
