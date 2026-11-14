import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'least_cost.dart';
import 'least_cost_game.dart';
import 'viewshed_game.dart' show GridCell;

/// One student's answer, as the teacher's list of responses gives it: the route's corners between A and B.
class RouteAnswer {
  final String participantId;
  final List<GridCell> via;
  final int score, createdAt;
  const RouteAnswer(this.participantId, this.via, this.score, this.createdAt);

  factory RouteAnswer.fromJson(Map<String, dynamic> j) => RouteAnswer(
    j['participantId'] as String,
    [
      for (final p in (j['answer'] as Map<String, dynamic>)['via'] as List)
        GridCell((p as List)[0] as int, p[1] as int),
    ],
    (j['score'] as num?)?.toInt() ?? 0,
    (j['createdAt'] as num?)?.toInt() ?? 0,
  );

  List<int> cells(ElevationGrid g, LeastCostGameSettings s) => routeThrough([
    for (final c in [s.start, ...via, s.end]) cellIndex(g, c),
  ], g.width);
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: who, the corners, the route's cost, length and climb, and the score.
String routeAnswersToCsv(CostSurface surface, LeastCostGameSettings settings, List<RouteAnswer> answers, String lang) {
  final g = surface.grid;
  final unit = settings.model.isSlope ? 'cost_m' : 'cost_min';
  final out = StringBuffer('﻿nickname,corners,$unit,length_km,climb_m,score,created_at\r\n');
  for (final a in answers) {
    final cells = a.cells(g, settings);
    final st = routeStats(surface, cells);
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        a.via.length,
        routeCost(surface, cells)?.toStringAsFixed(1) ?? '',
        (st.length / 1000).toStringAsFixed(2),
        st.climb.round(),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// A and B, the best route, and each student's route with its score, as lines through the cells' centres.
String routesToGeoJson(ElevationGrid g, LeastCostGameSettings settings, List<RouteAnswer> answers, String lang) {
  List<double> lonLat(LatLng p) => [p.longitude, p.latitude];
  List<List<double>> line(List<int> cells) => [for (final i in cells) lonLat(cellAt(g, i).centre(g))];
  final steps = settings.steps;
  return jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (final (label, c) in [('A', settings.start), ('B', settings.end)])
        {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': lonLat(c.centre(g))},
          'properties': {'point': label},
        },
      if (steps != null)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': line(cellsOf(cellIndex(g, settings.start), steps, g.width)),
          },
          'properties': {'best': true, 'cost': settings.best, 'model': settings.model.toJson()},
        },
      for (final a in answers)
        {
          'type': 'Feature',
          'geometry': {'type': 'LineString', 'coordinates': line(a.cells(g, settings))},
          'properties': {'nickname': nickname(a.participantId, lang), 'score': a.score},
        },
    ],
  });
}

/// The teacher's page for a least-cost session: A and B, every student's route coloured by its score, on
/// request the best route, and the leaderboard.
class LeastCostSessionPage extends SessionPageBase {
  final DemLoader? loader;
  const LeastCostSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.loader,
  });
  @override
  State<LeastCostSessionPage> createState() => _LeastCostSessionPageState();
}

class _LeastCostSessionPageState extends SessionPageState<LeastCostSessionPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  final _costs = CostCache();
  List<RouteAnswer> _answers = const [];
  ElevationGrid? _grid;
  bool _reveal = false;

  LeastCostGameSettings? get _settings {
    try {
      return LeastCostGameSettings.fromJson(session.settings);
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
    }
  }

  @override
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) RouteAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    return [settings.start.centre(g), settings.end.centre(g)];
  }

  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '';
    return routeAnswersToCsv(_costs.of(g, settings.model), settings, _answers, lang);
  }

  @override
  String exportGeoJson() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '{"type":"FeatureCollection","features":[]}';
    return routesToGeoJson(g, settings, _answers, lang);
  }

  @override
  List<Widget> mapLayers() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final steps = settings.steps;
    return [
      for (final a in _answers) routeLayer(g, a.cells(g, settings), scoreColor(a.score), width: 3),
      if (_reveal && steps != null)
        routeLayer(g, cellsOf(cellIndex(g, settings.start), steps, g.width), routeBestColour, width: 5),
      endsLayer(g, settings.start, settings.end, Theme.of(context).colorScheme),
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
                Flexible(child: Text(s['route_question'], style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  key: const Key('route_reveal'),
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
    final surface = g == null ? null : _costs.of(g, settings.model);
    final best = settings.best;
    return ListView(
      children: [
        ListTile(title: Text(s.f('slope_average', [average, rows.length]))),
        if (best != null)
          ListTile(dense: true, title: Text(s.f('route_best_cost', [costText(s, settings.model, best)]))),
        const Divider(),
        for (final (i, a) in rows.indexed)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scoreColor(a.score),
              foregroundColor: Colors.white,
              child: Text('${i + 1}'),
            ),
            title: Text(nickname(a.participantId, lang)),
            subtitle: surface == null
                ? null
                : Text(switch (routeCost(surface, a.cells(g!, settings))) {
                    final c? => costText(s, settings.model, c),
                    null => '',
                  }),
            trailing: Text(s.f('points', [a.score]), style: Theme.of(context).textTheme.titleSmall),
          ),
      ],
    );
  }
}
