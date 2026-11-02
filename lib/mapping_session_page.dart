import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'export.dart';
import 'mapping.dart';
import 'nicknames.dart';
import 'session_base.dart';

/// The mapping game: the clock, everyone's objects on the map, and who drew the most.
class MappingSessionPage extends SessionPageBase {
  const MappingSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<MappingSessionPage> createState() => _MappingSessionPageState();
}

class _MappingSessionPageState extends SessionPageState<MappingSessionPage> {
  List<MapObject> _objects = const [];
  int _minutes = 3;
  bool _showObjects = false;
  String? _student; // the one student picked out on the map
  Timer? _tick;

  List<MapObject> get _shown => _objects.where((o) => !o.hidden).toList();
  int? get _endsAt => session.settings['endsAt'] as int?;
  int get _left => (_endsAt ?? 0) - session.serverNow;
  bool get _running => _endsAt != null && _left > 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  void onRows(List<Map<String, dynamic>> rows) => _objects = [for (final r in rows) MapObject.fromJson(r)];

  @override
  List<LatLng> get fitPoints => [for (final o in _shown) ...o.points];
  @override
  int get answerCount => _objects.length;
  @override
  int get shownCount => _shown.length;
  @override
  String exportCsv() => mapObjectsToCsv(_objects, lang);
  @override
  String exportGeoJson() => mapObjectsToGeoJson(_objects, lang);

  // A neighbourhood game: open close up, where the teacher last was or at the start point.
  @override
  LatLng get initialCenter {
    final center = session.settings['center'] as List?;
    return center == null ? widget.settings.origin : LatLng((center[0] as num).toDouble(), (center[1] as num).toDouble());
  }

  @override
  double get initialZoom => (session.settings['zoom'] as num?)?.toDouble() ?? 13;
  @override
  double get fitMaxZoom => 17;
  @override
  double get singlePointZoom => 15;

  void _start() {
    final camera = mapController.camera;
    run(() => api.setTimer(
          session.id,
          seconds: _minutes * 60,
          center: [camera.center.latitude, (camera.center.longitude + 180) % 360 - 180],
          zoom: camera.zoom,
        ));
  }

  void _addMinute() => run(() => api.setTimer(session.id, seconds: (_left + 60).clamp(60, 3600)));
  void _stop() => run(() => api.setTimer(session.id, seconds: 0));

  @override
  void onMapTap() {
    if (_student != null) setState(() => _student = null);
  }

  @override
  List<Widget> mapLayers() {
    final student = _student;
    return mapObjectLayers(_shown, faded: student == null ? null : (o) => o.participantId != student);
  }

  @override
  List<Widget> mapOverlays() {
    final top = mappingLeaderboard(_objects).take(5).toList();
    return [
      Positioned(top: present ? 8 : 64, left: 8, child: _clock()),
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
                    Text('${i + 1}. ${nickname(r.participantId, lang)}: ${r.answered}', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  // On the map, because where the map is when the clock starts is where students' maps open.
  Widget _clock() {
    final theme = Theme.of(context);
    if (_running) {
      return Card(
        color: _left <= 30 ? theme.colorScheme.errorContainer : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatClock(_left), style: present ? theme.textTheme.displayMedium : theme.textTheme.headlineSmall),
              const SizedBox(width: 8),
              TextButton(onPressed: _addMinute, child: Text(s['mapping_more'])),
              IconButton(tooltip: s['mapping_stop'], icon: const Icon(Icons.stop_circle_outlined), onPressed: _stop),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_endsAt != null) Text(s['mapping_time_up'], textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              Row(
                children: [
                  IconButton(
                    tooltip: s['mapping_less'],
                    icon: const Icon(Icons.remove),
                    onPressed: _minutes > 1 ? () => setState(() => _minutes--) : null,
                  ),
                  Text(s.f('mapping_minutes', [_minutes]), style: theme.textTheme.titleMedium),
                  IconButton(
                    tooltip: s['mapping_more'],
                    icon: const Icon(Icons.add),
                    onPressed: _minutes < 60 ? () => setState(() => _minutes++) : null,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FilledButton(onPressed: _start, child: Text(s['mapping_start'], overflow: TextOverflow.ellipsis)),
                  ),
                ],
              ),
              Text(
                _objects.isEmpty ? s['mapping_map_note'] : s['mapping_kept'],
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget panel() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(s['leaderboard'])),
                ButtonSegment(value: true, label: Text('${s['mapping_objects']} (${_objects.length})')),
              ],
              selected: {_showObjects},
              onSelectionChanged: (v) => setState(() => _showObjects = v.first),
            ),
          ),
          Expanded(child: _showObjects ? _objectList() : _leaderboard()),
        ],
      );

  Widget _leaderboard() {
    final rows = mappingLeaderboard(_objects);
    if (rows.isEmpty) return Center(child: Text(s['no_results']));
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final r = rows[i];
        final own = _shown.where((o) => o.participantId == r.participantId);
        return ListTile(
          selected: _student == r.participantId,
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang)),
          subtitle: Text([
            for (final k in mapKinds) '${s['tool_$k']}: ${own.where((o) => o.kind == k).length}',
          ].join(' · ')),
          trailing: Text('${r.answered}', style: Theme.of(context).textTheme.titleLarge),
          onTap: () => setState(() {
            _student = _student == r.participantId ? null : r.participantId;
            showMapTab();
          }),
        );
      },
    );
  }

  Widget _objectList() {
    if (_objects.isEmpty) return Center(child: Text(s['no_results']));
    final rows = _objects.reversed.toList();
    final muted = Theme.of(context).disabledColor;
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final o = rows[i];
        return ListTile(
          leading: Icon(categoryIcon(o.category), color: o.hidden ? muted : categoryColor(o.category)),
          title: Text(s['cat_${o.category}'], style: o.hidden ? TextStyle(color: muted) : null),
          subtitle: Text(o.hidden ? s['hidden_label'] : '${nickname(o.participantId, lang)} · ${s['tool_${o.kind}']}'),
          onTap: o.hidden
              ? null
              : () {
                  setState(showMapTab);
                  final zoom = mapController.camera.zoom;
                  mapController.move(o.middle, zoom < 15 ? 15 : zoom);
                },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: o.hidden ? s['show'] : s['hide'],
                icon: Icon(o.hidden ? Icons.visibility_off : Icons.visibility),
                onPressed: () => run(() => api.setHidden(o.id, !o.hidden)),
              ),
              IconButton(
                tooltip: s['delete'],
                icon: const Icon(Icons.delete_outline),
                onPressed: () => run(() => api.deleteResponse(o.id)),
              ),
            ],
          ),
        );
      },
    );
  }
}
