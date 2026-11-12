import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'coords.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'models.dart';
import 'nicknames.dart';
import 'photos.dart';
import 'queue.dart';

/// The student's side of the coordinates and aerial games: one task at a time, with the result after each.
class CoordinatesPlay extends StatefulWidget {
  final S s;
  final String lang;
  final String token;
  final List<CoordTask> tasks;
  final int resetAt;
  final Api api;
  final ValueChanged<String> onStopped; // the session was paused or closed while playing
  const CoordinatesPlay({
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
  State<CoordinatesPlay> createState() => _CoordinatesPlayState();
}

class _Result {
  final CoordTask task;
  final double lat, lon, distance;
  final int score;
  final double targetLat, targetLon; // the right point: the task's own, or from the server's reply
  final String label, labelEn;
  const _Result(this.task, this.lat, this.lon, this.distance, this.score,
      {required this.targetLat, required this.targetLon, this.label = '', this.labelEn = ''});
  String labelFor(String lang) => lang == 'en' && labelEn.isNotEmpty ? labelEn : label;
}

class _CoordinatesPlayState extends State<CoordinatesPlay> {
  late final _queue = SubmissionQueue(widget.api.submit, onReply: _onReply);
  // The server's replies by submission id, until the answer they belong to takes its own.
  final _replies = <String, (int, Map<String, dynamic>)>{};
  // The boxes of the answer frame. joinBoxes says what each one holds in each format.
  final _boxes = List.generate(6, (_) => TextEditingController());
  final _map = MapController();
  Timer? _retry;
  bool _loaded = false;
  int _round = 0; // the task on screen; tasks.length means none is left to show
  final _answered = <int>{};
  int _total = 0;
  String _participant = '';
  _Result? _result;
  LatLng? _pin;
  String? _error;
  int _pending = 0;
  bool _busy = false;

  S get s => widget.s;
  String get _progressKey => 'progress_${widget.token}';
  CoordTask? get _task => _round < widget.tasks.length ? widget.tasks[_round] : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    for (final c in _boxes) {
      c.dispose();
    }
    _map.dispose();
    super.dispose();
  }

  // Reopening the link continues where the student stopped.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      // After the teacher resets the session everyone starts again.
      if (data['resetAt'] == widget.resetAt) {
        _round = data['round'] as int;
        // Progress saved before tasks could be skipped has only the position.
        _answered.addAll((data['answered'] as List?)?.cast<int>() ?? List.generate(_round, (i) => i));
        _total = data['total'] as int;
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
    _preloadPhoto();
  }

  // The next photo is ready at once, and stays available if the connection drops.
  void _preloadPhoto() {
    final photo = _task?.photo ?? '';
    if (photo.isNotEmpty) precacheImage(NetworkImage(photoUrl(photo)), context, onError: (_, _) {});
  }

  Future<void> _saveProgress() async => (await SharedPreferences.getInstance())
      .setString(_progressKey, jsonEncode({'round': _round, 'answered': _answered.toList(), 'total': _total, 'resetAt': widget.resetAt}));

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    if (item['token'] == widget.token) _replies[item['submissionId'] as String] = (item['round'] as int, reply);
  }

  /// Returns true unless the session stopped accepting answers.
  /// [waiting] is the answer whose result is shown now; the scores of answers sent later, after a lost
  /// connection, are added to the total here.
  Future<bool> _send({String? waiting}) async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return false;
    var late = 0;
    for (final id in _replies.keys.where((id) => id != waiting).toList()) {
      final (round, reply) = _replies.remove(id)!;
      if (round < widget.tasks.length && widget.tasks[round].secret) late += (reply['score'] as num? ?? 0).toInt();
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
    final LatLng? point;
    var raw = '';
    if (task.mode == 'read') {
      raw = joinBoxes(
        task.format,
        _boxes.map((c) => c.text).toList(),
        south: task.lat < 0,
        west: task.lon < 0,
        zone: utmZone(task.lon),
      );
      point = parseAs(task.format, raw, zone: utmZone(task.lon));
      if (point == null) {
        setState(() => _error = 'play_bad_input');
        return;
      }
    } else {
      point = _pin;
      if (point == null) {
        setState(() => _error = 'play_need_pin');
        return;
      }
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final submissionId = randomId();
    await _queue.add({
      'token': widget.token,
      'submissionId': submissionId,
      'participantId': _participant,
      'round': _round,
      'answer': {'raw': raw, 'format': task.format, 'mode': task.mode},
      'lat': point.latitude,
      'lon': point.longitude,
    });
    // The result shows only after sending, so a paused session can't reveal the answer.
    final accepted = await _send(waiting: submissionId);
    if (!mounted) return;
    _busy = false;
    if (!accepted) return;

    // The server's result when there is one. Without it, a task that came with its answer is scored here;
    // one whose answer stayed on the server is scored once the answer gets through.
    final reply = _replies.remove(submissionId)?.$2;
    final target = reply?['target'] as Map<String, dynamic>?;
    _Result? result;
    if (reply != null && target != null) {
      result = _Result(
        task,
        point.latitude,
        point.longitude,
        (reply['distanceM'] as num).toDouble(),
        (reply['score'] as num).toInt(),
        targetLat: (target['lat'] as num).toDouble(),
        targetLon: (target['lon'] as num).toDouble(),
        label: target['label'] as String? ?? '',
        labelEn: target['labelEn'] as String? ?? '',
      );
    } else if (!task.secret) {
      final distance = distanceM(point.latitude, point.longitude, task.lat, task.lon);
      result = _Result(task, point.latitude, point.longitude, distance, scoreFor(distance),
          targetLat: task.lat, targetLon: task.lon, label: task.label, labelEn: task.labelEn);
    }
    if (result == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(s['play_checked_later'])));
    }
    setState(() {
      _result = result;
      _total += result?.score ?? 0;
      _answered.add(_round);
      _round = _nextOpen();
    });
    _preloadPhoto();
    await _saveProgress();
  }

  /// The next unanswered task after this one, going round to the start; tasks.length if there is none.
  int _nextOpen() {
    final count = widget.tasks.length;
    for (var i = 1; i < count; i++) {
      final task = (_round + i) % count;
      if (!_answered.contains(task)) return task;
    }
    return count;
  }

  void _goTo(int task) {
    _next();
    setState(() => _round = task);
    _preloadPhoto();
    _saveProgress();
  }

  /// Numbers to jump between tasks. An answered one stays closed: the first try counts and its result was shown.
  Widget _taskButtons() => Wrap(
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
              onSelected: _answered.contains(i) || _busy
                  ? null
                  : (_) {
                      if (i != _round) _goTo(i);
                    },
            ),
        ],
      );

  void _next() {
    setState(() {
      _result = null;
      _pin = null;
      for (final c in _boxes) {
        c.clear();
      }
      _error = null;
    });
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

  Widget _grid(String format, int zone) =>
      format == 'utm' ? UtmGridLayer(zone: zone) : GraticuleLayer(format: format);

  /// One line of the answer frame. Each box is (mark after it, allows decimals, longest length).
  Widget _boxRow(String title, int first, List<(String, bool, int)> boxes) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 4),
      Row(children: [
        for (var i = 0; i < boxes.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _boxes[first + i],
              keyboardType: TextInputType.numberWithOptions(decimal: boxes[i].$2),
              textInputAction: TextInputAction.next,
              maxLength: boxes[i].$3,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(boxes[i].$2 ? r'[0-9.,]' : r'[0-9]'))],
              decoration: InputDecoration(
                // suffixText hides until the box is used, and these marks are what make the frame clear.
                suffixIcon: Align(widthFactor: 1, child: Text(boxes[i].$1)),
                suffixIconConstraints: const BoxConstraints(minWidth: 28),
                counterText: '',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ]),
    ]);
  }

  /// A ready-made frame for the answer, so nothing but numbers has to be typed.
  List<Widget> _answerFrame(CoordTask task, int zone) {
    final lat = s.f('play_lat', [task.lat < 0 ? 'S' : 'N']);
    final lon = s.f('play_lon', [task.lon < 0 ? 'W' : 'E']);
    final (first, second) = switch (task.format) {
      'dms' => (
          _boxRow(lat, 0, [('°', false, 3), ('′', false, 2), ('″', false, 2)]),
          _boxRow(lon, 3, [('°', false, 3), ('′', false, 2), ('″', false, 2)]),
        ),
      'dm' => (
          _boxRow(lat, 0, [('°', false, 3), ('′', true, 7)]),
          _boxRow(lon, 2, [('°', false, 3), ('′', true, 7)]),
        ),
      'utm' => (
          _boxRow(s.f('play_easting', ['${zone}N']), 0, [('m', false, 6)]),
          _boxRow(s['play_northing'], 1, [('m', false, 7)]),
        ),
      _ => (_boxRow(lat, 0, [('°', true, 9)]), _boxRow(lon, 1, [('°', true, 9)])),
    };
    return [first, const SizedBox(height: 8), second, const SizedBox(height: 12)];
  }

  Widget _taskView(CoordTask task) {
    final text = Theme.of(context).textTheme;
    final readMode = task.mode == 'read';
    final photoMode = task.mode == 'photo';
    final zone = utmZone(task.lon);
    final center = readMode ? LatLng(task.lat, task.lon) : const LatLng(42.2, 43.5);
    return _page([
      Text(s.f('play_task', [_round + 1, widget.tasks.length]), style: text.titleMedium),
      LinearProgressIndicator(value: _answered.length / widget.tasks.length),
      const SizedBox(height: 4),
      Text(s.f('play_nick', [nickname(_participant, widget.lang)]), style: text.bodySmall),
      if (widget.tasks.length > 1) ...[
        const SizedBox(height: 8),
        _taskButtons(),
      ],
      const SizedBox(height: 12),
      Text(s[photoMode ? 'play_photo' : (readMode ? 'play_read' : 'play_to_map')], style: text.titleLarge),
      const SizedBox(height: 8),
      if (photoMode)
        TaskPhoto(s: s, file: task.photo, height: 200)
      else if (!readMode)
        SelectableText(
          formatAs(task.format, task.lat, task.lon),
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
      const SizedBox(height: 4),
      Text(
        s[photoMode
            ? 'play_photo_hint'
            : (readMode ? 'play_read_hint_${task.format}' : 'play_to_map_hint')],
        style: text.bodyMedium,
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          // Photo and map both fit on a phone, so the student can compare them.
          height: photoMode ? 300 : 360,
          child: FlutterMap(
            key: ValueKey(_round),
            options: MapOptions(
              initialCenter: center,
              initialZoom: readMode ? 9 : 6.5,
              minZoom: 5,
              onTap: readMode ? null : (_, point) => setState(() => _pin = LatLng(point.latitude, (point.longitude + 180) % 360 - 180)),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              ...baseLayers(BaseMap.osm, 1),
              if (!photoMode) _grid(task.format, zone),
              MarkerLayer(markers: [
                if (readMode)
                  Marker(
                    point: center,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_pin, size: 44, color: Theme.of(context).colorScheme.error),
                  ),
                if (_pin != null)
                  Marker(
                    point: _pin!,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_pin, size: 44, color: Theme.of(context).colorScheme.primary),
                  ),
              ]),
              ...mapFurniture(BaseMap.osm),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (readMode) ...[
        Text(s['format_${task.format}'], style: text.titleSmall),
        const SizedBox(height: 8),
        ..._answerFrame(task, zone),
      ],
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

  Widget _resultView(_Result r) {
    final text = Theme.of(context).textTheme;
    final task = r.task;
    final target = LatLng(r.targetLat, r.targetLon);
    final yours = LatLng(r.lat, r.lon);
    return _page([
      Text(s.f('result_score', [r.score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(s.f('result_distance', [formatDistance(r.distance)]), style: text.titleMedium),
      if (r.label.isNotEmpty) Text(s.f('result_was', [r.labelFor(widget.lang)]), style: text.titleMedium),
      const SizedBox(height: 12),
      if (task.photo.isNotEmpty) ...[
        TaskPhoto(s: s, file: task.photo, height: 180),
        const SizedBox(height: 12),
      ],
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 260,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: yours == target
                  ? null
                  : CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints([yours, target]),
                      padding: const EdgeInsets.all(48),
                      maxZoom: 13,
                    ),
              initialCenter: target,
              initialZoom: 12,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              ...baseLayers(BaseMap.osm, 1),
              PolylineLayer(polylines: [
                Polyline(points: [yours, target], color: Theme.of(context).colorScheme.error, strokeWidth: 2),
              ]),
              MarkerLayer(markers: [
                Marker(
                  point: yours,
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
              ]),
              ...mapFurniture(BaseMap.osm),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      _coordinates(s['result_yours'], r.lat, r.lon, Icons.location_pin),
      const SizedBox(height: 8),
      _coordinates(s['result_target'], r.targetLat, r.targetLon, Icons.star),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(s[_error!], style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      if (_pending > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(s['done_pending']),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _next,
        icon: const Icon(Icons.arrow_forward),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['next'])),
      ),
    ]);
  }

  /// The same point in every format, with links to other maps.
  Widget _coordinates(String title, double lat, double lon, IconData icon) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Icon(icon, size: 20), const SizedBox(width: 6), Text(title, style: text.titleSmall)]),
            const SizedBox(height: 6),
            SelectableText('DD:  ${formatDd(lat, lon)}\nDM:  ${formatDm(lat, lon)}\nDMS:  ${formatDms(lat, lon)}\nUTM:  ${formatUtm(lat, lon)}'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => launchUrl(googleMapsUrl(lat, lon), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(s['open_google']),
                ),
                TextButton.icon(
                  onPressed: () => launchUrl(osmUrl(lat, lon), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(s['open_osm']),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
            Text(s.f('done_total', [_total, widget.tasks.length * 100]), style: text.titleLarge),
            const SizedBox(height: 4),
            Text(nickname(_participant, widget.lang)),
            if (skipped > 0) ...[
              const SizedBox(height: 12),
              Text(s.f('done_skipped', [skipped]), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _goTo(List.generate(widget.tasks.length, (i) => i).firstWhere((i) => !_answered.contains(i))),
                child: Text(s['done_back']),
              ),
            ],
            if (_pending > 0) ...[
              const SizedBox(height: 12),
              Text(s['done_pending'], textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
