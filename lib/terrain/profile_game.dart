import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart';
import 'profile.dart';
import 'profile_chart.dart';

/// The question kinds of the terrain profile game, in the order the teacher sees them.
/// worker/src/games/profile.ts has the same list and scores the answers.
const profileKinds = ['max', 'min', 'length', 'steepest', 'where_max'];

/// One question as the student gets it: its kind, and for heights how close counts as right.
class ProfileQuestion {
  final String kind;
  final double? tolerance;

  /// The right answer: only on the teacher's side, and in the server's reply after answering.
  final double? answer;

  const ProfileQuestion(this.kind, {this.tolerance, this.answer});

  factory ProfileQuestion.fromJson(Map<String, dynamic> j) => ProfileQuestion(
    j['kind'] as String,
    tolerance: (j['tolerance'] as num?)?.toDouble(),
    answer: (j['answer'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {'kind': kind, 'answer': ?answer, 'tolerance': ?tolerance};

  String title(S s) => s['profile_q_$kind'];
}

/// The session's settings: which area, the line on it, and the questions.
class ProfileGameSettings {
  final String areaId;
  final int areaVersion;
  final List<LatLng> line;
  final double? length;
  final List<ProfileQuestion> questions;

  const ProfileGameSettings(this.areaId, this.areaVersion, this.line, this.questions, {this.length});

  /// Reads the settings join or the teacher's session list gives. Throws [FormatException] if they don't fit.
  factory ProfileGameSettings.fromJson(Map<String, dynamic> j) {
    try {
      final area = j['area'] as Map<String, dynamic>;
      return ProfileGameSettings(
        area['id'] as String,
        area['version'] as int,
        [for (final p in j['line'] as List) LatLng(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
        [for (final q in j['questions'] as List) ProfileQuestion.fromJson(q as Map<String, dynamic>)],
        length: (j['length'] as num?)?.toDouble(),
      );
    } on TypeError {
      throw const FormatException('bad profile settings');
    }
  }

  Map<String, dynamic> toJson() => {
    'area': {'id': areaId, 'version': areaVersion},
    'line': [
      for (final p in line) [p.latitude, p.longitude],
    ],
    'length': ?length,
    'questions': [for (final q in questions) q.toJson()],
  };
}

/// The right answer to a question about [p], as the server is told it: heights to 0.1 m, length and the top's
/// place in metres, the steepest section by its index. Null when the profile can't answer it.
double? profileAnswer(TerrainProfile p, String kind) => switch (kind) {
  'max' => p.highest == null ? null : (p.highest!.height! * 10).round() / 10,
  'min' => p.lowest == null ? null : (p.lowest!.height! * 10).round() / 10,
  'length' => (p.length * 100).round() / 100,
  'steepest' => p.sections.length < 2 ? null : p.steepest?.index.toDouble(),
  'where_max' => p.highest == null ? null : (p.highest!.distance * 100).round() / 100,
  _ => null,
};

/// An answer value as the student and teacher read it: metres, kilometres, or a section's number.
String profileValue(String kind, double value, S s) => switch (kind) {
  'max' || 'min' => s.f('profile_m', [value.round()]),
  'length' || 'where_max' => profileDistance(value, s),
  'steepest' => s.f('profile_section', [value.round() + 1]),
  _ => '$value',
};

/// The line on the map: the line itself, its vertices, and each section's number half way along it.
List<Widget> profileLineLayers(List<LatLng> line, ColorScheme scheme, {LatLng? cursor, bool numbers = true}) => [
  if (line.length > 1)
    PolylineLayer(
      polylines: [Polyline(points: line, color: scheme.primary, strokeWidth: 3)],
    ),
  CircleLayer(
    circles: [
      for (final p in line)
        CircleMarker(point: p, radius: 5, color: Colors.white, borderColor: scheme.primary, borderStrokeWidth: 2),
      if (cursor != null)
        CircleMarker(point: cursor, radius: 7, color: scheme.error, borderColor: Colors.white, borderStrokeWidth: 2),
    ],
  ),
  if (numbers && line.length > 2)
    MarkerLayer(
      markers: [
        for (var k = 0; k + 1 < line.length; k++)
          Marker(
            point: LatLng(
              (line[k].latitude + line[k + 1].latitude) / 2,
              (line[k].longitude + line[k + 1].longitude) / 2,
            ),
            width: 24,
            height: 24,
            child: CircleAvatar(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              child: Text('${k + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    ),
];

/// The teacher's setup: pick an area, draw the line, pick the questions. Returns the settings to send with the
/// new session, the right answers worked out from the area's grid.
class ProfileSetupPage extends StatefulWidget {
  final S s;
  final DemLoader? loader;
  const ProfileSetupPage({super.key, required this.s, this.loader});

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  late Future<List<AreaSummary>> _catalog = _loader.catalog();
  AreaSummary? _area;
  ElevationGrid? _grid;
  final _line = <LatLng>[];
  TerrainProfile? _profile;
  ProfileSample? _cursor;
  final _kinds = <String>{'max', 'min', 'length', 'steepest', 'where_max'};
  final _tolerance = TextEditingController(text: '50');
  String? _error;

  static const maxVertices = 10;
  S get s => widget.s;

  @override
  void dispose() {
    _tolerance.dispose();
    super.dispose();
  }

  void _changed() {
    _cursor = null;
    _error = null;
    _profile = _line.length < 2 || _grid == null ? null : TerrainProfile.along(_grid!, _line);
  }

  void _tap(LatLng p, double? height) {
    if (_line.length >= maxVertices) return;
    if (height == null) {
      setState(() => _error = 'profile_need_inside');
      return;
    }
    setState(() {
      _line.add(p);
      _changed();
    });
  }

  /// Why the session can't be made yet, or null.
  String? _problem() {
    final p = _profile;
    if (p == null) return 'profile_need_line';
    if (p.samples.any((x) => x.height == null)) return 'profile_need_inside';
    final kinds = _kinds.where((k) => k != 'steepest' || p.sections.length > 1);
    if (kinds.isEmpty) return 'profile_need_question';
    final t = double.tryParse(_tolerance.text.replaceAll(',', '.'));
    if ((_kinds.contains('max') || _kinds.contains('min')) && (t == null || t < 5 || t > 1000)) {
      return 'profile_bad_tolerance';
    }
    return null;
  }

  void _create() {
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final p = _profile!;
    final t = double.tryParse(_tolerance.text.replaceAll(',', '.'));
    final questions = [
      for (final k in profileKinds)
        if (_kinds.contains(k) && profileAnswer(p, k) != null)
          ProfileQuestion(k, answer: profileAnswer(p, k), tolerance: k == 'max' || k == 'min' ? t : null),
    ];
    final settings = ProfileGameSettings(
      _area!.id,
      _area!.version,
      List.of(_line),
      questions,
      length: profileAnswer(p, 'length'),
    );
    Navigator.of(context).pop({'profile': settings.toJson()});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(s['game_profile']),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(onPressed: _profile == null ? null : _create, child: Text(s['create'])),
        ),
      ],
    ),
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
        final area = _area ??= areas.isEmpty ? null : areas.first;
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
                      onSelected: (_) => setState(() {
                        _area = a;
                        _grid = null;
                        _line.clear();
                        _changed();
                      }),
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
                      builder: (context, grid) {
                        if (!identical(_grid, grid)) {
                          _grid = grid;
                          _changed();
                        }
                        return _workspace(grid);
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );

  Widget _workspace(ElevationGrid grid) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final p = _profile;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 900;
        final map = MapWorkspace(
          grid: grid,
          s: s,
          showHeight: false,
          onTap: _tap,
          layers: profileLineLayers(
            _line,
            scheme,
            cursor: p == null || _cursor == null ? null : p.positionOf(_cursor!),
          ),
        );
        final side = ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(
              children: [
                Expanded(child: Text(s['profile_setup_hint'], style: text.bodyMedium)),
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
            if (p != null) ...[
              ProfileChart(
                profile: p,
                s: s,
                cursor: _cursor,
                height: 160,
                onCursor: (c) => setState(() => _cursor = c),
              ),
              const SizedBox(height: 4),
              ProfileSummary(profile: p, s: s, cursor: _cursor),
            ],
            const SizedBox(height: 12),
            Text(s['profile_questions'], style: text.titleSmall),
            for (final k in profileKinds)
              CheckboxListTile(
                key: Key('profile_kind_$k'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _kinds.contains(k) && (k != 'steepest' || (p?.sections.length ?? 0) > 1),
                onChanged: k == 'steepest' && (p?.sections.length ?? 0) < 2
                    ? null
                    : (on) => setState(() => on == true ? _kinds.add(k) : _kinds.remove(k)),
                title: Text(s['profile_q_$k']),
                subtitle: switch (k) {
                  'steepest' when (p?.sections.length ?? 0) < 2 => Text(s['profile_steepest_needs']),
                  _ when p != null && profileAnswer(p, k) != null => Text(
                    s.f('profile_right', [profileValue(k, profileAnswer(p, k)!, s)]),
                  ),
                  _ => null,
                },
              ),
            if (_kinds.contains('max') || _kinds.contains('min'))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  key: const Key('profile_tolerance'),
                  controller: _tolerance,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: s['profile_tolerance'],
                    suffixText: s.f('profile_m', ['']).trim(),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Text(s['profile_scoring'], style: text.bodySmall),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(s[_error!], style: TextStyle(color: scheme.error)),
              ),
          ],
        );
        if (wide) {
          return Row(
            children: [
              Expanded(child: map),
              SizedBox(width: 420, child: side),
            ],
          );
        }
        return Column(
          children: [
            Expanded(flex: 3, child: map),
            Expanded(flex: 4, child: side),
          ],
        );
      },
    );
  }
}
