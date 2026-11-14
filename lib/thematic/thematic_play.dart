import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files.dart';
import '../games/game.dart';
import '../l10n.dart';
import '../puzzle.dart' show GeoUnits, loadGeoUnits;
import '../queue.dart';
import '../student_message.dart';
import 'thematic.dart';
import 'thematic_map.dart';

/// The student's side of the thematic map: the teacher's data on the map of Georgia; the student chooses how
/// to show it and hands the map in. In target mode the target and the score show once it is sent.
class ThematicPlay extends StatefulWidget {
  final PlayContext ctx;
  final GeoUnits? units;
  const ThematicPlay({super.key, required this.ctx, this.units});

  @override
  State<ThematicPlay> createState() => _ThematicPlayState();
}

class _ThematicPlayState extends State<ThematicPlay> {
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  Timer? _retry;

  ThematicSettings? _settings;
  ThematicBase? _base;
  String _participant = '';
  bool _loaded = false;

  ThematicChoice _choice = const ThematicChoice(field: 0);
  bool _sent = false, _busy = false;
  int? _score;
  ThematicChoice? _target;
  String? _error;

  S get s => widget.ctx.s;
  String get lang => widget.ctx.lang;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      _settings = ThematicSettings.fromJson(widget.ctx.settings);
    } on FormatException {
      _settings = null;
    }
    if (_settings != null) _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final all = widget.units ?? await loadGeoUnits();
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        if (data['resetAt'] == widget.ctx.resetAt) {
          final c = ThematicChoice.fromJson(data['choice'] as Map<String, dynamic>);
          if (c.field < _settings!.fields.length) _choice = c;
          _sent = data['sent'] as bool;
          _score = data['score'] as int?;
          final t = data['target'];
          _target = t == null ? null : ThematicChoice.fromJson(t as Map<String, dynamic>);
        }
      } on Object {
        // A damaged save starts again.
      }
    }
    if (!mounted) return;
    setState(() {
      _base = ThematicBase.of(all, _settings!);
      _loaded = true;
    });
    _send();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'choice': _choice.toJson(),
      'sent': _sent,
      'score': _score,
      'target': _target?.toJson(),
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
    if (reply['target'] is Map) {
      try {
        _target = ThematicChoice.fromJson((reply['target'] as Map).cast<String, dynamic>());
      } on FormatException {
        _target = null;
      }
    }
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

  Future<void> _answerNow() async {
    if (_busy || _sent) return;
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
      'answer': _choice.toJson(),
      'lat': 42.3,
      'lon': 43.4,
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

  void _compare(ThematicBase base, ThematicSettings st) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s['thematic_compare']),
      content: SizedBox(
        width: 1000,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s['thematic_compare_hint']),
              const SizedBox(height: 8),
              ThematicCompare(base: base, settings: st, choice: _choice, s: s, lang: lang),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s['close']))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final st = _settings;
    if (st == null) return StudentMessage(Icons.error_outline, s['profile_bad_session']);
    final base = _base;
    if (!_loaded || base == null) return const Center(child: CircularProgressIndicator());
    final view = ThematicView.of(base, st, _choice);
    final text = Theme.of(context).textTheme;
    final target = _target;
    final map = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (st.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(st.title, style: text.titleMedium),
          ),
        Expanded(
          child: ChoroplethView(view: view, s: s, lang: lang),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: ThematicLegend(view: view, s: s),
        ),
      ],
    );
    final panel = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(s[st.mode == 'target' ? 'thematic_question_target' : 'thematic_question_free'], style: text.titleMedium),
        const SizedBox(height: 8),
        if (!_sent) ...[
          ThematicChoiceEditor(
            settings: st,
            base: base,
            choice: _choice,
            s: s,
            onChanged: (c) {
              setState(() => _choice = c);
              _save();
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                key: const Key('thematic_compare'),
                onPressed: () => _compare(base, st),
                icon: const Icon(Icons.compare),
                label: Text(s['thematic_compare']),
              ),
              FilledButton.icon(
                key: const Key('thematic_answer'),
                onPressed: _busy ? null : _answerNow,
                icon: const Icon(Icons.check),
                label: Text(s['thematic_hand_in']),
              ),
            ],
          ),
        ] else ...[
          if (st.mode == 'free')
            Text(s['thematic_sent'], key: const Key('thematic_sent'))
          else if (_score == null || target == null)
            Text(s['play_checked_later'])
          else ...[
            Text(s.f('result_score', [_score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(
              s.f('thematic_target_line', [
                st.fields[target.field].name,
                s['thematic_normalise_${target.normalise}'],
                s['thematic_method_${target.method}'],
                target.classes,
              ]),
              key: const Key('thematic_target'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 260,
              child: ChoroplethView(view: ThematicView.of(base, st, target), s: s, lang: lang),
            ),
            ThematicLegend(view: ThematicView.of(base, st, target), s: s),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('thematic_pdf'),
            onPressed: () async =>
                saveBytes(await thematicPdf(view, s, st.title), 'geoclass-map', 'pdf', 'application/pdf'),
            icon: const Icon(Icons.picture_as_pdf),
            label: Text(s['layout_pdf']),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s[_error!], style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 900
          ? Row(
              children: [
                Expanded(child: map),
                SizedBox(width: 420, child: Material(elevation: 2, child: panel)),
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
}
