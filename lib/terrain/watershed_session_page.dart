import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'watershed.dart';
import 'watershed_game.dart';

/// One student's answer, as the teacher's list of responses gives it: the polygon drawn, in grid units.
class WatershedAnswer {
  final String participantId;
  final List<GridPoint> poly;
  final int score, createdAt;
  const WatershedAnswer(this.participantId, this.poly, this.score, this.createdAt);

  factory WatershedAnswer.fromJson(Map<String, dynamic> j) => WatershedAnswer(
    j['participantId'] as String,
    polyFromJson((j['answer'] as Map<String, dynamic>)['poly'] as List),
    (j['score'] as num?)?.toInt() ?? 0,
    (j['createdAt'] as num?)?.toInt() ?? 0,
  );
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: who, the area and perimeter drawn, the score.
String watershedAnswersToCsv(ElevationGrid g, List<WatershedAnswer> answers, String lang) {
  final out = StringBuffer('﻿nickname,vertices,area_km2,perimeter_km,score,created_at\r\n');
  for (final a in answers) {
    final pts = [for (final p in a.poly) latLngOf(g, p)];
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        a.poly.length,
        (geodesicArea(pts) / 1e6).toStringAsFixed(3),
        (geodesicPerimeter(pts) / 1000).toStringAsFixed(2),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// The outlet, the basin (its cells, row runs as rectangles: dissolve them in QGIS for one outline), and
/// each student's polygon with its score.
String watershedToGeoJson(ElevationGrid g, WatershedGameSettings settings, List<WatershedAnswer> answers, String lang) {
  List<double> lonLat(LatLng p) => [p.longitude, p.latitude];
  List<List<double>> ring(List<GridPoint> poly) => [
    for (final p in [...poly, poly.first]) lonLat(latLngOf(g, p)),
  ];
  final runs = settings.runs;
  return jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': lonLat(settings.outlet.centre(g))},
        'properties': {'outlet': true},
      },
      if (runs != null)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'MultiPolygon',
            'coordinates': [
              for (final r in runs)
                [
                  ring([
                    (row: r[0].toDouble(), col: r[1].toDouble()),
                    (row: r[0].toDouble(), col: r[2].toDouble()),
                    (row: r[0] + 1.0, col: r[2].toDouble()),
                    (row: r[0] + 1.0, col: r[1].toDouble()),
                  ]),
                ],
            ],
          },
          'properties': {'basin': true, 'area_km2': cellsArea(g, runCells(runs), settings.outlet.centre(g)) / 1e6},
        },
      for (final a in answers)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [ring(a.poly)],
          },
          'properties': {'nickname': nickname(a.participantId, lang), 'score': a.score},
        },
    ],
  });
}

/// The teacher's page for a watershed session: the outlet and the streams, every student's polygon coloured
/// by its score, on request the basin, and the leaderboard.
class WatershedSessionPage extends SessionPageBase {
  final DemLoader? loader;
  const WatershedSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.loader,
  });
  @override
  State<WatershedSessionPage> createState() => _WatershedSessionPageState();
}

class _WatershedSessionPageState extends SessionPageState<WatershedSessionPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  final _cache = WatershedCache();
  List<WatershedAnswer> _answers = const [];
  ElevationGrid? _grid;
  FlowGrid? _flow;
  bool _reveal = false;

  WatershedGameSettings? get _settings {
    try {
      return WatershedGameSettings.fromJson(session.settings);
    } on FormatException {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final settings = _settings;
    if (settings != null) {
      _loader.load(settings.areaId, settings.areaVersion).then((g) {
        if (!mounted) return;
        setState(() => _grid = g);
        fitAll();
      }, onError: (_) {});
      _loader.loadFlow(settings.areaId, settings.areaVersion).then((f) {
        if (mounted) setState(() => _flow = f);
      }, onError: (_) {});
    }
  }

  @override
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) WatershedAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final runs = settings.runs;
    if (runs == null || runs.isEmpty) return [settings.outlet.centre(g)];
    var c0 = runs.first[1], c1 = runs.first[2];
    for (final r in runs) {
      if (r[1] < c0) c0 = r[1];
      if (r[2] > c1) c1 = r[2];
    }
    final r0 = runs.first[0].toDouble(), r1 = runs.last[0] + 1.0;
    return [latLngOf(g, (row: r0, col: c0.toDouble())), latLngOf(g, (row: r1, col: c1.toDouble()))];
  }

  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() {
    final g = _grid;
    return g == null ? '' : watershedAnswersToCsv(g, _answers, lang);
  }

  @override
  String exportGeoJson() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '{"type":"FeatureCollection","features":[]}';
    return watershedToGeoJson(g, settings, _answers, lang);
  }

  @override
  List<Widget> mapLayers() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    final f = _flow;
    final runs = settings.runs;
    return [
      if (_reveal && runs != null) basinLayer(g, 'session', runsMask(runs, g.width, g.height)),
      if (f != null) streamsLayer(g, f, _cache.accOf(f)),
      for (final a in _answers) ...drawnLayers(g, a.poly, scoreColor(a.score)),
      outletLayer(g, settings.outlet, scheme),
    ];
  }

  @override
  List<Widget> mapOverlays() => [
    Positioned(
      top: present ? 8 : 64,
      left: 8,
      right: 64,
      child: Align(
        alignment: Alignment.topLeft,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(s['shed_question'], style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  key: const Key('shed_reveal'),
                  tooltip: s[_reveal ? 'answer_hide' : 'answer_show'],
                  icon: Icon(_reveal ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _reveal = !_reveal),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ];

  @override
  Widget panel() {
    final settings = _settings, g = _grid;
    if (_answers.isEmpty || settings == null) return Center(child: Text(s['no_results']));
    final rows = [..._answers]..sort((a, b) => b.score.compareTo(a.score));
    final average = (rows.map((a) => a.score).reduce((a, b) => a + b) / rows.length).round();
    final runs = settings.runs;
    return ListView(
      children: [
        ListTile(title: Text(s.f('slope_average', [average, rows.length]))),
        if (g != null && runs != null)
          ListTile(
            dense: true,
            title: Text(s.f('shed_basin_area', [km2(cellsArea(g, runCells(runs), settings.outlet.centre(g)))])),
          ),
        const Divider(),
        for (final (i, a) in rows.indexed)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scoreColor(a.score),
              foregroundColor: Colors.white,
              child: Text('${i + 1}'),
            ),
            title: Text(nickname(a.participantId, lang)),
            subtitle: g == null
                ? null
                : Text(
                    s.f('shed_area', [
                      km2(geodesicArea([for (final p in a.poly) latLngOf(g, p)])),
                    ]),
                  ),
            trailing: Text(s.f('points', [a.score]), style: Theme.of(context).textTheme.titleSmall),
          ),
      ],
    );
  }
}
