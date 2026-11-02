import 'dart:convert';

import 'models.dart';

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
