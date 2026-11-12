import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'converter.dart';
import 'coords.dart';
import 'evidence.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'nicknames.dart';
import 'queue.dart';

const _letters = ['ა', 'ბ', 'გ'];
const _lettersEn = ['a', 'b', 'c'];

/// The student's side of the evidence game: read the coordinates off a picture, then answer the task's questions.
class EvidencePlay extends StatefulWidget {
  final S s;
  final String lang;
  final String token;
  final List<EvidenceTask> tasks;
  final int resetAt;
  final Api api;
  final ValueChanged<String> onStopped; // the session was paused or closed while playing
  const EvidencePlay({
    super.key,
    required this.s,
    required this.lang,
    required this.token,
    required this.tasks,
    required this.resetAt,
    required this.api,
    required this.onStopped,
  });
  @override
  State<EvidencePlay> createState() => _EvidencePlayState();
}

/// What the student answered to one task, and how it scored.
class _Result {
  final EvidenceTask task;
  final LatLng? typed, pin;
  final String raw, name;
  final Map<String, int> scores; // a name checked only on the server has no score here until it gets through
  final String right; // the accepted name, from the task or the server's reply
  const _Result(this.task, this.typed, this.pin, this.raw, this.name, this.scores, {this.right = ''});
  int get total => scores.values.fold(0, (a, b) => a + b);
}

class _EvidencePlayState extends State<EvidencePlay> {
  late final _queue = SubmissionQueue(widget.api.submit, onReply: _onReply);
  // The server's replies to name answers by submission id, until the answer they belong to takes its own.
  final _replies = <String, Map<String, dynamic>>{};
  final _boxes = List.generate(6, (_) => TextEditingController());
  final _name = TextEditingController();
  Timer? _retry;
  MapController? _resultMap; // one per result: a map controller can't move to a new map
  bool _loaded = false;
  int _round = 0; // the task on screen; tasks.length when none is left
  final _answered = <int>{};
  int _total = 0;
  String _participant = '';
  _Result? _result;
  LatLng? _pin;
  int? _zone; // the UTM zone the student picked for the answer
  String? _error;
  int _pending = 0;
  bool _busy = false;

  S get s => widget.s;
  String get _progressKey => 'evidence_${widget.token}';
  EvidenceTask? get _task => _round < widget.tasks.length ? widget.tasks[_round] : null;
  int get _maxTotal => widget.tasks.fold(0, (sum, t) => sum + 100 * t.questions.length);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _resultMap?.dispose();
    for (final c in [..._boxes, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId();
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      // After the teacher resets the session everyone starts again.
      if (data['resetAt'] == widget.resetAt) {
        _round = data['round'] as int;
        _answered.addAll((data['answered'] as List).cast<int>());
        _total = data['total'] as int;
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  Future<void> _saveProgress() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({'round': _round, 'answered': _answered.toList(), 'total': _total, 'resetAt': widget.resetAt}),
  );

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    final named = (item['answer'] as Map?)?['q'] == 'name';
    if (item['token'] == widget.token && named) _replies[item['submissionId'] as String] = reply;
  }

  /// Returns true unless the session stopped accepting answers.
  /// [waiting] is the name answer whose result is shown now. Names checked only on the server and sent later,
  /// after a lost connection, add their score to the total here.
  Future<bool> _send({String? waiting}) async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return false;
    var late = 0;
    for (final id in _replies.keys.where((id) => id != waiting).toList()) {
      late += (_replies.remove(id)!['score'] as num? ?? 0).toInt();
    }
    if (late > 0) {
      setState(() => _total += late);
      _saveProgress();
    }
    if (refused == 'session_paused' || refused == 'session_closed') {
      widget.onStopped(refused!.replaceFirst('session_', ''));
      return false;
    }
    setState(() {
      _pending = pending;
      if (refused != null) _error = refused;
    });
    if (pending > 0) _retry = Timer(const Duration(seconds: 15), _send);
    return true;
  }

  Future<void> _answer() async {
    if (_busy) return;
    final task = _task!;
    LatLng? typed;
    var raw = '';
    if (task.asks('coords')) {
      final zone = task.ask == 'utm' ? _zone : null;
      if (task.ask == 'utm' && zone == null) {
        setState(() => _error = 'ev_need_zone');
        return;
      }
      raw = joinBoxes(task.ask, _boxes.map((c) => c.text).toList(), south: task.lat < 0, west: task.lon < 0, zone: zone);
      typed = parseAs(task.ask, raw, zone: zone);
      if (typed == null) {
        setState(() => _error = 'play_bad_input');
        return;
      }
    }
    if (task.asks('map') && _pin == null) {
      setState(() => _error = 'play_need_pin');
      return;
    }
    final name = _name.text.trim();
    if (task.asks('name') && name.isEmpty) {
      setState(() => _error = 'ev_need_name');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    Map<String, dynamic> submission(Map<String, dynamic> answer, LatLng? point) => {
      'token': widget.token,
      'submissionId': randomId(),
      'participantId': _participant,
      'round': _round,
      'answer': answer,
      'lat': point?.latitude ?? 0,
      'lon': point?.longitude ?? 0,
    };
    if (typed != null) await _queue.add(submission({'q': 'coords', 'raw': raw, 'format': task.ask}, typed));
    if (task.asks('map')) await _queue.add(submission({'q': 'map'}, _pin));
    final named = task.asks('name') ? submission({'q': 'name', 'name': name}, null) : null;
    if (named != null) await _queue.add(named);
    // The result shows only after sending, so a paused session can't reveal the answer.
    final accepted = await _send(waiting: named?['submissionId'] as String?);
    if (!mounted) return;
    _busy = false;
    if (!accepted) return;

    // The picture shows the coordinates, so those are scored here. The accepted names may have stayed on the
    // server (online answers): then the name's score comes from its reply, or later if it is still waiting.
    final reply = named == null ? null : _replies.remove(named['submissionId']);
    final served = reply?['score'] as num?;
    final nameScore = served != null
        ? served.toInt()
        : (named != null && task.names.isNotEmpty ? (nameMatches(task, name) ? 100 : 0) : null);
    final scores = <String, int>{
      if (typed != null) 'coords': strictScoreFor(distanceM(typed.latitude, typed.longitude, task.lat, task.lon)),
      if (task.asks('map')) 'map': scoreFor(distanceM(_pin!.latitude, _pin!.longitude, task.lat, task.lon)),
      'name': ?nameScore,
    };
    final right = reply?['right'] as String? ?? (task.names.isEmpty ? '' : task.names.first);
    final result = _Result(task, typed, _pin, raw, name, scores, right: right);
    setState(() {
      _resultMap?.dispose();
      _resultMap = MapController();
      _result = result;
      _total += result.total;
      _answered.add(_round);
      _round = _nextOpen();
    });
    await _saveProgress();
  }

  int _nextOpen() {
    final count = widget.tasks.length;
    for (var i = 1; i < count; i++) {
      final task = (_round + i) % count;
      if (!_answered.contains(task)) return task;
    }
    return count;
  }

  void _clear() {
    setState(() {
      _result = null;
      _pin = null;
      _zone = null;
      for (final c in [..._boxes, _name]) {
        c.clear();
      }
      _error = null;
    });
  }

  void _goTo(int task) {
    _clear();
    setState(() => _round = task);
    _saveProgress();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_result != null) return _resultView(_result!);
    final task = _task;
    return task == null ? _finished() : _taskView(task);
  }

  Widget _page(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    ),
  );

  // Fixed per question, as on the teacher's page: a task without the map question goes from ა to გ.
  String _letter(String question) => (widget.lang == 'en' ? _lettersEn : _letters)[evidenceQuestions.indexOf(question)];

  Widget _question(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
  );

  Widget _grid(EvidenceTask task) =>
      task.shown == 'utm' ? UtmGridLayer(zone: utmZone(task.lon)) : GraticuleLayer(format: task.shown);

  Widget _picture(EvidenceTask task) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: task.kind == 'receipt' ? 420 : 300),
      child: EvidencePicture(s: s, task: task),
    ),
  );

  Widget _taskView(EvidenceTask task) {
    final text = Theme.of(context).textTheme;
    final showMap = task.asks('map') || task.asks('name');
    return _page([
      Text(s.f('play_task', [_round + 1, widget.tasks.length]), style: text.titleMedium),
      LinearProgressIndicator(value: _answered.length / widget.tasks.length),
      const SizedBox(height: 4),
      Text(s.f('play_nick', [nickname(_participant, widget.lang)]), style: text.bodySmall),
      if (widget.tasks.length > 1) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < widget.tasks.length; i++)
              ChoiceChip(
                label: Text('${i + 1}'),
                selected: i == _round,
                showCheckmark: false,
                avatar: _answered.contains(i) ? const Icon(Icons.check, size: 16) : null,
                visualDensity: VisualDensity.compact,
                onSelected: _answered.contains(i) || _busy ? null : (_) => i == _round ? null : _goTo(i),
              ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Text(s['ev_play_${task.kind}'], style: text.titleLarge),
      const SizedBox(height: 4),
      Text(s['ev_play_hint'], style: text.bodyMedium),
      const SizedBox(height: 8),
      _picture(task),
      if (task.converter) ...[
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(s['ev_converter']),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [CoordConverter(s: s)],
          ),
        ),
      ],
      if (task.asks('coords')) ...[
        _question('${_letter('coords')}) ${s.f('ev_q_coords', [s['format_${task.ask}']])}'),
        if (task.ask == 'utm') ...[
          SegmentedButton<int>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 37, label: Text('UTM 37N')),
              ButtonSegment(value: 38, label: Text('UTM 38N')),
            ],
            selected: {?_zone},
            onSelectionChanged: (v) => setState(() => _zone = v.isEmpty ? null : v.first),
          ),
          const SizedBox(height: 8),
        ],
        CoordBoxes(s: s, format: task.ask, boxes: _boxes, south: task.lat < 0, west: task.lon < 0, zone: _zone),
      ],
      if (showMap) ...[
        _question(task.asks('map') ? '${_letter('map')}) ${s['ev_q_map']}' : s['ev_map_look']),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 360,
            child: FlutterMap(
              key: ValueKey(_round),
              options: MapOptions(
                initialCenter: const LatLng(42.2, 43.5),
                initialZoom: 6.5,
                minZoom: 5,
                onTap: task.asks('map')
                    ? (_, point) => setState(() => _pin = LatLng(point.latitude, (point.longitude + 180) % 360 - 180))
                    : null,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              ),
              children: [
                ...baseLayers(BaseMap.osm, 1),
                _grid(task),
                MarkerLayer(
                  markers: [
                    if (_pin != null)
                      Marker(
                        point: _pin!,
                        width: 44,
                        height: 44,
                        alignment: Alignment.topCenter,
                        child: Icon(Icons.location_pin, size: 44, color: Theme.of(context).colorScheme.primary),
                      ),
                  ],
                ),
                ...mapFurniture(BaseMap.osm),
              ],
            ),
          ),
        ),
      ],
      if (task.asks('name')) ...[
        _question('${_letter('name')}) ${s['ev_q_name']}'),
        TextField(
          controller: _name,
          maxLength: 120,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: s['ev_name_hint'], border: const OutlineInputBorder(), counterText: ''),
        ),
      ],
      const SizedBox(height: 16),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(s[_error!], style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      FilledButton.icon(
        onPressed: _busy ? null : _answer,
        icon: const Icon(Icons.check),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['play_answer'])),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : () => _goTo(_nextOpen()),
        icon: const Icon(Icons.skip_next),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['play_skip'])),
      ),
    ]);
  }

  Widget _scoreLine(String title, int score, String detail) {
    final theme = Theme.of(context);
    final good = score >= 100;
    return Card(
      child: ListTile(
        leading: Icon(
          good ? Icons.check_circle : (score > 0 ? Icons.adjust : Icons.cancel),
          color: good ? Colors.green : (score > 0 ? Colors.orange : theme.colorScheme.error),
        ),
        title: Text(title),
        subtitle: Text(detail),
        trailing: Text('$score', style: theme.textTheme.titleLarge),
      ),
    );
  }

  Widget _resultView(_Result r) {
    final text = Theme.of(context).textTheme;
    final task = r.task;
    final target = LatLng(task.lat, task.lon);
    final points = [target, ?r.typed, ?r.pin];
    final fit = points.any((p) => p != target);
    return _page([
      Text(s.f('ev_result_total', [r.total, 100 * r.scores.length]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (r.typed != null)
        _scoreLine(
          s['ev_r_coords'],
          r.scores['coords']!,
          '${s.f('ev_r_typed', [r.raw])}\n${s.f('ev_r_right', [formatAs(task.ask, task.lat, task.lon)])}\n'
          '${s.f('result_distance', [formatDistance(distanceM(r.typed!.latitude, r.typed!.longitude, task.lat, task.lon))])}',
        ),
      if (r.pin != null)
        _scoreLine(
          s['ev_r_map'],
          r.scores['map']!,
          s.f('result_distance', [formatDistance(distanceM(r.pin!.latitude, r.pin!.longitude, task.lat, task.lon))]),
        ),
      if (task.asks('name') && r.scores['name'] != null)
        _scoreLine(s['ev_r_name'], r.scores['name']!, '${s.f('ev_r_typed', [r.name])}\n${s.f('ev_r_right', [r.right])}')
      else if (task.asks('name'))
        Card(child: ListTile(leading: const Icon(Icons.schedule), title: Text(s['ev_r_name']), subtitle: Text(s['play_checked_later']))),
      if (r.total < 100 * r.scores.length)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(s['ev_r_teacher'], style: text.bodySmall),
        ),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 260,
          child: FlutterMap(
            mapController: _resultMap,
            options: MapOptions(
              // Fitted just after the map opens: fitted any sooner, its tiles stay unloaded until the map moves.
              onMapReady: () => Future.delayed(const Duration(milliseconds: 300), () {
                if (!mounted || _result != r) return;
                final camera = _resultMap!.camera;
                if (fit) {
                  _resultMap!.fitCamera(
                    CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(48), maxZoom: 15),
                  );
                } else {
                  _resultMap!.move(camera.center, camera.zoom);
                }
              }),
              initialCenter: target,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              ...baseLayers(BaseMap.osm, 1),
              MarkerLayer(
                markers: [
                  if (r.typed != null)
                    Marker(
                      point: r.typed!,
                      width: 36,
                      height: 36,
                      alignment: Alignment.topCenter,
                      child: Icon(Icons.edit_location_alt, size: 36, color: Theme.of(context).colorScheme.tertiary),
                    ),
                  if (r.pin != null)
                    Marker(
                      point: r.pin!,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: Icon(Icons.location_pin, size: 44, color: Theme.of(context).colorScheme.primary),
                    ),
                  Marker(
                    point: target,
                    width: 36,
                    height: 36,
                    child: const Icon(Icons.star, size: 36, color: Color(0xFFFFB300), shadows: [Shadow(blurRadius: 4)]),
                  ),
                ],
              ),
              ...mapFurniture(BaseMap.osm),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            '${s['result_target']}\nDD:  ${formatDd(task.lat, task.lon)}\nDM:  ${formatDm(task.lat, task.lon)}\n'
            'DMS:  ${formatDms(task.lat, task.lon)}\nUTM:  ${formatUtm(task.lat, task.lon)}',
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(s[_error!], style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      if (_pending > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s['done_pending'])),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _clear,
        icon: const Icon(Icons.arrow_forward),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['next'])),
      ),
    ]);
  }

  Widget _finished() {
    final text = Theme.of(context).textTheme;
    final skipped = widget.tasks.length - _answered.length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(s['done_title'], style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(s.f('done_total', [_total, _maxTotal]), style: text.titleLarge),
            const SizedBox(height: 4),
            Text(nickname(_participant, widget.lang)),
            const SizedBox(height: 8),
            Text(s['ev_done_note'], textAlign: TextAlign.center, style: text.bodySmall),
            if (skipped > 0) ...[
              const SizedBox(height: 12),
              Text(s.f('done_skipped', [skipped]), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _goTo(List.generate(widget.tasks.length, (i) => i).firstWhere((i) => !_answered.contains(i))),
                child: Text(s['done_back']),
              ),
            ],
            if (_pending > 0) ...[const SizedBox(height: 12), Text(s['done_pending'], textAlign: TextAlign.center)],
          ],
        ),
      ),
    );
  }
}
