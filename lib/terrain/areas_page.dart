import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'profile.dart';
import 'profile_chart.dart';

/// The terrain areas on the map, one at a time, at `#/areas`. Not linked from the app yet: it is where the
/// map for the terrain games can be looked at before any game uses it, with a profile along a line drawn on it.
class AreasPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;
  const AreasPage({super.key, required this.s, this.loader});

  @override
  State<AreasPage> createState() => _AreasPageState();
}

class _AreasPageState extends State<AreasPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  AreaSummary? _area;

  S get s => widget.s;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(s['terrain_areas'])),
    body: FutureBuilder<List<AreaSummary>>(
      future: _catalog,
      builder: (context, snap) {
        if (snap.hasError) {
          final e = snap.error;
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s[e is DemError ? e.key : 'dem_bad_data']),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() {
                    _catalog = _loader.catalog();
                  }),
                  child: Text(s['retry']),
                ),
              ],
            ),
          );
        }
        final areas = snap.data;
        if (areas == null) return const Center(child: CircularProgressIndicator());
        final area = _area ?? (areas.isEmpty ? null : areas.first);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final a in areas)
                    ChoiceChip(
                      label: Text(a.name(s.lang)),
                      selected: a.id == area?.id,
                      onSelected: (_) => setState(() => _area = a),
                    ),
                ],
              ),
            ),
            Expanded(
              child: area == null
                  ? Center(child: Text(s['dem_not_found']))
                  : AreaMap(
                      key: ValueKey('${area.id}/${area.version}'),
                      loader: _loader,
                      id: area.id,
                      version: area.version,
                      s: s,
                      builder: (context, grid) => ProfilePreview(grid: grid, s: s),
                    ),
            ),
          ],
        );
      },
    ),
  );
}

/// The area's map; with "profile" on, touches draw a line and the profile along it shows under the map.
/// Pointing at the chart shows the same place on the map.
class ProfilePreview extends StatefulWidget {
  final ElevationGrid grid;
  final S s;
  const ProfilePreview({super.key, required this.grid, required this.s});

  @override
  State<ProfilePreview> createState() => _ProfilePreviewState();
}

class _ProfilePreviewState extends State<ProfilePreview> {
  static const maxVertices = 10, chartHeight = 160.0, summaryHeight = 64.0;
  bool _drawing = false;
  final _line = <LatLng>[];
  TerrainProfile? _profile;
  ProfileSample? _cursor;

  S get s => widget.s;

  void _changed() {
    _cursor = null;
    _profile = _line.length < 2 ? null : TerrainProfile.along(widget.grid, _line);
  }

  void _tap(LatLng p, double? _) {
    if (!_drawing || _line.length >= maxVertices) return;
    setState(() {
      _line.add(p);
      _changed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = _profile;
    final cursor = _cursor;
    return Column(
      children: [
        Expanded(
          child: MapWorkspace(
            grid: widget.grid,
            s: s,
            showHeight: !_drawing,
            onTap: _tap,
            layers: [
              if (_line.length > 1)
                PolylineLayer(
                  polylines: [Polyline(points: _line, color: scheme.primary, strokeWidth: 3)],
                ),
              CircleLayer(
                circles: [
                  for (final p in _line)
                    CircleMarker(point: p, radius: 5, color: Colors.white, borderColor: scheme.primary, borderStrokeWidth: 2),
                  if (profile != null && cursor != null)
                    CircleMarker(
                      point: profile.positionOf(cursor),
                      radius: 7,
                      color: scheme.error,
                      borderColor: Colors.white,
                      borderStrokeWidth: 2,
                    ),
                ],
              ),
            ],
          ),
        ),
        Material(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    FilterChip(
                      label: Text(s['profile_draw']),
                      selected: _drawing,
                      onSelected: (on) => setState(() => _drawing = on),
                    ),
                    const SizedBox(width: 8),
                    if (_drawing && _line.length < 2)
                      Expanded(child: Text(s['profile_draw_hint'], style: Theme.of(context).textTheme.bodySmall))
                    else
                      const Spacer(),
                    if (_line.isNotEmpty) ...[
                      IconButton(
                        tooltip: s['profile_undo'],
                        icon: const Icon(Icons.undo),
                        onPressed: () => setState(() {
                          _line.removeLast();
                          _changed();
                        }),
                      ),
                      IconButton(
                        tooltip: s['profile_clear'],
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() {
                          _line.clear();
                          _changed();
                        }),
                      ),
                    ],
                  ],
                ),
                // The room for the chart is kept from the moment drawing starts, so the map does not change size
                // (and move) under the next touch.
                if (_drawing || profile != null)
                  SizedBox(
                    height: chartHeight + summaryHeight,
                    child: profile == null
                        ? const SizedBox.expand()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ProfileChart(
                                profile: profile,
                                s: s,
                                cursor: cursor,
                                height: chartHeight,
                                onCursor: (c) => setState(() => _cursor = c),
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: ProfileSummary(profile: profile, s: s, cursor: cursor),
                                ),
                              ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
