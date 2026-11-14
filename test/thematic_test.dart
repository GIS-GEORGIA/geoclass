import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/puzzle.dart';
import 'package:geoclass/thematic/ramps.dart';
import 'package:geoclass/thematic/thematic.dart';

void main() {
  final expected = jsonDecode(File('test/fixtures/thematic/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final units = parseGeoUnits(File('assets/ge_units.json').readAsStringSync());
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  test('every unit\'s area matches PROJ\'s geod on the WGS84 ellipsoid to 0.05 %', () {
    final areas = (expected['areas'] as Map<String, dynamic>).cast<String, num>();
    expect(areas, hasLength(units.regions.length + units.municipalities.length));
    for (final u in [...units.regions, ...units.municipalities]) {
      expect(unitAreaKm2(u), closeTo(areas[u.id]!.toDouble(), areas[u.id]! * 5e-4), reason: u.id);
    }
    // Tbilisi is 504 km² by the official figure.
    expect(unitAreaKm2(units.region('ge_tbilisi')!), closeTo(504, 504 * 0.01));
  });

  double sse(List<double> values, List<double> uppers) {
    var total = 0.0;
    for (var c = 0; c < uppers.length; c++) {
      final members = [
        for (final v in values)
          if (classOf(v, uppers) == c) v,
      ];
      if (members.isEmpty) continue;
      final mean = members.reduce((a, b) => a + b) / members.length;
      total += members.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b);
    }
    return total;
  }

  test('equal interval and quantile breaks are QGIS\'s; Jenks reaches the exact optimum, never worse than QGIS', () {
    for (final MapEntry(key: name, value: d as Map<String, dynamic>)
        in (expected['classes'] as Map<String, dynamic>).entries) {
      final values = [for (final v in d['values'] as List) (v as num).toDouble()];
      for (var k = 3; k <= 7; k++) {
        for (final method in ['equal', 'quantile']) {
          final want = [for (final b in (d[method] as Map<String, dynamic>)['$k'] as List) (b as num).toDouble()];
          final got = classBreaks(values, method, k);
          expect(got.length, want.length, reason: '$name $method $k');
          for (var i = 0; i < want.length; i++) {
            expect(got[i], closeTo(want[i], 1e-9 * (1 + want[i].abs())), reason: '$name $method $k #$i');
          }
        }
        final jenks = classBreaks(values, 'jenks', k);
        expect(jenks, hasLength(k));
        expect(jenks.last, values.reduce((a, b) => a > b ? a : b));
        final best = ((d['jenks_sse'] as Map<String, dynamic>)['$k'] as num).toDouble();
        final qgis = ((d['qgis_jenks_sse'] as Map<String, dynamic>)['$k'] as num).toDouble();
        expect(sse(values, jenks), closeTo(best, 1e-6 * (1 + best)), reason: '$name jenks $k');
        expect(sse(values, jenks), lessThanOrEqualTo(qgis + 1e-6 * (1 + qgis)), reason: '$name jenks $k');
      }
    }
    expect(classOf(1, [1, 5, 9]), 0);
    expect(classOf(1.01, [1, 5, 9]), 1);
    expect(classOf(9, [1, 5, 9]), 2);
  });

  test('the ramps are QGIS\'s ColorBrewer colours', () {
    final ramps = expected['ramps'] as Map<String, dynamic>;
    expect(thematicRamps.keys, ramps.keys);
    for (final MapEntry(key: name, value: ks as Map<String, dynamic>) in ramps.entries) {
      for (var k = 3; k <= 7; k++) {
        final want = [for (final c in ks['$k'] as List) int.parse('ff${(c as String).substring(1)}', radix: 16)];
        expect([for (final c in thematicRamps[name]![k]!) c.toARGB32()], want, reason: '$name $k');
      }
    }
  });

  test('a CSV is read with any delimiter, quotes, a BOM and gaps; numbers in several ways', () {
    final t = readTable(bytes('﻿name;"people, 2024";share\r\n"Abasha";21 500;"1,5"\r\nAdigeni;-;2\r\n\r\n'), 'a.csv');
    expect(t.columns, ['name', 'people, 2024', 'share']);
    expect(t.rows, [
      ['Abasha', '21 500', '1,5'],
      ['Adigeni', '-', '2'],
    ]);
    expect(parseNumber('21 500'), 21500);
    expect(parseNumber('1,5'), 1.5);
    expect(parseNumber('1,234,567.5'), 1234567.5);
    expect(parseNumber('-'), isNull);
    expect(parseNumber('NA'), isNull);
    expect(parseNumber('abc'), isNaN);
    expect(numericColumns(t), [1, 2]);
    final tab = readTable(bytes('a\tb\nx\t1\n'), 'a.tsv');
    expect(tab.rows.single, ['x', '1']);
  });

  test('a JSON array and a GeoJSON FeatureCollection give their properties; bad files say why', () {
    final j = readTable(bytes('[{"n":"Guria","v":3},{"n":"Adjara","v":null,"w":1}]'), 'a.json');
    expect(j.columns, ['n', 'v', 'w']);
    expect(j.rows, [
      ['Guria', '3', null],
      ['Adjara', null, '1'],
    ]);
    final g = readTable(
      bytes(
        '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":null,"properties":{"n":"Guria","v":3}}]}',
      ),
      'a.geojson',
    );
    expect(g.rows.single, ['Guria', '3']);
    Matcher fails(String key) => throwsA(isA<TableError>().having((e) => e.key, 'key', key));
    expect(() => readTable(Uint8List.fromList([0xff, 0xfe, 0x41]), 'a.csv'), fails('thematic_file_encoding'));
    expect(() => readTable(Uint8List(thematicFileMax + 1), 'a.csv'), fails('thematic_file_big'));
    expect(() => readTable(bytes('only\n1\n'), 'a.csv'), fails('thematic_file_empty'));
    expect(() => readTable(bytes('a,b\n${'x,1\n' * (thematicRowsMax + 1)}'), 'a.csv'), fails('thematic_file_rows'));
    expect(() => readTable(bytes('{"a":1}'), 'a.json'), fails('thematic_file_bad'));
  });

  test('names are matched to units by id, Georgian or English name, words like "municipality" aside', () {
    final t = readTable(
      bytes(
        'code,unit,v\n1,Abasha Municipality,1\n2,ადიგენის მუნიციპალიტეტი,2\n3,ახალქალაქი,3\n4,ge_m_akhmeta,4\n5,Nowhere,5\n6,abasha,6\n',
      ),
      'a.csv',
    );
    final m = matchUnits(t, units.municipalities);
    expect(m.column, 1);
    // "ადიგენის" is the genitive of "ადიგენი": picked by hand. A unit named twice counts once.
    expect(m.units, ['ge_m_abasha', null, 'ge_m_akhalkalaki', 'ge_m_akhmeta', null, null]);
    final s = settingsFrom(
      table: t,
      level: 'municipalities',
      title: 'Test',
      mode: 'free',
      rowUnits: m.units,
      columns: [2],
      kinds: ['count'],
    );
    expect(s.units, ['ge_m_abasha', 'ge_m_akhalkalaki', 'ge_m_akhmeta']);
    expect(s.fields.single.values, [1, 3, 4]);
    expect(ThematicSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>).toJson(), s.toJson());
  });

  test('classify: per km², the classes and their counts; no data stays out', () {
    const s = ThematicSettings(
      level: 'regions',
      title: '',
      mode: 'target',
      units: ['a', 'b', 'c', 'd'],
      fields: [
        ThematicField('people', 'count', [100, 200, null, 400]),
      ],
    );
    final areas = [10.0, 10.0, 10.0, 100.0];
    final c = classify(s, const ThematicChoice(field: 0, normalise: 'area', method: 'equal', classes: 3), areas)!;
    expect(c.values, [10, 20, null, 4]);
    expect(c.uppers, [closeTo(28 / 3, 1e-9), closeTo(44 / 3, 1e-9), 20]);
    expect(c.classOfUnit, [1, 2, null, 0]);
    expect(c.counts, [1, 1, 1]);
    final manual = classify(
      s,
      const ThematicChoice(field: 0, method: 'manual', classes: 3, breaks: [150, 300]),
      areas,
    )!;
    expect(manual.uppers, [150, 300, 400]);
    expect(manual.classOfUnit, [0, 1, null, 2]);
    const target = ThematicChoice(field: 0, normalise: 'area', method: 'jenks', classes: 5);
    expect(thematicScore(target, target), 100);
    expect(thematicScore(target, const ThematicChoice(field: 0, method: 'jenks', classes: 4)), 50);
    expect(legendNumber(1234), '1234');
    expect(legendNumber(12.345), '12.3');
    expect(legendNumber(0.01234), '0.012');
  });

  test('the sample: every unit with its area, and it reads back and matches', () {
    final csv = sampleCsv(units.regions, 'ka');
    final t = readTable(bytes(csv), 'sample.csv');
    final m = matchUnits(t, units.regions);
    expect(m.units, everyElement(isNotNull));
    expect(numericColumns(t), [1]);
  });
}
