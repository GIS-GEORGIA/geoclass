import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'map_workspace.dart' show GridImage, gridOverlay;
import 'viewshed_game.dart' show GridCell;
import 'watershed.dart';
import 'watershed_game.dart';
import 'watershed_session_page.dart' show WatershedAnswer, watershedToGeoJson;

/// One student's level-2 answer: the pour point, the stream threshold they chose, and the basin they drew by
/// hand, if any.
class HydroAnswer {
  final String participantId;
  final GridCell pour;
  final int threshold, score, createdAt;
  final List<GridPoint> poly;
  const HydroAnswer(this.participantId, this.pour, this.threshold, this.poly, this.score, this.createdAt);

  factory HydroAnswer.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return HydroAnswer(
      j['participantId'] as String,
      GridCell.fromJson(a['pour'] as Map<String, dynamic>),
      (a['threshold'] as num).toInt(),
      a['poly'] == null ? const [] : polyFromJson(a['poly'] as List),
      (j['score'] as num?)?.toInt() ?? 0,
      (j['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: the pour point, the threshold, the pour point's basin, the drawn basin, the score.
String hydroAnswersToCsv(ElevationGrid g, FlowGrid f, List<HydroAnswer> answers, String lang) {
  final out = StringBuffer(
    '﻿nickname,pour_row,pour_col,pour_lon,pour_lat,threshold_cells,pour_basin_km2,drawn_km2,score,created_at\r\n',
  );
  for (final a in answers) {
    final at = a.pour.centre(g);
    final cells = runCells(maskRuns(basinMask(f, a.pour.row, a.pour.col), f.width));
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        a.pour.row,
        a.pour.col,
        at.longitude.toStringAsFixed(6),
        at.latitude.toStringAsFixed(6),
        a.threshold,
        (cellsArea(g, cells, at) / 1e6).toStringAsFixed(3),
        a.poly.length < 3 ? '' : (geodesicArea([for (final p in a.poly) latLngOf(g, p)]) / 1e6).toStringAsFixed(3),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// Level 1's file (the outlet, the basin, the drawn polygons) and each student's pour point.
String hydroToGeoJson(ElevationGrid g, WatershedGameSettings settings, List<HydroAnswer> answers, String lang) {
  final base =
      jsonDecode(
            watershedToGeoJson(g, settings, [
              for (final a in answers)
                if (a.poly.length >= 3) WatershedAnswer(a.participantId, a.poly, a.score, a.createdAt),
            ], lang),
          )
          as Map<String, dynamic>;
  final at = [for (final a in answers) a.pour.centre(g)];
  (base['features'] as List).addAll([
    for (final (i, a) in answers.indexed)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [at[i].longitude, at[i].latitude],
        },
        'properties': {
          'pour_point': true,
          'nickname': nickname(a.participantId, lang),
          'threshold_cells': a.threshold,
          'score': a.score,
        },
      },
  ]);
  return jsonEncode(base);
}

/// The teacher's page for a level-2 session: the outlet, every student's pour point coloured by its score,
/// the chosen student's basin, and on request the outlet's.
class HydroSessionPage extends SessionPageBase {
  final DemLoader? loader;
  const HydroSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen, this.loader});
  @override
  State<HydroSessionPage> createState() => _HydroSessionPageState();
}

class _HydroSessionPageState extends SessionPageState<HydroSessionPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  final _cache = WatershedCache();
  List<HydroAnswer> _answers = const [];
  ElevationGrid? _grid;
  FlowGrid? _flow;
  bool _reveal = false;
  String? _chosen;

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
  void onRows(List<Map<String, dynamic>> rows) {
    final out = <HydroAnswer>[];
    for (final r in rows) {
      try {
        out.add(HydroAnswer.fromJson(r));
      } on Object {
        // An answer this app can't read is left out.
      }
    }
    _answers = out..sort((a, b) => b.score.compareTo(a.score));
  }

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
    return [
      latLngOf(g, (row: runs.first[0].toDouble(), col: c0.toDouble())),
      latLngOf(g, (row: runs.last[0] + 1.0, col: c1.toDouble())),
    ];
  }

  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() {
    final g = _grid, f = _flow;
    return g == null || f == null ? '' : hydroAnswersToCsv(g, f, _answers, lang);
  }

  @override
  String exportGeoJson() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '{"type":"FeatureCollection","features":[]}';
    return hydroToGeoJson(g, settings, _answers, lang);
  }

  HydroAnswer? get _chosenAnswer {
    for (final a in _answers) {
      if (a.participantId == _chosen) return a;
    }
    return null;
  }

  @override
  List<Widget> mapLayers() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    final f = _flow;
    final runs = settings.runs;
    final chosen = _chosenAnswer;
    return [
      if (_reveal && runs != null) basinLayer(g, 'session', runsMask(runs, g.width, g.height)),
      if (f != null && chosen != null)
        gridOverlay(
          g.outline,
          GridImage(
            g,
            'pour/${chosen.pour.row}/${chosen.pour.col}',
            () => maskPixels(_cache.basinOf(f, chosen.pour), colour: 0xffef6c00),
          ),
          opacity: 0.4,
        ),
      if (f != null) streamsLayer(g, f, _cache.accOf(f)),
      if (chosen != null && chosen.poly.length >= 3) ...drawnLayers(g, chosen.poly, scheme.tertiary),
      outletLayer(g, settings.outlet, scheme),
      MarkerLayer(
        markers: [
          for (final a in _answers)
            Marker(
              point: a.pour.centre(g),
              width: 18,
              height: 18,
              child: Container(
                decoration: BoxDecoration(
                  color: scoreColor(a.score),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: a.participantId == _chosen ? 3 : 1.5),
                ),
              ),
            ),
        ],
      ),
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
                Flexible(child: Text(s['hydro_question'], style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  key: const Key('hydro_reveal'),
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
    final settings = _settings, g = _grid, f = _flow;
    if (_answers.isEmpty || settings == null) return Center(child: Text(s['no_results']));
    final average = (_answers.map((a) => a.score).reduce((a, b) => a + b) / _answers.length).round();
    final runs = settings.runs;
    return ListView(
      children: [
        ListTile(title: Text(s.f('slope_average', [average, _answers.length]))),
        if (g != null && runs != null)
          ListTile(
            dense: true,
            title: Text(s.f('hydro_outlet_basin', [km2(cellsArea(g, runCells(runs), settings.outlet.centre(g)))])),
          ),
        const Divider(),
        for (final (i, a) in _answers.indexed)
          ListTile(
            key: Key('hydro_answer_$i'),
            selected: a.participantId == _chosen,
            leading: CircleAvatar(
              backgroundColor: scoreColor(a.score),
              foregroundColor: Colors.white,
              child: Text('${i + 1}'),
            ),
            title: Text(nickname(a.participantId, lang)),
            subtitle: g == null || f == null
                ? null
                : Text(
                    s.f('hydro_row', [
                      km2(cellsArea(g, runCells(maskRuns(_cache.basinOf(f, a.pour), f.width)), a.pour.centre(g))),
                      a.threshold,
                      a.pour.distance(settings.outlet),
                    ]),
                  ),
            trailing: Text(s.f('points', [a.score]), style: Theme.of(context).textTheme.titleSmall),
            onTap: () => setState(() => _chosen = _chosen == a.participantId ? null : a.participantId),
          ),
      ],
    );
  }
}
