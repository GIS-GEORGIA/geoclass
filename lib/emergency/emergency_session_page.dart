import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../coords.dart';
import '../nicknames.dart';
import '../session_base.dart';
import 'emergency.dart';

/// One student's call about one point, with its score's parts.
class CallRow {
  final String participantId;
  final int round, score, createdAt;
  final EmergencyAnswer answer;
  const CallRow(this.participantId, this.round, this.score, this.createdAt, this.answer);

  factory CallRow.fromJson(Map<String, dynamic> j) => CallRow(
    j['participantId'] as String,
    (j['round'] as num).toInt(),
    (j['score'] as num?)?.toInt() ?? 0,
    (j['createdAt'] as num?)?.toInt() ?? 0,
    EmergencyAnswer.fromJson(j['answer'] as Map<String, dynamic>),
  );
}

/// The session's points, as the server keeps them (with the facts and the best photo).
List<EmergencyPoint> sessionPoints(Map<String, dynamic> settings) => [
  for (final p in settings['points'] as List) EmergencyPoint.fromJson(p as Map<String, dynamic>),
];

ScoreParts partsOf(EmergencyPoint p, CallRow c) =>
    scoreParts((lat: p.lat, lon: p.lon), p.format, p.facts, p.photos[p.best].id, c.answer);

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per call: who, which point, what they wrote and where it points, how far that is, the parts of
/// the score.
String callsToCsv(List<EmergencyPoint> points, List<CallRow> calls, String lang) {
  final out = StringBuffer(
    '﻿nickname,point,title,coords,format_asked,format_written,lat,lon,distance_m,kind,people,injured,landmark,'
    'photo_best,place_pts,format_pts,message_pts,photo_pts,score,created_at\r\n',
  );
  for (final c in calls) {
    if (c.round >= points.length) continue;
    final p = points[c.round];
    final parts = partsOf(p, c);
    final a = c.answer;
    out.write(
      [
        _csv(nickname(c.participantId, lang)),
        c.round + 1,
        _csv(p.title),
        _csv(a.coords),
        p.format,
        classifyCoords(a.coords) ?? '',
        a.at?.lat.toStringAsFixed(6) ?? '',
        a.at?.lon.toStringAsFixed(6) ?? '',
        parts.distance?.round() ?? '',
        a.kind,
        a.people,
        a.injured,
        _csv(a.landmark),
        a.photo == p.photos[p.best].id,
        parts.place,
        parts.format,
        parts.message,
        parts.photo,
        c.score,
        DateTime.fromMillisecondsSinceEpoch(c.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// The true points, and each call that could be read as a point with a line to the truth.
String callsToGeoJson(List<EmergencyPoint> points, List<CallRow> calls, String lang) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    for (final (i, p) in points.indexed)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lon, p.lat],
        },
        'properties': {'truth': true, 'point': i + 1, 'title': p.title, 'format': p.format},
      },
    for (final c in calls)
      if (c.answer.at != null && c.round < points.length) ...[
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [c.answer.at!.lon, c.answer.at!.lat],
          },
          'properties': {
            'truth': false,
            'point': c.round + 1,
            'nickname': nickname(c.participantId, lang),
            'coords': c.answer.coords,
            'distance_m': partsOf(points[c.round], c).distance?.round(),
            'score': c.score,
          },
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              [c.answer.at!.lon, c.answer.at!.lat],
              [points[c.round].lon, points[c.round].lat],
            ],
          },
          'properties': {'point': c.round + 1, 'nickname': nickname(c.participantId, lang)},
        },
      ],
  ],
});

/// The teacher's page for a 112 session: the true points, where each call put them, and every call's score
/// with its parts.
class EmergencySessionPage extends SessionPageBase {
  const EmergencySessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<EmergencySessionPage> createState() => _EmergencySessionPageState();
}

class _EmergencySessionPageState extends SessionPageState<EmergencySessionPage> {
  List<CallRow> _calls = const [];
  int? _point; // null: every point

  List<EmergencyPoint> get _points {
    try {
      return sessionPoints(session.settings);
    } on Object {
      return const [];
    }
  }

  List<CallRow> get _shown => _point == null
      ? _calls
      : [
          for (final c in _calls)
            if (c.round == _point) c,
        ];

  @override
  void onRows(List<Map<String, dynamic>> rows) {
    final out = <CallRow>[];
    for (final r in rows) {
      try {
        out.add(CallRow.fromJson(r));
      } on Object {
        // An answer this app can't read is left out.
      }
    }
    _calls = out..sort((a, b) => a.round != b.round ? a.round.compareTo(b.round) : b.score.compareTo(a.score));
  }

  @override
  List<LatLng> get fitPoints => [
    for (final (i, p) in _points.indexed)
      if (_point == null || _point == i) LatLng(p.lat, p.lon),
    for (final c in _shown)
      if (c.answer.at != null) LatLng(c.answer.at!.lat, c.answer.at!.lon),
  ];

  @override
  double get fitMaxZoom => 15;
  @override
  double get singlePointZoom => 15;
  @override
  int get answerCount => _calls.length;
  @override
  int get shownCount => _shown.length;
  @override
  String exportCsv() => callsToCsv(_points, _calls, lang);
  @override
  String exportGeoJson() => callsToGeoJson(_points, _calls, lang);

  @override
  List<Widget> mapLayers() {
    final points = _points;
    final scheme = Theme.of(context).colorScheme;
    final shown = [
      for (final c in _shown)
        if (c.answer.at != null && c.round < points.length) c,
    ];
    return [
      PolylineLayer(
        polylines: [
          for (final c in shown)
            Polyline(
              points: [LatLng(c.answer.at!.lat, c.answer.at!.lon), LatLng(points[c.round].lat, points[c.round].lon)],
              color: scoreColor(c.score).withValues(alpha: 0.7),
              strokeWidth: 2,
            ),
        ],
      ),
      MarkerLayer(
        markers: [
          // The true points under the students' dots, so a call close to its point still shows.
          for (final (i, p) in points.indexed)
            if (_point == null || _point == i)
              Marker(
                point: LatLng(p.lat, p.lon),
                width: 28,
                height: 28,
                child: CircleAvatar(
                  backgroundColor: scheme.error,
                  child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: scheme.onError)),
                ),
              ),
          for (final c in shown)
            Marker(
              point: LatLng(c.answer.at!.lat, c.answer.at!.lon),
              width: 16,
              height: 16,
              child: Container(
                decoration: BoxDecoration(
                  color: scoreColor(c.score),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  @override
  List<Widget> mapOverlays() => const [];

  @override
  Widget panel() {
    final points = _points;
    final shown = _shown;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                key: const Key('emergency_filter_all'),
                label: Text(s['emergency_all_points']),
                selected: _point == null,
                showCheckmark: false,
                onSelected: (_) => setState(() {
                  _point = null;
                  fitAll();
                }),
              ),
              for (var i = 0; i < points.length; i++)
                ChoiceChip(
                  key: Key('emergency_filter_$i'),
                  label: Text('${i + 1}'),
                  selected: _point == i,
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    _point = i;
                    fitAll();
                  }),
                ),
            ],
          ),
        ),
        if (_point != null && _point! < points.length)
          ListTile(
            dense: true,
            title: Text(points[_point!].title),
            subtitle: Text(
              '${formatAs(points[_point!].format, points[_point!].lat, points[_point!].lon)} · ${s['format_${points[_point!].format}']}',
            ),
          ),
        if (shown.isNotEmpty)
          ListTile(
            title: Text(
              s.f('slope_average', [
                (shown.map((c) => c.score).reduce((a, b) => a + b) / shown.length).round(),
                shown.length,
              ]),
            ),
          ),
        const Divider(),
        if (shown.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s['no_results'])),
        for (final (i, c) in shown.indexed)
          if (c.round < points.length)
            ListTile(
              key: Key('emergency_call_$i'),
              leading: CircleAvatar(
                backgroundColor: scoreColor(c.score),
                foregroundColor: Colors.white,
                child: Text('${c.round + 1}'),
              ),
              title: Text('${nickname(c.participantId, lang)} · ${c.answer.coords}'),
              subtitle: Text(() {
                final parts = partsOf(points[c.round], c);
                final d = parts.distance;
                return s.f('emergency_row', [
                  d == null ? '–' : (d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km' : '${d.round()} m'),
                  parts.place,
                  parts.format,
                  parts.message,
                  parts.photo,
                ]);
              }()),
              trailing: Text(s.f('points', [c.score]), style: Theme.of(context).textTheme.titleSmall),
            ),
      ],
    );
  }
}
