import 'dart:convert';

import 'coords.dart';
import 'mapping.dart';
import 'models.dart';
import 'nicknames.dart';

String _iso(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toIso8601String();

/// Students write this text, so a spreadsheet must not run it as a formula.
String _csvText(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  return '"${v.replaceAll('"', '""')}"';
}

/// UTF-8 BOM first, so Excel reads Georgian correctly.
String answersToCsv(List<TravelAnswer> answers) {
  final out = StringBuffer('﻿place,country,reason,transport,company,lat,lon,hidden,created_at\r\n');
  for (final a in answers) {
    out.write([
      _csvText(a.place),
      _csvText(a.country),
      _csvText(a.reason),
      a.transport,
      a.company,
      a.lat,
      a.lon,
      a.hidden,
      _iso(a.createdAt),
    ].join(','));
    out.write('\r\n');
  }
  return out.toString();
}

String answersToGeoJson(List<TravelAnswer> answers) => const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': [
        for (final a in answers)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [a.lon, a.lat],
            },
            'properties': {
              'place': a.place,
              'country': a.country,
              'reason': a.reason,
              'transport': a.transport,
              'company': a.company,
              'hidden': a.hidden,
              'created_at': _iso(a.createdAt),
            },
          },
      ],
    });

/// Counts by key, largest first. Hidden answers don't count.
List<MapEntry<String, int>> countBy(List<TravelAnswer> answers, String Function(TravelAnswer) key) {
  final counts = <String, int>{};
  for (final a in answers) {
    if (a.hidden) continue;
    final k = key(a);
    if (k.isEmpty) continue;
    counts[k] = (counts[k] ?? 0) + 1;
  }
  return counts.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
}

String coordAnswersToCsv(List<CoordAnswer> answers, List<CoordTask> tasks, String lang) {
  final out = StringBuffer(
    '\uFEFFnickname,task,mode,format,typed,lat,lon,distance_m,score,target_lat,target_lon,utm,created_at\r\n',
  );
  for (final a in answers) {
    final t = tasks[a.round];
    out.write([
      _csvText(nickname(a.participantId, lang)),
      a.round + 1,
      t.mode,
      t.format,
      _csvText(a.raw),
      a.lat,
      a.lon,
      a.distanceM.round(),
      a.score,
      t.lat,
      t.lon,
      _csvText(formatUtm(a.lat, a.lon)),
      _iso(a.createdAt),
    ].join(','));
    out.write('\r\n');
  }
  return out.toString();
}

String coordAnswersToGeoJson(List<CoordAnswer> answers, List<CoordTask> tasks, String lang) =>
    const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': [
        for (final a in answers)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [a.lon, a.lat],
            },
            'properties': {
              'nickname': nickname(a.participantId, lang),
              'task': a.round + 1,
              'mode': tasks[a.round].mode,
              'format': tasks[a.round].format,
              'typed': a.raw,
              'distance_m': a.distanceM.round(),
              'score': a.score,
              'target_lat': tasks[a.round].lat,
              'target_lon': tasks[a.round].lon,
              'created_at': _iso(a.createdAt),
            },
          },
      ],
    });

Map<String, dynamic> _geometry(MapObject o) => switch (o.kind) {
      'point' => {'type': 'Point', 'coordinates': o.coords.first},
      'line' => {'type': 'LineString', 'coordinates': o.coords},
      // A polygon's ring ends where it starts.
      _ => {
          'type': 'Polygon',
          'coordinates': [
            [...o.coords, o.coords.first],
          ],
        },
    };

String _wkt(MapObject o) {
  String pair(List<double> c) => '${c[0]} ${c[1]}';
  return switch (o.kind) {
    'point' => 'POINT (${pair(o.coords.first)})',
    'line' => 'LINESTRING (${o.coords.map(pair).join(', ')})',
    _ => 'POLYGON ((${[...o.coords, o.coords.first].map(pair).join(', ')}))',
  };
}

String mapObjectsToCsv(List<MapObject> objects, String lang) {
  final out = StringBuffer('\uFEFFnickname,category,kind,wkt,hidden,created_at\r\n');
  for (final o in objects) {
    out.write([
      _csvText(nickname(o.participantId, lang)),
      o.category,
      o.kind,
      _csvText(_wkt(o)),
      o.hidden,
      _iso(o.createdAt),
    ].join(','));
    out.write('\r\n');
  }
  return out.toString();
}

String mapObjectsToGeoJson(List<MapObject> objects, String lang) => const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': [
        for (final o in objects)
          {
            'type': 'Feature',
            'geometry': _geometry(o),
            'properties': {
              'nickname': nickname(o.participantId, lang),
              'category': o.category,
              'kind': o.kind,
              'hidden': o.hidden,
              'created_at': _iso(o.createdAt),
            },
          },
      ],
    });

class LeaderRow {
  final String participantId;
  final int score, answered;
  const LeaderRow(this.participantId, this.score, this.answered);
}

/// Highest total first. With equal totals, whoever answered fewer tasks ranks higher.
List<LeaderRow> leaderboard(List<CoordAnswer> answers) {
  final score = <String, int>{};
  final count = <String, int>{};
  for (final a in answers) {
    score[a.participantId] = (score[a.participantId] ?? 0) + a.score;
    count[a.participantId] = (count[a.participantId] ?? 0) + 1;
  }
  final rows = [for (final id in score.keys) LeaderRow(id, score[id]!, count[id]!)];
  rows.sort((x, y) {
    final byScore = y.score.compareTo(x.score);
    return byScore != 0 ? byScore : x.answered.compareTo(y.answered);
  });
  return rows;
}

/// Most objects first. With equal counts, whoever reached that count sooner ranks higher. Hidden objects don't count.
List<LeaderRow> mappingLeaderboard(List<MapObject> objects) {
  final count = <String, int>{};
  final last = <String, int>{};
  for (final o in objects) {
    if (o.hidden) continue;
    count[o.participantId] = (count[o.participantId] ?? 0) + 1;
    if (o.createdAt > (last[o.participantId] ?? 0)) last[o.participantId] = o.createdAt;
  }
  final rows = [for (final id in count.keys) LeaderRow(id, count[id]!, count[id]!)];
  rows.sort((x, y) {
    final byCount = y.answered.compareTo(x.answered);
    return byCount != 0 ? byCount : last[x.participantId]!.compareTo(last[y.participantId]!);
  });
  return rows;
}
