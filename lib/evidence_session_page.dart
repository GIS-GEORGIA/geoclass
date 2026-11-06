import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'coordinates_session_page.dart' show scoreColor;
import 'coords.dart';
import 'evidence.dart';
import 'export.dart';
import 'nicknames.dart';
import 'session_base.dart';

/// The evidence game: the leaderboard, and each task's answers, where the teacher can count a slip as right.
class EvidenceSessionPage extends SessionPageBase {
  const EvidenceSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<EvidenceSessionPage> createState() => _EvidenceSessionPageState();
}

class _EvidenceSessionPageState extends SessionPageState<EvidenceSessionPage> {
  List<EvidenceAnswer> _answers = const [];
  bool _review = false;
  int _task = 0;

  List<EvidenceTask> get _tasks => EvidenceTask.listFrom(session.settings);

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) EvidenceAnswer.fromJson(r)];
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() => evidenceToCsv(_answers, _tasks, lang);
  @override
  String exportGeoJson() => evidenceToGeoJson(_answers, _tasks, lang);
  @override
  List<Widget> mapLayers() => const [];
  @override
  List<Widget> mapOverlays() => const [];

  void _accept(EvidenceAnswer a, bool accepted) => run(() => api.setAccepted(a.id, accepted));

  @override
  Widget panel() {
    final tasks = _tasks;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(s['leaderboard'])),
                ButtonSegment(value: true, label: Text(s['ev_review'])),
              ],
              selected: {_review},
              onSelectionChanged: (v) => setState(() => _review = v.first),
            ),
            const SizedBox(height: 8),
            if (_review && tasks.isNotEmpty) ..._reviewRows(tasks) else if (!_review) ..._leaderRows(tasks),
          ],
        ),
      ),
    );
  }

  List<Widget> _leaderRows(List<EvidenceTask> tasks) {
    final rows = evidenceLeaderboard(_answers);
    if (rows.isEmpty) return [Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(s['no_results'])))];
    final max = tasks.fold(0, (sum, t) => sum + 100 * t.questions.length);
    final text = Theme.of(context).textTheme;
    return [
      for (final (i, r) in rows.indexed)
        ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang), style: text.titleMedium),
          subtitle: Text(s.f('ev_answers_count', [r.answers])),
          trailing: Text('${r.points} / $max', style: text.titleLarge),
        ),
    ];
  }

  String _given(EvidenceAnswer a) => switch (a.question) {
    'coords' => '${a.raw}  ·  ${formatDistance(a.distanceM ?? 0)}',
    'map' => '${formatDd(a.lat, a.lon)}  ·  ${formatDistance(a.distanceM ?? 0)}',
    _ => a.name,
  };

  List<Widget> _reviewRows(List<EvidenceTask> tasks) {
    final task = tasks[_task.clamp(0, tasks.length - 1)];
    final theme = Theme.of(context);
    final mine = _answers.where((a) => a.task == _task).toList()
      ..sort((a, b) => a.participantId != b.participantId ? a.participantId.compareTo(b.participantId) : a.round.compareTo(b.round));
    return [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < tasks.length; i++)
            ChoiceChip(
              label: Text('${i + 1}'),
              selected: i == _task,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() => _task = i),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(task.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              SelectableText(
                '${s['ev_kind_${task.kind}']} · ${s['ev_shown']}: ${task.shown.toUpperCase()}\n'
                '${s['ev_ask']}: ${formatAs(task.ask, task.lat, task.lon)}'
                '${task.names.isEmpty ? '' : '\n${s['ev_names']}: ${task.names.join(' / ')}'}',
              ),
              const SizedBox(height: 8),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: EvidencePicture(s: s, task: task),
                ),
              ),
            ],
          ),
        ),
      ),
      if (mine.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s['no_results']))),
      for (final a in mine)
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${nickname(a.participantId, lang)} · ${s['ev_short_${a.question}']}', style: theme.textTheme.titleSmall),
                      SelectableText(_given(a)),
                      if (a.accepted)
                        Text(s.f('ev_accepted_note', [a.score]), style: theme.textTheme.bodySmall?.copyWith(color: Colors.green[800])),
                    ],
                  ),
                ),
                Text('${a.points}', style: theme.textTheme.titleLarge?.copyWith(color: scoreColor(a.points))),
                const SizedBox(width: 8),
                if (a.accepted)
                  TextButton(onPressed: () => _accept(a, false), child: Text(s['ev_unaccept']))
                else if (a.score < 100)
                  OutlinedButton(onPressed: () => _accept(a, true), child: Text(s['ev_accept'])),
              ],
            ),
          ),
        ),
    ];
  }
}
