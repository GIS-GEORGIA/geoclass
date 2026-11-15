import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../nicknames.dart';
import '../session_base.dart';
import 'frame_map.dart';
import 'timelapse.dart';

/// A session's settings as the teacher's page has them: with the teacher's outlines.
TimelapseData sessionData(Map<String, dynamic> settings) => TimelapseData.fromJson(settings);

/// One student's answer, with what the page works out from it.
class OutlineRow {
  final String participantId;
  final int score, createdAt;
  final Outline a, b;
  final double areaA, areaB, iouA, iouB;
  const OutlineRow(
    this.participantId,
    this.score,
    this.createdAt,
    this.a,
    this.b,
    this.areaA,
    this.areaB,
    this.iouA,
    this.iouB,
  );

  factory OutlineRow.of(Map<String, dynamic> j, TimelapseData d) {
    final answer = j['answer'] as Map<String, dynamic>;
    final a = outlineFromJson(answer['a']), b = outlineFromJson(answer['b']);
    return OutlineRow(
      j['participantId'] as String,
      (j['score'] as num?)?.toInt() ?? 0,
      (j['createdAt'] as num?)?.toInt() ?? 0,
      a,
      b,
      outlineArea(a),
      outlineArea(b),
      iou(d.truthA, a),
      iou(d.truthB, b),
    );
  }
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per student: both areas, the change, how well each year matches and the score; the teacher's
/// outlines first.
String outlinesToCsv(TimelapseData d, List<OutlineRow> rows, String lang) {
  final out = StringBuffer(
    '﻿nickname,year_a,year_b,area_a_km2,area_b_km2,change_km2,change_pct,iou_a,iou_b,score,created_at\r\n',
  );
  String line(String who, double areaA, double areaB, String iouA, String iouB, String score, String at) => [
    _csv(who),
    d.yearA,
    d.yearB,
    (areaA / 1e6).toStringAsFixed(4),
    (areaB / 1e6).toStringAsFixed(4),
    ((areaB - areaA) / 1e6).toStringAsFixed(4),
    areaA > 0 ? ((areaB - areaA) / areaA * 100).toStringAsFixed(1) : '',
    iouA,
    iouB,
    score,
    at,
  ].join(',');
  out.write(
    line(lang == 'ka' ? 'მასწავლებელი' : 'teacher', outlineArea(d.truthA), outlineArea(d.truthB), '', '', '', ''),
  );
  out.write('\r\n');
  for (final r in rows) {
    out.write(
      line(
        nickname(r.participantId, lang),
        r.areaA,
        r.areaB,
        r.iouA.toStringAsFixed(3),
        r.iouB.toStringAsFixed(3),
        '${r.score}',
        DateTime.fromMillisecondsSinceEpoch(r.createdAt * 1000, isUtc: true).toIso8601String(),
      ),
    );
    out.write('\r\n');
  }
  return out.toString();
}

Map<String, dynamic> _polygons(Outline o) => {
  'type': 'MultiPolygon',
  'coordinates': [
    for (final ring in o)
      [
        [
          for (final p in [...ring, ring.first]) [p.longitude, p.latitude],
        ],
      ],
  ],
};

/// The teacher's outlines and each student's, one feature per outline and year.
String outlinesToGeoJson(TimelapseData d, List<OutlineRow> rows, String lang) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    for (final (year, o) in [(d.yearA, d.truthA), (d.yearB, d.truthB)])
      {
        'type': 'Feature',
        'geometry': _polygons(o),
        'properties': {'truth': true, 'site': d.site, 'year': year, 'area_km2': outlineArea(o) / 1e6},
      },
    for (final r in rows)
      for (final (year, o, area, match) in [(d.yearA, r.a, r.areaA, r.iouA), (d.yearB, r.b, r.areaB, r.iouB)])
        if (o.isNotEmpty)
          {
            'type': 'Feature',
            'geometry': _polygons(o),
            'properties': {
              'truth': false,
              'site': d.site,
              'year': year,
              'nickname': nickname(r.participantId, lang),
              'area_km2': area / 1e6,
              'iou': match,
              'score': r.score,
            },
          },
  ],
});

/// The teacher's page for a time-lapse session: a year's frame with the teacher's outline and every
/// student's, and a table of areas, changes and scores.
class TimelapseSessionPage extends SessionPageBase {
  final FrameLoader? loader;
  const TimelapseSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.loader,
  });
  @override
  State<TimelapseSessionPage> createState() => _TimelapseSessionPageState();
}

class _TimelapseSessionPageState extends SessionPageState<TimelapseSessionPage> {
  late final _loader = widget.loader ?? FrameLoader();
  List<OutlineRow> _rows = const [];
  SiteFrames? _frames;
  bool _showB = false;

  TimelapseData? get _data {
    try {
      return sessionData(session.settings);
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final d = _data;
    if (d != null) {
      _loader.site(d.site, d.version).then((f) {
        if (mounted) {
          setState(() => _frames = f);
          fitAll();
        }
      }, onError: (Object _) {});
    }
  }

  @override
  void onRows(List<Map<String, dynamic>> rows) {
    final d = _data;
    if (d == null) return;
    final out = <OutlineRow>[];
    for (final r in rows) {
      try {
        out.add(OutlineRow.of(r, d));
      } on Object {
        // An answer this app can't read is left out.
      }
    }
    _rows = out..sort((a, b) => b.score.compareTo(a.score));
  }

  @override
  List<LatLng> get fitPoints => _frames?.corners ?? const [];
  @override
  double get fitMaxZoom => 15;
  @override
  int get answerCount => _rows.length;
  @override
  int get shownCount => _rows.length;
  @override
  String exportCsv() => _data == null ? '' : outlinesToCsv(_data!, _rows, lang);
  @override
  String exportGeoJson() => _data == null ? '{}' : outlinesToGeoJson(_data!, _rows, lang);

  @override
  List<Widget> mapLayers() {
    final d = _data, f = _frames;
    if (d == null || f == null) return const [];
    final frame = f.frameOf(_showB ? d.yearB : d.yearA);
    return [
      if (frame != null) frameLayer(f, frame),
      for (final r in _rows) outlineLayer(_showB ? r.b : r.a, scoreColor(r.score), width: 1.5),
      outlineLayer(_showB ? d.truthB : d.truthA, Colors.white, dashed: true, width: 3),
    ];
  }

  @override
  List<Widget> mapOverlays() => const [];

  @override
  Widget panel() {
    final d = _data;
    if (d == null) return Center(child: Text(s['session_unreadable']));
    final truthA = outlineArea(d.truthA), truthB = outlineArea(d.truthB);
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<bool>(
            key: const Key('timelapse_session_year'),
            segments: [
              ButtonSegment(value: false, label: Text('${s['timelapse_year_a']} ${d.yearA}')),
              ButtonSegment(value: true, label: Text('${s['timelapse_year_b']} ${d.yearB}')),
            ],
            selected: {_showB},
            onSelectionChanged: (v) => setState(() => _showB = v.first),
          ),
        ),
        if (_frames != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              [
                if (_frames!.frameOf(_showB ? d.yearB : d.yearA) case final f?) frameLabel(f),
                ..._frames!.attribution,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ListTile(
          dense: true,
          title: Text(s['timelapse_teacher_outline']),
          subtitle: Text(
            '${d.yearA}: ${km2Text(truthA)} km² · ${d.yearB}: ${km2Text(truthB)} km² · ${changeText(truthA, truthB)}',
          ),
        ),
        if (_rows.isNotEmpty)
          ListTile(
            title: Text(
              s.f('slope_average', [
                (_rows.map((r) => r.score).reduce((a, b) => a + b) / _rows.length).round(),
                _rows.length,
              ]),
            ),
          ),
        const Divider(),
        if (_rows.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s['no_results'])),
        for (final (i, r) in _rows.indexed)
          ListTile(
            key: Key('timelapse_row_$i'),
            leading: CircleAvatar(
              backgroundColor: scoreColor(r.score),
              foregroundColor: Colors.white,
              child: Text('${r.score}', style: const TextStyle(fontSize: 12)),
            ),
            title: Text(nickname(r.participantId, lang)),
            subtitle: Text(
              s.f('timelapse_row', [
                km2Text(r.areaA),
                km2Text(r.areaB),
                changeText(r.areaA, r.areaB),
                (r.iouA * 100).round(),
                (r.iouB * 100).round(),
              ]),
            ),
          ),
      ],
    );
  }
}
