import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'coords.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'mapping.dart';
import 'models.dart';
import 'queue.dart';

const _maxVertices = 100;
const _samePlaceM = 10.0; // the server refuses the same category this close
const _defaultCenter = LatLng(42.2, 43.5);

/// The student's side of the mapping game: draw as many places as you can before the time runs out.
class MappingPlay extends StatefulWidget {
  final S s;
  final String token;
  final Map<String, dynamic> settings;
  final int now; // the server's clock, from the same reply as settings
  final Api api;
  final ValueChanged<String> onStopped; // the session was paused or closed while playing
  const MappingPlay({
    super.key,
    required this.s,
    required this.token,
    required this.settings,
    required this.now,
    required this.api,
    required this.onStopped,
  });
  @override
  State<MappingPlay> createState() => _MappingPlayState();
}

class _MappingPlayState extends State<MappingPlay> {
  late Map<String, dynamic> _settings = widget.settings;
  late int _clockOffset = widget.now - deviceSeconds();
  Timer? _poll, _tick, _retry;
  String _participant = '';
  bool _loaded = false;
  bool _sending = false;

  // Only the student's own objects: nobody can copy from a neighbour's screen.
  final _objects = <MapObject>[];
  final _pending = <String>{}; // ids of objects the server hasn't got yet

  String _kind = 'point';
  String? _category;
  List<LatLng> _draft = const [];
  String? _error;

  S get s => widget.s;
  String get _storeKey => 'mapping_${widget.token}';
  int? get _endsAt => _settings['endsAt'] as int?;
  int get _resetAt => _settings['resetAt'] as int? ?? 0;
  int get _left => (_endsAt ?? 0) - (deviceSeconds() + _clockOffset);
  bool get _running => _endsAt != null && _left > 0;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _retry?.cancel();
    super.dispose();
  }

  // Reopening the link keeps what was drawn, until the teacher clears the session.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId();
    final saved = prefs.getString(_storeKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['resetAt'] == _resetAt) {
        for (final o in (data['objects'] as List).cast<Map<String, dynamic>>()) {
          _objects.add(MapObject(
            id: o['id'] as String,
            participantId: _participant,
            kind: o['kind'] as String,
            category: o['category'] as String,
            points: pointsFromCoords(o['coords'] as List),
          ));
          if (o['pending'] == true) _pending.add(o['id'] as String);
        }
      }
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _send();
    _refresh();
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
        _storeKey,
        jsonEncode({
          'resetAt': _resetAt,
          'objects': [
            for (final o in _objects)
              {'id': o.id, 'kind': o.kind, 'category': o.category, 'coords': o.coords, 'pending': _pending.contains(o.id)},
          ],
        }),
      );

  /// Asks the server whether the clock changed. Quick while waiting, so everyone starts together.
  Future<void> _refresh() async {
    _poll?.cancel();
    try {
      final data = await widget.api.join(widget.token);
      if (!mounted) return;
      final status = data['status'] as String;
      if (status != 'open') {
        widget.onStopped(status);
        return;
      }
      final settings = data['settings'] as Map<String, dynamic>? ?? const {};
      setState(() {
        _clockOffset = (data['now'] as int? ?? deviceSeconds()) - deviceSeconds();
        if ((settings['resetAt'] as int? ?? 0) != _resetAt) {
          _objects.clear();
          _pending.clear();
          _draft = const [];
          _error = null;
        }
        _settings = settings;
      });
      await _save();
    } on ApiError catch (e) {
      if (e.status == 404) {
        widget.onStopped('closed');
        return;
      }
    } on NoConnection {
      // The clock keeps counting on the device.
    }
    if (mounted) {
      _poll = Timer(Duration(seconds: _endsAt == null ? 4 : (_running ? 10 : 15)), _refresh);
    }
  }

  /// Sends in the order drawn. A refused object leaves the map, so the student's count matches the teacher's.
  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    _retry?.cancel();
    var again = false;
    while (mounted && _pending.isNotEmpty && !again) {
      final o = _objects.firstWhere((x) => _pending.contains(x.id));
      try {
        await widget.api.submit({
          'token': widget.token,
          'submissionId': o.id,
          'participantId': _participant,
          'answer': {'kind': o.kind, 'category': o.category, 'coords': o.coords},
          'lat': o.middle.latitude,
          'lon': o.middle.longitude,
        });
        _pending.remove(o.id);
      } on NoConnection {
        again = true;
      } on ApiError catch (e) {
        if (e.status == 429 || e.status >= 500) {
          again = true;
        } else if (e.key == 'session_paused' || e.key == 'session_closed') {
          _sending = false;
          if (mounted) widget.onStopped(e.key.replaceFirst('session_', ''));
          return;
        } else if (mounted) {
          setState(() {
            _objects.remove(o);
            _pending.remove(o.id);
            _error = e.key;
          });
        }
      }
      await _save();
      if (mounted) setState(() {});
    }
    _sending = false;
    if (again && mounted) _retry = Timer(const Duration(seconds: 10), _send);
  }

  void _tapMap(LatLng point) {
    if (!_running) return;
    // The map repeats sideways, so a tap can land outside ±180°.
    final wrapped = LatLng(point.latitude, (point.longitude + 180) % 360 - 180);
    setState(() {
      _error = null;
      if (_kind == 'point') {
        _draft = [wrapped];
      } else if (_draft.length < _maxVertices) {
        _draft = [..._draft, wrapped];
      }
    });
  }

  void _add() {
    final category = _category;
    final needed = switch (_kind) { 'polygon' => 3, 'line' => 2, _ => 1 };
    final String? problem = _draft.length < needed
        ? 'mapping_need_$_kind'
        : category == null
            ? 'mapping_need_category'
            : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final middle = middleOf(_draft);
    final twice = _objects.any((o) =>
        o.category == category && distanceM(middle.latitude, middle.longitude, o.middle.latitude, o.middle.longitude) < _samePlaceM);
    if (twice) {
      setState(() => _error = 'same_place');
      return;
    }
    final object = MapObject(id: randomId(), participantId: _participant, kind: _kind, category: category!, points: _draft);
    setState(() {
      _objects.add(object);
      _pending.add(object.id);
      _draft = const [];
      _error = null;
    });
    _save().then((_) => _send());
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_endsAt == null) return _waiting();
    return Column(
      children: [
        _header(),
        Expanded(child: _map()),
        if (_running) _tools(),
      ],
    );
  }

  Widget _waiting() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_top, size: 56),
              const SizedBox(height: 16),
              Text(s['mapping_wait'], textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(s['mapping_wait_body'], textAlign: TextAlign.center),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      );

  Widget _header() {
    final theme = Theme.of(context);
    final left = _left;
    final hurry = _running && left <= 30;
    return Material(
      color: hurry ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(_running ? Icons.timer : Icons.timer_off),
            const SizedBox(width: 8),
            Text(_running ? formatClock(left) : s['mapping_time_up'], style: theme.textTheme.titleLarge),
            const Spacer(),
            if (_pending.isNotEmpty) ...[
              Tooltip(message: s['mapping_waiting_send'], child: const Icon(Icons.cloud_upload_outlined, size: 20)),
              const SizedBox(width: 8),
            ],
            Text(s.f('mapping_count', [_objects.length]), style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }

  Widget _map() {
    final center = _settings['center'] as List?;
    final draftColor = categoryColor(_category ?? 'other');
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: center == null ? _defaultCenter : LatLng((center[0] as num).toDouble(), (center[1] as num).toDouble()),
            initialZoom: (_settings['zoom'] as num?)?.toDouble() ?? 7,
            minZoom: 2,
            onTap: (_, point) => _tapMap(point),
            // Quick taps are vertices here, so a double tap must not zoom. Zooming is by pinch or wheel.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate & ~InteractiveFlag.doubleTapZoom & ~InteractiveFlag.doubleTapDragZoom,
            ),
          ),
          children: [
            ...baseLayers(BaseMap.osm, 1),
            ...mapObjectLayers(_objects),
            if (_kind == 'polygon' && _draft.length >= 3)
              PolygonLayer(polygons: [
                Polygon(points: _draft, color: draftColor.withValues(alpha: 0.25)),
              ]),
            if (_kind != 'point' && _draft.length >= 2)
              PolylineLayer(polylines: [
                Polyline(points: _draft, color: draftColor, strokeWidth: 3),
              ]),
            CircleLayer(circles: [
              for (final p in _draft)
                CircleMarker(
                  point: p,
                  radius: _kind == 'point' ? 10 : 6,
                  color: draftColor,
                  borderColor: Colors.white,
                  borderStrokeWidth: 2,
                ),
            ]),
            ...mapFurniture(BaseMap.osm),
          ],
        ),
        if (!_running)
          Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  s.f('mapping_final', [_objects.length]),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tools() {
    final theme = Theme.of(context);
    final error = _error;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                // Georgian words are long, and all three must fit a narrow phone.
                style: SegmentedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  textStyle: theme.textTheme.labelMedium,
                ),
                segments: [
                  for (final k in mapKinds)
                    ButtonSegment(value: k, icon: Icon(kindIcon(k)), label: FittedBox(fit: BoxFit.scaleDown, child: Text(s['tool_$k']))),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() {
                  _kind = v.first;
                  _draft = const [];
                  _error = null;
                }),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final c in mapCategories)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(categoryIcon(c), size: 18, color: categoryColor(c)),
                          showCheckmark: false,
                          label: Text(s['cat_$c']),
                          selected: _category == c,
                          onSelected: (_) => setState(() {
                            _category = c;
                            _error = null;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 4),
                Text(s[error], textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: s['mapping_undo'],
                    icon: const Icon(Icons.undo),
                    onPressed: _draft.isEmpty ? null : () => setState(() => _draft = _draft.sublist(0, _draft.length - 1)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.add_location_alt),
                      label: Text(s['mapping_add']),
                      onPressed: _add,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
