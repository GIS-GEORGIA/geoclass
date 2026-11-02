import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'coords.dart';
import 'export.dart';
import 'geo_map.dart';
import 'models.dart';
import 'nicknames.dart';
import 'session_base.dart';

/// The coordinates game: where students placed each task's point, and the leaderboard.
class CoordinatesSessionPage extends SessionPageBase {
  const CoordinatesSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<CoordinatesSessionPage> createState() => _CoordinatesSessionPageState();
}

Color scoreColor(int score) => score >= 80
    ? const Color(0xFF2E7D32)
    : score >= 40
        ? const Color(0xFFEF6C00)
        : const Color(0xFFC62828);

class _CoordinatesSessionPageState extends SessionPageState<CoordinatesSessionPage> {
  List<CoordAnswer> _answers = const [];
  int _task = 0;
  bool _showTasks = false;

  List<CoordTask> get _tasks => CoordTask.listFrom(session.settings);
  List<CoordAnswer> get _taskAnswers => _answers.where((a) => a.round == _task).toList();

  @override
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) CoordAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints {
    final tasks = _tasks;
    if (tasks.isEmpty) return const [];
    final t = tasks[_task];
    return [LatLng(t.lat, t.lon), for (final a in _taskAnswers) LatLng(a.lat, a.lon)];
  }

  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() => coordAnswersToCsv(_answers, _tasks, lang);
  @override
  String exportGeoJson() => coordAnswersToGeoJson(_answers, _tasks, lang);
  @override
  Widget gridLayer() {
    final tasks = _tasks;
    if (tasks.isEmpty || tasks[_task].format != 'utm') return super.gridLayer();
    return UtmGridLayer(zone: utmZone(tasks[_task].lon));
  }

  void _select(int task) {
    setState(() {
      _task = task;
      showMapTab();
    });
    fitAll();
  }

  @override
  List<Widget> mapLayers() {
    final tasks = _tasks;
    if (tasks.isEmpty) return const [];
    final t = tasks[_task];
    final target = LatLng(t.lat, t.lon);
    final answers = _taskAnswers;
    return [
      PolylineLayer(polylines: [
        for (final a in answers)
          Polyline(
            points: [LatLng(a.lat, a.lon), target],
            color: scoreColor(a.score).withValues(alpha: 0.5),
            strokeWidth: 2,
          ),
      ]),
      MarkerLayer(markers: [
        for (final a in answers)
          Marker(
            point: LatLng(a.lat, a.lon),
            width: 20,
            height: 20,
            child: Tooltip(
              message: '${nickname(a.participantId, lang)}: ${formatDistance(a.distanceM)}',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scoreColor(a.score),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ),
        Marker(
          point: target,
          width: 40,
          height: 40,
          child: const Icon(Icons.star, size: 40, color: Color(0xFFFFB300), shadows: [Shadow(blurRadius: 4)]),
        ),
      ]),
    ];
  }

  @override
  List<Widget> mapOverlays() {
    final tasks = _tasks;
    if (tasks.isEmpty) return const [];
    final t = tasks[_task];
    final top = leaderboard(_answers).take(5).toList();
    return [
      Positioned(
        top: present ? 8 : 64,
        left: 8,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _task > 0 ? () => _select(_task - 1) : null,
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.f('play_task', [_task + 1, tasks.length]), style: Theme.of(context).textTheme.titleSmall),
                    Text(formatAs(t.format, t.lat, t.lon), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _task < tasks.length - 1 ? () => _select(_task + 1) : null,
                ),
              ],
            ),
          ),
        ),
      ),
      if (present && top.isNotEmpty)
        Positioned(
          left: 8,
          bottom: 40,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s['leaderboard'], style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  for (final (i, r) in top.indexed)
                    Text('${i + 1}. ${nickname(r.participantId, lang)}: ${r.score}'),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  @override
  Widget panel() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(s['leaderboard'])),
                ButtonSegment(value: true, label: Text(s['tasks'])),
              ],
              selected: {_showTasks},
              onSelectionChanged: (v) => setState(() => _showTasks = v.first),
            ),
          ),
          Expanded(child: _showTasks ? _taskList() : _leaderboard()),
        ],
      );

  Widget _leaderboard() {
    final rows = leaderboard(_answers);
    if (rows.isEmpty) return Center(child: Text(s['no_results']));
    final total = _tasks.length;
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final r = rows[i];
        return ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang)),
          subtitle: Text(s.f('answered_of', [r.answered, total])),
          trailing: Text(s.f('points', [r.score]), style: Theme.of(context).textTheme.titleSmall),
        );
      },
    );
  }

  Widget _taskList() {
    final tasks = _tasks;
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (_, i) {
        final t = tasks[i];
        final answers = _answers.where((a) => a.round == i).toList();
        final average = answers.isEmpty
            ? '–'
            : formatDistance(answers.map((a) => a.distanceM).reduce((x, y) => x + y) / answers.length);
        return ListTile(
          selected: i == _task,
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(t.label.isEmpty ? formatAs(t.format, t.lat, t.lon) : t.label),
          subtitle: Text('${s['mode_${t.mode}']}\n${s.f('task_stats', [answers.length, average])}'),
          isThreeLine: true,
          onTap: () => _select(i),
        );
      },
    );
  }
}
