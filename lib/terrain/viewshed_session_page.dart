import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'slope_game.dart';
import 'viewshed_game.dart';

/// One student's answer, as the teacher's list of responses gives it: seen or not, per target or square.
class ViewshedAnswer {
  final String participantId;
  final List<bool> seen;
  final int score, createdAt;
  const ViewshedAnswer(this.participantId, this.seen, this.score, this.createdAt);

  factory ViewshedAnswer.fromJson(Map<String, dynamic> j) => ViewshedAnswer(
    j['participantId'] as String,
    marksFromString((j['answer'] as Map<String, dynamic>)['seen'] as String),
    (j['score'] as num?)?.toInt() ?? 0,
    (j['createdAt'] as num?)?.toInt() ?? 0,
  );
}

/// How many students said each target or square is seen.
List<int> seenCounts(List<ViewshedAnswer> answers, int count) {
  final out = List.filled(count, 0);
  for (final a in answers) {
    for (var k = 0; k < count && k < a.seen.length; k++) {
      if (a.seen[k]) out[k]++;
    }
  }
  return out;
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: who, the targets or squares they said are seen (numbered from 1), and the score.
String viewshedAnswersToCsv(List<ViewshedAnswer> answers, String lang) {
  final out = StringBuffer('﻿nickname,said_seen,score,created_at\r\n');
  for (final a in answers) {
    final seen = [
      for (var k = 0; k < a.seen.length; k++)
        if (a.seen[k]) k + 1,
    ];
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        _csv(seen.join(' ')),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// The observer, and each target as a point or each square as a polygon, with whether it is seen and how many
/// students said so.
String viewshedToGeoJson(ElevationGrid g, ViewshedGameSettings settings, List<int> counts) {
  List<double> lonLat(LatLng p) => [p.longitude, p.latitude];
  return jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': lonLat(settings.observer.centre(g))},
        'properties': {'observer': true, 'height_m': settings.height},
      },
      for (var k = 0; k < settings.count; k++)
        {
          'type': 'Feature',
          'geometry': settings.byTargets
              ? {'type': 'Point', 'coordinates': lonLat(settings.targets[k].centre(g))}
              : {
                  'type': 'Polygon',
                  'coordinates': [
                    [
                      for (final p in [...settings.box!.square(g, k), settings.box!.square(g, k).first]) lonLat(p),
                    ],
                  ],
                },
          'properties': {
            settings.byTargets ? 'target' : 'square': k + 1,
            'seen': settings.answer?[k],
            'said_seen_by': counts[k],
          },
        },
    ],
  });
}

/// The teacher's page for a viewshed session: the observer and the targets or the box, shaded by how many
/// students said each is seen; on request, what is really seen; and the leaderboard.
class ViewshedSessionPage extends SessionPageBase {
  final DemLoader? loader;
  const ViewshedSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.loader,
  });
  @override
  State<ViewshedSessionPage> createState() => _ViewshedSessionPageState();
}

class _ViewshedSessionPageState extends SessionPageState<ViewshedSessionPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  final _cache = ViewshedCache();
  List<ViewshedAnswer> _answers = const [];
  ElevationGrid? _grid;
  bool _reveal = false;

  ViewshedGameSettings? get _settings {
    try {
      return ViewshedGameSettings.fromJson(session.settings);
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
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) ViewshedAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    return [
      settings.observer.centre(g),
      if (settings.byTargets) ...settings.targets.map((t) => t.centre(g)) else ...settings.box!.outline(g),
    ];
  }

  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() => viewshedAnswersToCsv(_answers, lang);
  @override
  String exportGeoJson() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '{"type":"FeatureCollection","features":[]}';
    return viewshedToGeoJson(g, settings, seenCounts(_answers, settings.count));
  }

  @override
  List<Widget> mapLayers() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    final counts = seenCounts(_answers, settings.count);
    final total = _answers.length;
    final right = _reveal ? settings.answer : null;
    final seen = _reveal ? _cache.of(g, settings.observer, settings.height) : null;
    // A share of the class: how strongly the students think it is seen.
    Color? share(int k) =>
        total == 0 || counts[k] == 0 ? null : scheme.tertiary.withValues(alpha: 0.15 + 0.6 * counts[k] / total);
    return [
      if (seen != null) viewshedLayer(g, settings.observer, settings.height, seen),
      if (settings.byTargets)
        targetsLayer(
          g,
          settings.targets,
          scheme,
          colour: (i) => right != null ? (right[i] ? viewSeenFill : viewHiddenFill) : share(i),
        )
      else
        ...slopeBoxLayers(g, settings.box!, scheme, fill: share, right: right),
      observerLayer(g, settings.observer, scheme),
    ];
  }

  @override
  List<Widget> mapOverlays() {
    final settings = _settings;
    return [
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
                  Flexible(
                    child: Text(
                      settings == null
                          ? s['game_viewshed']
                          : s.f(settings.byTargets ? 'view_question_targets' : 'view_question_squares', [
                              viewMetres(settings.height),
                            ]),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
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
  }

  @override
  Widget panel() {
    final settings = _settings;
    if (_answers.isEmpty || settings == null) return Center(child: Text(s['no_results']));
    final rows = [..._answers]..sort((a, b) => b.score.compareTo(a.score));
    final average = (rows.map((a) => a.score).reduce((a, b) => a + b) / rows.length).round();
    final counts = seenCounts(_answers, settings.count);
    return ListView(
      children: [
        ListTile(title: Text(s.f('slope_average', [average, rows.length]))),
        if (settings.byTargets)
          for (var i = 0; i < settings.count; i++)
            ListTile(
              dense: true,
              leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
              title: Text(s.f('view_target_said', [counts[i], rows.length])),
              trailing: settings.answer == null || !_reveal
                  ? null
                  : Icon(settings.answer![i] ? Icons.visibility : Icons.visibility_off),
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
            subtitle: Text(
              s.f(settings.byTargets ? 'view_said_seen' : 'slope_marked', [
                a.seen.where((m) => m).length,
                a.seen.length,
              ]),
            ),
            trailing: Text(s.f('points', [a.score]), style: Theme.of(context).textTheme.titleSmall),
          ),
      ],
    );
  }
}
