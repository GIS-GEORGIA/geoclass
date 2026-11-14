import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../evidence.dart' show normaliseName;
import '../puzzle.dart' show GeoUnit, GeoUnits;
import '../terrain/watershed.dart' show geodesicArea;
import 'ramps.dart';

/// The thematic map game: the teacher's table of numbers by region or municipality; students choose what to
/// show and how to classify it, and get a choropleth with its legend. As worker/src/games/thematic.ts checks it.
const thematicLevels = ['regions', 'municipalities'];
const thematicMethods = ['equal', 'quantile', 'jenks', 'manual'];
const thematicNormalisations = ['none', 'area'];
const thematicModes = ['target', 'free'];
const thematicKinds = ['count', 'rate'];
const thematicClassesMin = 3, thematicClassesMax = 7, thematicFieldsMax = 4;

/// What a file may be: 1 MB and 5000 rows, as the audit set.
const thematicFileMax = 1024 * 1024, thematicRowsMax = 5000;

/// The settings a session may carry, below the Worker's 8 KB limit on a request with room to spare.
const thematicSettingsMax = 7000;

List<GeoUnit> levelUnits(GeoUnits all, String level) => level == 'regions' ? all.regions : all.municipalities;

/// What is drawn in grey around the units: parts of Georgia a level doesn't divide (Abkhazia has no municipalities).
List<GeoUnit> levelFixed(GeoUnits all, String level) => [
  ...all.fixed,
  if (level == 'municipalities') ...all.regions.where((r) => all.municipalitiesOf(r.id).isEmpty),
];

// ---------------------------------------------------------------------------------------------------------------
// Areas

bool _inside(LatLng p, List<LatLng> ring) {
  var c = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
      c = !c;
    }
  }
  return c;
}

/// A unit's area on the WGS84 ellipsoid in km², its rings filled even-odd (a ring inside another is a hole).
/// test/thematic_test.dart checks it against PROJ's geod.
double unitAreaKm2(GeoUnit u) {
  final rings = [
    for (final r in u.rings) [for (final p in r) LatLng(p.dy, p.dx)],
  ];
  var total = 0.0;
  for (var i = 0; i < rings.length; i++) {
    var depth = 0;
    for (var j = 0; j < rings.length; j++) {
      if (j != i && _inside(rings[i].first, rings[j])) depth++;
    }
    total += geodesicArea(rings[i]) * (depth.isEven ? 1 : -1);
  }
  return total / 1e6;
}

// ---------------------------------------------------------------------------------------------------------------
// Classification

/// The classes' upper bounds, lowest first, the last one the largest value, as QGIS's QgsClassification* gives
/// them for equal interval and quantile (test/thematic_test.dart checks both against QGIS). [values] without
/// gaps; at least one.
List<double> classBreaks(List<double> values, String method, int classes) {
  final v = [...values]..sort();
  final n = v.length, lo = v.first, hi = v.last;
  switch (method) {
    case 'equal':
      final step = (hi - lo) / classes;
      return [for (var i = 1; i < classes; i++) lo + step * i, hi];
    case 'quantile':
      // R's type 7, as QGIS: the value at (n − 1)·q + 1 in the sorted list, between neighbours linearly.
      return [
        for (var i = 1; i < classes; i++)
          () {
            final h = (n - 1) * i / classes;
            final f = h.floor();
            return f + 1 < n ? v[f] + (h - f) * (v[f + 1] - v[f]) : v[f];
          }(),
        hi,
      ];
    case 'jenks':
      return _jenks(v, classes);
  }
  throw ArgumentError.value(method, 'method');
}

/// Jenks natural breaks: the classes with the least sum of squared deviations, found exactly by dynamic
/// programming (Jenks 1977; Fisher 1958). QGIS's QgsClassificationJenks runs the same loops but steps one value
/// too far as it reads the breaks back, so it often misses the optimum; test/thematic_test.dart checks this one
/// against the exact optimum worked out by tool/thematic/make_thematic_fixture.py, and that it is never worse
/// than QGIS's.
List<double> _jenks(List<double> v, int k) {
  final n = v.length;
  if (k >= n) return [...v];
  final lower = List.generate(n + 1, (_) => List.filled(k + 1, 0));
  final cost = List.generate(n + 1, (_) => List.filled(k + 1, double.infinity));
  for (var j = 1; j <= k; j++) {
    lower[1][j] = 1;
    cost[1][j] = 0;
  }
  for (var l = 2; l <= n; l++) {
    var s1 = 0.0, s2 = 0.0, w = 0.0, variance = 0.0;
    for (var m = 1; m <= l; m++) {
      final i3 = l - m + 1;
      final x = v[i3 - 1];
      s2 += x * x;
      s1 += x;
      w += 1;
      variance = s2 - s1 * s1 / w;
      final i4 = i3 - 1;
      if (i4 != 0) {
        for (var j = 2; j <= k; j++) {
          if (cost[l][j] >= variance + cost[i4][j - 1]) {
            lower[l][j] = i3;
            cost[l][j] = variance + cost[i4][j - 1];
          }
        }
      }
    }
    lower[l][1] = 1;
    cost[l][1] = variance;
  }
  final out = List.filled(k, 0.0);
  out[k - 1] = v[n - 1];
  var at = n;
  for (var j = k; j >= 2; j--) {
    final id = lower[at][j] - 2;
    out[j - 2] = v[id];
    at = lower[at][j] - 1;
  }
  return out;
}

/// The class of [value] under [uppers]: the first class whose upper bound it doesn't pass.
int classOf(double value, List<double> uppers) {
  for (var i = 0; i < uppers.length; i++) {
    if (value <= uppers[i]) return i;
  }
  return uppers.length - 1;
}

// ---------------------------------------------------------------------------------------------------------------
// The teacher's data and the students' choices

/// One column of numbers, a value (or no data) per unit of [ThematicData.units]. A count (people, hectares) is
/// best shown per km²; a rate (per cent, per person) as it is.
class ThematicField {
  final String name, kind;
  final List<double?> values;
  const ThematicField(this.name, this.kind, this.values);

  factory ThematicField.fromJson(Map<String, dynamic> j) => ThematicField(j['name'] as String, j['kind'] as String, [
    for (final v in j['values'] as List) (v as num?)?.toDouble(),
  ]);

  Map<String, dynamic> toJson() => {'name': name, 'kind': kind, 'values': values};
}

/// How a student shows a field.
class ThematicChoice {
  final int field, classes;
  final String normalise, method, ramp;

  /// The inner breaks for the manual method, classes − 1 of them, ascending.
  final List<double>? breaks;

  const ThematicChoice({
    required this.field,
    this.normalise = 'none',
    this.method = 'quantile',
    this.classes = 5,
    this.ramp = 'Blues',
    this.breaks,
  });

  factory ThematicChoice.fromJson(Map<String, dynamic> j) {
    try {
      final c = ThematicChoice(
        field: j['field'] as int,
        normalise: j['normalise'] as String,
        method: j['method'] as String,
        classes: j['classes'] as int,
        ramp: j['ramp'] as String? ?? 'Blues',
        breaks: (j['breaks'] as List?)?.map((b) => (b as num).toDouble()).toList(),
      );
      if (!thematicNormalisations.contains(c.normalise) ||
          !thematicMethods.contains(c.method) ||
          c.classes < thematicClassesMin ||
          c.classes > thematicClassesMax ||
          !thematicRamps.containsKey(c.ramp)) {
        throw const FormatException('bad thematic choice');
      }
      return c;
    } on TypeError {
      throw const FormatException('bad thematic choice');
    }
  }

  Map<String, dynamic> toJson() => {
    'field': field,
    'normalise': normalise,
    'method': method,
    'classes': classes,
    'ramp': ramp,
    if (method == 'manual' && breaks != null) 'breaks': breaks,
  };

  ThematicChoice copyWith({
    int? field,
    String? normalise,
    String? method,
    int? classes,
    String? ramp,
    List<double>? breaks,
  }) => ThematicChoice(
    field: field ?? this.field,
    normalise: normalise ?? this.normalise,
    method: method ?? this.method,
    classes: classes ?? this.classes,
    ramp: ramp ?? this.ramp,
    breaks: breaks ?? this.breaks,
  );

  @override
  bool operator ==(Object other) =>
      other is ThematicChoice &&
      other.field == field &&
      other.normalise == normalise &&
      other.method == method &&
      other.classes == classes &&
      other.ramp == ramp;
  @override
  int get hashCode => Object.hash(field, normalise, method, classes, ramp);
}

/// The score a target gives: 25 for each of the field, the normalisation, the method and the number of classes
/// that match it. As worker/src/games/thematic.ts scores it.
int thematicScore(ThematicChoice target, ThematicChoice answer) =>
    (answer.field == target.field ? 25 : 0) +
    (answer.normalise == target.normalise ? 25 : 0) +
    (answer.method == target.method ? 25 : 0) +
    (answer.classes == target.classes ? 25 : 0);

/// The session's settings. [target] only on the teacher's side and in the reply to an answer.
class ThematicSettings {
  final String level, title, mode;
  final List<String> units;
  final List<ThematicField> fields;
  final ThematicChoice? target;
  const ThematicSettings({
    required this.level,
    required this.title,
    required this.mode,
    required this.units,
    required this.fields,
    this.target,
  });

  factory ThematicSettings.fromJson(Map<String, dynamic> j) {
    try {
      return ThematicSettings(
        level: j['level'] as String,
        title: j['title'] as String,
        mode: j['mode'] as String,
        units: [for (final u in j['units'] as List) u as String],
        fields: [for (final f in j['fields'] as List) ThematicField.fromJson(f as Map<String, dynamic>)],
        target: j['target'] == null ? null : ThematicChoice.fromJson(j['target'] as Map<String, dynamic>),
      );
    } on TypeError {
      throw const FormatException('bad thematic settings');
    }
  }

  Map<String, dynamic> toJson() => {
    'level': level,
    'title': title,
    'mode': mode,
    'units': units,
    'fields': [for (final f in fields) f.toJson()],
    if (target != null) 'target': target!.toJson(),
  };
}

/// What a choice makes of the data: each unit's value (per km² if so chosen; null for no data), the classes'
/// upper bounds, each unit's class (null for no data) and the colours.
class Classified {
  final List<double?> values;
  final List<double> uppers;
  final List<int?> classOfUnit;
  final List<int> counts;
  final List<double> range; // the smallest and largest value
  const Classified(this.values, this.uppers, this.classOfUnit, this.counts, this.range);
}

/// [areas] the units' areas in km², in the settings' order; null without data to classify.
Classified? classify(ThematicSettings s, ThematicChoice c, List<double> areas) {
  final f = s.fields[c.field];
  final values = [
    for (var i = 0; i < f.values.length; i++)
      switch (f.values[i]) {
        null => null,
        final v when c.normalise == 'area' => areas[i] > 0 ? v / areas[i] : null,
        final v => v,
      },
  ];
  final known = values.whereType<double>().toList();
  if (known.isEmpty) return null;
  final lo = known.reduce(math.min), hi = known.reduce(math.max);
  List<double> uppers;
  if (c.method == 'manual') {
    final b = c.breaks;
    uppers = b != null && b.length == c.classes - 1 ? [...b, hi] : classBreaks(known, 'equal', c.classes);
  } else {
    uppers = classBreaks(known, c.method, c.classes);
  }
  final cls = [for (final v in values) v == null ? null : classOf(v, uppers)];
  final counts = List.filled(uppers.length, 0);
  for (final k in cls) {
    if (k != null) counts[k]++;
  }
  return Classified(values, uppers, cls, counts, [lo, hi]);
}

/// A number as a legend writes it: three significant figures, whole numbers as they are.
String legendNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e7) return v.round().toString();
  final a = v.abs();
  final digits = a >= 100 ? 0 : (a >= 10 ? 1 : (a >= 1 ? 2 : 3));
  return v.toStringAsFixed(digits);
}

// ---------------------------------------------------------------------------------------------------------------
// Reading a table

/// A table read from a file: column names and rows of cells (null for empty).
class ThematicTable {
  final List<String> columns;
  final List<List<String?>> rows;
  const ThematicTable(this.columns, this.rows);
}

/// Why a file can't be read: an l10n key.
class TableError implements Exception {
  final String key;
  const TableError(this.key);
  @override
  String toString() => 'TableError($key)';
}

/// A CSV (comma, semicolon or tab; quotes as RFC 4180), a JSON array of objects or a GeoJSON FeatureCollection
/// (its features' properties; the geometry is not needed). UTF-8 only.
ThematicTable readTable(Uint8List bytes, String fileName) {
  if (bytes.length > thematicFileMax) throw const TableError('thematic_file_big');
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const TableError('thematic_file_encoding');
  }
  if (text.startsWith('﻿')) text = text.substring(1);
  final t = text.trimLeft();
  final table = t.startsWith('[') || t.startsWith('{') ? _readJson(t) : _readCsv(text);
  if (table.rows.isEmpty || table.columns.length < 2) throw const TableError('thematic_file_empty');
  if (table.rows.length > thematicRowsMax) throw const TableError('thematic_file_rows');
  return table;
}

ThematicTable _readJson(String text) {
  Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    throw const TableError('thematic_file_bad');
  }
  final List<Object?> items;
  if (j is Map && j['type'] == 'FeatureCollection' && j['features'] is List) {
    items = [for (final f in j['features'] as List) f is Map ? f['properties'] : null];
  } else if (j is List) {
    items = j;
  } else {
    throw const TableError('thematic_file_bad');
  }
  final columns = <String>[];
  for (final o in items) {
    if (o is! Map) throw const TableError('thematic_file_bad');
    for (final k in o.keys) {
      if (!columns.contains('$k')) columns.add('$k');
    }
  }
  return ThematicTable(columns, [
    for (final o in items.cast<Map<dynamic, dynamic>>())
      [
        for (final c in columns)
          switch (o[c]) {
            null => null,
            final v => '$v',
          },
      ],
  ]);
}

ThematicTable _readCsv(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).first;
  int count(String d) => d.allMatches(firstLine.replaceAll(RegExp(r'"[^"]*"'), '')).length;
  final delimiter = [';', '\t', ','].reduce((a, b) => count(b) > count(a) ? b : a);
  final records = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == delimiter) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((c) => c.trim().isNotEmpty)) records.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  row.add(cell.toString());
  if (row.any((c) => c.trim().isNotEmpty)) records.add(row);
  if (records.isEmpty) throw const TableError('thematic_file_empty');
  final columns = [for (final c in records.first) c.trim()];
  return ThematicTable(columns, [
    for (final r in records.skip(1))
      [
        for (var i = 0; i < columns.length; i++)
          switch (i < r.length ? r[i].trim() : '') {
            '' => null,
            final v => v,
          },
      ],
  ]);
}

final _spaces = RegExp(r'[\s  ]');
const _noData = {'-', '—', 'na', 'n/a', 'nan', 'null', '..', '...'};

/// A cell as a number: spaces between thousands, and a decimal comma when there is no point, are allowed.
/// Null for no data ('', '-', 'NA', ...); NaN when the cell isn't a number.
double? parseNumber(String? cell) {
  if (cell == null) return null;
  var t = cell.replaceAll(_spaces, '');
  if (t.isEmpty || _noData.contains(t.toLowerCase())) return null;
  if (!t.contains('.') && RegExp(r'^-?\d+,\d+$').hasMatch(t)) t = t.replaceFirst(',', '.');
  if (RegExp(r'^-?\d{1,3}(,\d{3})+(\.\d+)?$').hasMatch(t)) t = t.replaceAll(',', '');
  return double.tryParse(t) ?? double.nan;
}

/// Columns whose every cell is a number or no data, with one number at least.
List<int> numericColumns(ThematicTable t) => [
  for (var c = 0; c < t.columns.length; c++)
    if (t.rows.any((r) => parseNumber(r[c]) != null) && t.rows.every((r) => !(parseNumber(r[c])?.isNaN ?? false))) c,
];

final _unitWords = RegExp(
  r'(?<!\p{L})(municipality|region|city|town|მუნიციპალიტეტი|მხარე|ქალაქი|თვითმმართველი|ავტონომიური|რესპუბლიკა)(?!\p{L})',
  unicode: true,
);

String _key(String name) => normaliseName(name.toLowerCase().replaceAll(_unitWords, ' '));

/// The units a name may mean: the unit whose id, Georgian or English name it is, words like "municipality"
/// or "მხარე" aside. Georgian forms like "აბაშის" don't match "აბაშა": the teacher picks those by hand.
Map<String, String> unitKeys(List<GeoUnit> units) => {
  for (final u in units) ...{_key(u.id): u.id, _key(u.ka): u.id, _key(u.en): u.id},
  for (final u in units)
    if (u.id.startsWith('ge_m_'))
      _key(u.id.substring(5)): u.id
    else if (u.id.startsWith('ge_'))
      _key(u.id.substring(3)): u.id,
};

/// The column most of whose cells name a unit, and each row's unit (null where none, or one named before).
({int column, List<String?> units}) matchUnits(ThematicTable t, List<GeoUnit> units) {
  final keys = unitKeys(units);
  var best = 0, bestCount = -1;
  for (var c = 0; c < t.columns.length; c++) {
    final n = t.rows.where((r) => r[c] != null && keys.containsKey(_key(r[c]!))).length;
    if (n > bestCount) {
      best = c;
      bestCount = n;
    }
  }
  return (column: best, units: matchColumn(t, best, units));
}

List<String?> matchColumn(ThematicTable t, int column, List<GeoUnit> units) {
  final keys = unitKeys(units);
  final seen = <String>{};
  return [
    for (final r in t.rows)
      switch (r[column] == null ? null : keys[_key(r[column]!)]) {
        final id? when seen.add(id) => id,
        _ => null,
      },
  ];
}

/// The settings a table makes: the matched rows' units, and the chosen columns as fields, rounded to 6
/// significant figures to keep the session small.
ThematicSettings settingsFrom({
  required ThematicTable table,
  required String level,
  required String title,
  required String mode,
  required List<String?> rowUnits,
  required List<int> columns,
  required List<String> kinds,
  ThematicChoice? target,
}) {
  final rows = [
    for (var i = 0; i < table.rows.length; i++)
      if (rowUnits[i] != null) i,
  ];
  double? round(double? v) => v == null || v == 0 ? v : double.parse(v.toStringAsPrecision(6));
  return ThematicSettings(
    level: level,
    title: title,
    mode: mode,
    units: [for (final i in rows) rowUnits[i]!],
    fields: [
      for (var k = 0; k < columns.length; k++)
        ThematicField(table.columns[columns[k]], kinds[k], [
          for (final i in rows) round(parseNumber(table.rows[i][columns[k]])),
        ]),
    ],
    target: target,
  );
}

/// The sample table: every unit's area, so a teacher can try the game without a file of their own.
String sampleCsv(List<GeoUnit> units, String lang) {
  final out = StringBuffer(lang == 'ka' ? 'ერთეული,ფართობი_კვკმ\n' : 'unit,area_sq_km\n');
  for (final u in units) {
    out.write('"${u.name(lang)}",${unitAreaKm2(u).toStringAsFixed(1)}\n');
  }
  return out.toString();
}
