import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'slope_game.dart';

/// One student's marking, as the teacher's list of responses gives it.
class SlopeAnswer {
  final String participantId;
  final List<bool> marks;
  final int score, createdAt;
  const SlopeAnswer(this.participantId, this.marks, this.score, this.createdAt);

  factory SlopeAnswer.fromJson(Map<String, dynamic> j) => SlopeAnswer(
    j['participantId'] as String,
    marksFromString((j['answer'] as Map<String, dynamic>)['marks'] as String),
    (j['score'] as num?)?.toInt() ?? 0,
    (j['createdAt'] as num?)?.toInt() ?? 0,
  );
}

/// How many students marked each square.
List<int> markCounts(List<SlopeAnswer> answers, int squares) {
  final out = List.filled(squares, 0);
  for (final a in answers) {
    for (var k = 0; k < squares && k < a.marks.length; k++) {
      if (a.marks[k]) out[k]++;
    }
  }
  return out;
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: who, the squares they marked (numbered from 1, row by row), and the score.
String slopeAnswersToCsv(List<SlopeAnswer> answers, String lang) {
  final out = StringBuffer('﻿nickname,marked_squares,score,created_at\r\n');
  for (final a in answers) {
    final marked = [
      for (var k = 0; k < a.marks.length; k++)
        if (a.marks[k]) k + 1,
    ];
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        _csv(marked.join(' ')),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// Each square as a polygon, with how many marked it and whether it is steep.
String slopeToGeoJson(ElevationGrid g, SlopeGameSettings settings, List<int> counts) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    for (var k = 0; k < settings.box.n * settings.box.n; k++)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              for (final p in [...settings.box.square(g, k), settings.box.square(g, k).first])
                [p.longitude, p.latitude],
            ],
          ],
        },
        'properties': {
          'square': k + 1,
          'steep': settings.answer?[k],
          'threshold_deg': settings.threshold,
          'marked_by': counts[k],
        },
      },
  ],
});

/// The teacher's page for a slope session: the box on the map, shaded by how many students marked each
/// square, the right squares on request, and the leaderboard.
class SlopeSessionPage extends SessionPageBase {
  final DemLoader? loader;
  const SlopeSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen, this.loader});
  @override
  State<SlopeSessionPage> createState() => _SlopeSessionPageState();
}

class _SlopeSessionPageState extends SessionPageState<SlopeSessionPage> {
  late final DemLoader _loader = widget.loader ?? DemLoader();
  List<SlopeAnswer> _answers = const [];
  ElevationGrid? _grid;
  bool _reveal = false;

  SlopeGameSettings? get _settings {
    try {
      return SlopeGameSettings.fromJson(session.settings);
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
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) SlopeAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints {
    final g = _grid, settings = _settings;
    return g == null || settings == null ? const [] : settings.box.outline(g);
  }

  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() => slopeAnswersToCsv(_answers, lang);
  @override
  String exportGeoJson() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return '{"type":"FeatureCollection","features":[]}';
    return slopeToGeoJson(g, settings, markCounts(_answers, settings.box.n * settings.box.n));
  }

  @override
  List<Widget> mapLayers() {
    final g = _grid, settings = _settings;
    if (g == null || settings == null) return const [];
    final counts = markCounts(_answers, settings.box.n * settings.box.n);
    final total = _answers.length;
    return slopeBoxLayers(
      g,
      settings.box,
      Theme.of(context).colorScheme,
      fill: (k) => total == 0 || counts[k] == 0
          ? null
          : Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.15 + 0.6 * counts[k] / total),
      right: _reveal ? settings.answer : null,
    );
  }

  @override
  List<Widget> mapOverlays() => [
    Positioned(
      top: present ? 8 : 64,
      left: 8,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.f('slope_question', [_settings?.threshold ?? 15]), style: Theme.of(context).textTheme.titleSmall),
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
  ];

  @override
  Widget panel() {
    if (_answers.isEmpty) return Center(child: Text(s['no_results']));
    final rows = [..._answers]..sort((a, b) => b.score.compareTo(a.score));
    final average = (rows.map((a) => a.score).reduce((a, b) => a + b) / rows.length).round();
    return ListView(
      children: [
        ListTile(title: Text(s.f('slope_average', [average, rows.length]))),
        for (final (i, a) in rows.indexed)
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scoreColor(a.score),
              foregroundColor: Colors.white,
              child: Text('${i + 1}'),
            ),
            title: Text(nickname(a.participantId, lang)),
            subtitle: Text(s.f('slope_marked', [a.marks.where((m) => m).length, a.marks.length])),
            trailing: Text(s.f('points', [a.score]), style: Theme.of(context).textTheme.titleSmall),
          ),
      ],
    );
  }
}
