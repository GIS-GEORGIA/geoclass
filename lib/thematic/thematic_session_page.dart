import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../files.dart';
import '../nicknames.dart';
import '../puzzle.dart' show GeoUnits, loadGeoUnits;
import '../session_base.dart';
import 'thematic.dart';
import 'thematic_map.dart';

/// One student's handed-in map: their choice, and the score in target mode.
class ThematicAnswer {
  final String participantId;
  final ThematicChoice? choice; // null if the stored answer can't be read
  final int? score;
  final int createdAt;
  const ThematicAnswer(this.participantId, this.choice, this.score, this.createdAt);

  factory ThematicAnswer.fromJson(Map<String, dynamic> j) {
    ThematicChoice? c;
    try {
      c = ThematicChoice.fromJson(j['answer'] as Map<String, dynamic>);
    } on Object {
      c = null;
    }
    return ThematicAnswer(
      j['participantId'] as String,
      c,
      (j['score'] as num?)?.toInt(),
      (j['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: who, what they chose, and the score.
String thematicAnswersToCsv(ThematicSettings s, List<ThematicAnswer> answers, String lang) {
  final out = StringBuffer('﻿nickname,field,normalise,method,classes,ramp,breaks,score,created_at\r\n');
  for (final a in answers) {
    final c = a.choice;
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        _csv(c == null || c.field >= s.fields.length ? '' : s.fields[c.field].name),
        c?.normalise ?? '',
        c?.method ?? '',
        c?.classes ?? '',
        c?.ramp ?? '',
        _csv(c?.breaks?.join(' ') ?? ''),
        a.score ?? '',
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// The units with the teacher's numbers, their areas, and the target's class, as polygons for a GIS.
String thematicToGeoJson(ThematicBase base, ThematicSettings s) {
  final target = s.target;
  final classified = target == null ? null : classify(s, target, base.areas);
  return jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (var i = 0; i < s.units.length; i++)
        if (base.units[i] != null)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                for (final r in base.units[i]!.rings)
                  [
                    for (final p in [...r, r.first]) [p.dx, p.dy],
                  ],
              ],
            },
            'properties': {
              'id': s.units[i],
              'ka': base.units[i]!.ka,
              'en': base.units[i]!.en,
              'area_km2': double.parse(base.areas[i].toStringAsFixed(2)),
              for (final f in s.fields) f.name: f.values[i],
              if (classified != null)
                'target_class': classified.classOfUnit[i] == null ? null : classified.classOfUnit[i]! + 1,
            },
          },
    ],
  });
}

/// The teacher's page for a thematic map session: the target, and every student's map to open and print.
class ThematicSessionPage extends SessionPageBase {
  final GeoUnits? units;
  const ThematicSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.units,
  });
  @override
  State<ThematicSessionPage> createState() => _ThematicSessionPageState();
}

class _ThematicSessionPageState extends SessionPageState<ThematicSessionPage> {
  List<ThematicAnswer> _answers = const [];
  ThematicBase? _base;

  ThematicSettings? get _settings {
    try {
      return ThematicSettings.fromJson(session.settings);
    } on FormatException {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final st = _settings;
    if (st == null) return;
    final u = widget.units;
    (u != null ? Future.value(u) : loadGeoUnits()).then((all) {
      if (mounted) setState(() => _base = ThematicBase.of(all, st));
    });
  }

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) =>
      _answers = [for (final r in rows) ThematicAnswer.fromJson(r)]
        ..sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() {
    final st = _settings;
    return st == null ? '' : thematicAnswersToCsv(st, _answers, lang);
  }

  @override
  String exportGeoJson() {
    final st = _settings, base = _base;
    if (st == null || base == null) return '{"type":"FeatureCollection","features":[]}';
    return thematicToGeoJson(base, st);
  }

  @override
  List<Widget> mapLayers() => const [];
  @override
  List<Widget> mapOverlays() => const [];

  void _open(String title, ThematicView v, ThematicSettings st) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 900,
        height: 520,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ChoroplethView(view: v, s: s, lang: lang),
            ),
            SizedBox(
              width: 220,
              child: SingleChildScrollView(
                child: ThematicLegend(view: v, s: s),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async => saveBytes(await thematicPdf(v, s, st.title), 'geoclass-map', 'pdf', 'application/pdf'),
          icon: const Icon(Icons.picture_as_pdf),
          label: Text(s['layout_pdf']),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s['close'])),
      ],
    ),
  );

  String _choiceLine(ThematicSettings st, ThematicChoice c) => s.f('thematic_target_line', [
    c.field < st.fields.length ? st.fields[c.field].name : '?',
    s['thematic_normalise_${c.normalise}'],
    s['thematic_method_${c.method}'],
    c.classes,
  ]);

  @override
  Widget panel() {
    final st = _settings, base = _base;
    if (st == null) return Center(child: Text(s['profile_bad_session']));
    if (base == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final target = st.target;
    final scored = [
      for (final a in _answers)
        if (a.score != null) a.score!,
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: ListTile(
                title: Text(st.title.isEmpty ? s['game_thematic'] : st.title),
                subtitle: Text(
                  '${s['thematic_level_${st.level}']} · ${s.f('thematic_units', [st.units.length])} · '
                  '${s['thematic_mode_${st.mode}']}'
                  '${target == null ? '' : '\n${s['thematic_target']}: ${_choiceLine(st, target)}'}',
                ),
                trailing: target == null
                    ? null
                    : IconButton(
                        key: const Key('thematic_show_target'),
                        tooltip: s['answer_show'],
                        icon: const Icon(Icons.map),
                        onPressed: () => _open(s['thematic_target'], ThematicView.of(base, st, target), st),
                      ),
              ),
            ),
            if (_answers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text(s['no_results'])),
              )
            else ...[
              if (scored.isNotEmpty)
                ListTile(
                  title: Text(
                    s.f('slope_average', [(scored.reduce((a, b) => a + b) / scored.length).round(), scored.length]),
                  ),
                ),
              for (final (i, a) in _answers.indexed)
                ListTile(
                  key: Key('thematic_answer_$i'),
                  leading: CircleAvatar(
                    backgroundColor: a.score == null ? theme.colorScheme.secondary : scoreColor(a.score!),
                    foregroundColor: Colors.white,
                    child: Text('${i + 1}'),
                  ),
                  title: Text(nickname(a.participantId, lang)),
                  subtitle: a.choice == null ? null : Text(_choiceLine(st, a.choice!)),
                  trailing: a.score == null ? null : Text(s.f('points', [a.score]), style: theme.textTheme.titleSmall),
                  onTap: a.choice == null || a.choice!.field >= st.fields.length
                      ? null
                      : () => _open(nickname(a.participantId, lang), ThematicView.of(base, st, a.choice!), st),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
