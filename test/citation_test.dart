import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/citation.dart';

void main() {
  test('the in-app citation matches CITATION.cff and pubspec', () {
    final cff = File('CITATION.cff').readAsStringSync();
    final version = RegExp(
      r'^version: (\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
    expect(cff, contains('version: $version'));
    expect(citationApa, contains('Version $version'));
    expect(citationBibtex, contains('version     = {$version}'));
    for (final text in [cff, citationApa, citationBibtex]) {
      expect(text, contains('Kapanadze'));
      expect(text, contains('https://github.com/GIS-GEORGIA/geoclass'));
    }
  });
}
