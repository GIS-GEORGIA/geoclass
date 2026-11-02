import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'coords.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'models.dart';
import 'places.dart';

const _modes = ['to_map', 'read'];
const _formats = ['dd', 'dms', 'utm'];

/// Picks random Georgian places as tasks. Places with a Georgian name are the well-known ones.
List<CoordTask> randomTasks(PlaceIndex index, int count, String mode, String format, {Random? random}) {
  final r = random ?? Random();
  final pool = index.places.where((p) => p.country == 'GE' && p.ka.isNotEmpty).toList()..shuffle(r);
  return [
    for (final (i, p) in pool.take(count).indexed)
      CoordTask(
        lat: p.lat,
        lon: p.lon,
        mode: mode == 'mix' ? _modes[i % _modes.length] : mode,
        format: format == 'mix' ? _formats[i % _formats.length] : format,
        label: p.ka,
      ),
  ];
}

/// The teacher's list of tasks. Returns it when done.
class CoordinatesSetupPage extends StatefulWidget {
  final S s;
  const CoordinatesSetupPage({super.key, required this.s});
  @override
  State<CoordinatesSetupPage> createState() => _CoordinatesSetupPageState();
}

class _CoordinatesSetupPageState extends State<CoordinatesSetupPage> {
  final _coordCtl = TextEditingController();
  final _scroll = ScrollController();
  PlaceIndex? _index;
  String _mode = 'mix';
  String _format = 'mix';
  int _count = 5;
  List<CoordTask> _tasks = [];
  String? _coordError;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    PlaceIndex.load().then((index) {
      if (!mounted) return;
      _index = index;
      _generate();
    });
  }

  @override
  void dispose() {
    _coordCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _generate() {
    final index = _index;
    if (index != null) setState(() => _tasks = randomTasks(index, _count, _mode, _format));
  }

  String _next(String choice, List<String> values) =>
      choice == 'mix' ? values[_tasks.length % values.length] : choice;

  void _add(LatLng point) {
    if (_tasks.length >= 30) return;
    setState(() {
      _tasks = [
        ..._tasks,
        CoordTask(
          lat: point.latitude,
          lon: (point.longitude + 180) % 360 - 180,
          mode: _next(_mode, _modes),
          format: _next(_format, _formats),
        ),
      ];
      _coordError = null;
    });
  }

  void _addTyped() {
    final point = parseAny(_coordCtl.text);
    if (point == null) {
      setState(() => _coordError = s['setup_bad_coord']);
      return;
    }
    _coordCtl.clear();
    _add(point);
  }

  Widget _choice(String label, String value, List<(String, String)> items, ValueChanged<String> onChanged) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        items: [
          for (final (v, text) in items)
            DropdownMenuItem(value: v, child: Text(text, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => onChanged(v!),
      );

  @override
  Widget build(BuildContext context) {
    final points = [for (final t in _tasks) LatLng(t.lat, t.lon)];
    return Scaffold(
      appBar: AppBar(
        title: Text(s['setup_title']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _tasks.isEmpty ? null : () => Navigator.pop(context, _tasks),
              child: Text(s['create']),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            children: [
              _choice(s['setup_mode'], _mode, [
                ('mix', s['mode_mix']),
                ('to_map', s['mode_to_map']),
                ('read', s['mode_read']),
              ], (v) {
                _mode = v;
                _generate();
              }),
              const SizedBox(height: 12),
              _choice(s['setup_format'], _format, [
                ('mix', s['format_mix']),
                ('dd', s['format_dd']),
                ('dms', s['format_dms']),
                ('utm', s['format_utm']),
              ], (v) {
                _format = v;
                _generate();
              }),
              const SizedBox(height: 8),
              Text(s.f('setup_count', [_count])),
              Slider(
                value: _count.toDouble(),
                min: 1,
                max: 20,
                divisions: 19,
                label: '$_count',
                onChanged: (v) => setState(() => _count = v.round()),
                onChangeEnd: (_) => _generate(),
              ),
              OutlinedButton.icon(
                onPressed: _index == null ? null : _generate,
                icon: const Icon(Icons.casino),
                label: Text(s['setup_random']),
              ),
              const SizedBox(height: 16),
              Text(s['setup_hint']),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 300,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: const LatLng(42.2, 43.5),
                      initialZoom: 6.5,
                      minZoom: 2,
                      onTap: (_, point) => _add(point),
                      interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    ),
                    children: [
                      ...baseLayers(BaseMap.osm, 1),
                      MarkerLayer(markers: [
                        for (final (i, p) in points.indexed)
                          Marker(
                            point: p,
                            width: 26,
                            height: 26,
                            child: CircleAvatar(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onPrimary),
                              ),
                            ),
                          ),
                      ]),
                      ...mapFurniture(BaseMap.osm),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _coordCtl,
                decoration: InputDecoration(
                  labelText: s['setup_add_label'],
                  hintText: '41.69380, 44.80150',
                  errorText: _coordError,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(tooltip: s['setup_add'], icon: const Icon(Icons.add), onPressed: _addTyped),
                ),
                onSubmitted: (_) => _addTyped(),
              ),
              const SizedBox(height: 12),
              if (_tasks.isEmpty) Text(s['setup_empty']),
              for (final (i, t) in _tasks.indexed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(t.label.isEmpty ? formatAs(t.format, t.lat, t.lon) : t.label),
                  subtitle: Text('${s['mode_${t.mode}']} · ${t.format.toUpperCase()}'),
                  trailing: IconButton(
                    tooltip: s['delete'],
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _tasks = [..._tasks]..removeAt(i)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
