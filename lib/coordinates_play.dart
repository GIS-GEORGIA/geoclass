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
import 'queue.dart';

/// The student's side of the coordinates game: one task at a time, with the result after each.
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
  const _Result(this.task, this.lat, this.lon, this.distance, this.score);
}

class _CoordinatesPlayState extends State<CoordinatesPlay> {
  late final _queue = SubmissionQueue(widget.api.submit);
  final _input = TextEditingController();
  final _map = MapController();
  Timer? _retry;
  bool _loaded = false;
  int _round = 0;
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
    _input.dispose();
    _map.dispose();
    super.dispose();
  }

  // Reopening the link continues where the student stopped.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId();
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      // After the teacher resets the session everyone starts again.
      if (data['resetAt'] == widget.resetAt) {
        _round = data['round'] as int;
        _total = data['total'] as int;
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
  }

  Future<void> _saveProgress() async => (await SharedPreferences.getInstance())
      .setString(_progressKey, jsonEncode({'round': _round, 'total': _total, 'resetAt': widget.resetAt}));

  /// Returns true unless the session stopped accepting answers.
  Future<bool> _send() async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return false;
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
      raw = _input.text.trim();
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
    await _queue.add({
      'token': widget.token,
      'submissionId': randomId(),
      'participantId': _participant,
      'round': _round,
      'answer': {'raw': raw, 'format': task.format, 'mode': task.mode},
      'lat': point.latitude,
      'lon': point.longitude,
    });
    // The result shows only after sending, so a paused session can't reveal the answer.
    final accepted = await _send();
    if (!mounted) return;
    _busy = false;
    if (!accepted) return;

    final distance = distanceM(point.latitude, point.longitude, task.lat, task.lon);
    final score = scoreFor(distance);
    setState(() {
      _result = _Result(task, point!.latitude, point.longitude, distance, score);
      _total += score;
      _round++;
    });
    await _saveProgress();
  }

  void _next() {
    setState(() {
      _result = null;
      _pin = null;
      _input.clear();
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

  Widget _grid(String format, int zone) => format == 'utm' ? UtmGridLayer(zone: zone) : const GraticuleLayer();

  Widget _taskView(CoordTask task) {
    final text = Theme.of(context).textTheme;
    final readMode = task.mode == 'read';
    final zone = utmZone(task.lon);
    final center = readMode ? LatLng(task.lat, task.lon) : const LatLng(42.2, 43.5);
    return _page([
      Text(s.f('play_task', [_round + 1, widget.tasks.length]), style: text.titleMedium),
      LinearProgressIndicator(value: _round / widget.tasks.length),
      const SizedBox(height: 4),
      Text(s.f('play_nick', [nickname(_participant, widget.lang)]), style: text.bodySmall),
      const SizedBox(height: 12),
      Text(s[readMode ? 'play_read' : 'play_to_map'], style: text.titleLarge),
      const SizedBox(height: 8),
      if (!readMode)
        SelectableText(
          formatAs(task.format, task.lat, task.lon),
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
      const SizedBox(height: 4),
      Text(s[readMode ? 'play_read_hint' : 'play_to_map_hint'], style: text.bodyMedium),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 360,
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
              _grid(task.format, zone),
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
        TextField(
          controller: _input,
          decoration: InputDecoration(
            labelText: s['play_input'],
            helperText: s.f('play_example', [_example(task.format, zone)]),
            border: const OutlineInputBorder(),
          ),
          maxLength: 60,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r\t]'))],
          onSubmitted: (_) => _answer(),
        ),
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
    ]);
  }

  String _example(String format, int zone) => switch (format) {
        'dms' => '41°41′38″ N, 44°48′05″ E',
        'utm' => '${zone}N 483482 4615799',
        _ => '41.69380, 44.80150',
      };

  Widget _resultView(_Result r) {
    final text = Theme.of(context).textTheme;
    final task = r.task;
    final target = LatLng(task.lat, task.lon);
    final yours = LatLng(r.lat, r.lon);
    return _page([
      Text(s.f('result_score', [r.score]), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(s.f('result_distance', [formatDistance(r.distance)]), style: text.titleMedium),
      if (task.label.isNotEmpty) Text(s.f('result_was', [task.label]), style: text.titleMedium),
      const SizedBox(height: 12),
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
      _coordinates(s['result_target'], task.lat, task.lon, Icons.star),
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
            SelectableText('DD:  ${formatDd(lat, lon)}\nDMS:  ${formatDms(lat, lon)}\nUTM:  ${formatUtm(lat, lon)}'),
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
