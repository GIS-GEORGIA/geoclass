import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/export.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/main.dart';
import 'package:geoclass/models.dart';
import 'package:geoclass/places.dart';
import 'package:geoclass/queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

TravelAnswer answer({
  String place = 'Paris',
  String country = 'FR',
  String reason = 'Art',
  String transport = 'plane',
  bool hidden = false,
}) =>
    TravelAnswer(
      id: 'id-$place',
      place: place,
      country: country,
      reason: reason,
      transport: transport,
      company: 'friends',
      lat: 48.85,
      lon: 2.35,
      hidden: hidden,
      createdAt: 1790000000,
    );

void main() {
  group('translations', () {
    test('both languages have the same keys', () {
      final ka = S.keys['ka']!.keys.toSet();
      final en = S.keys['en']!.keys.toSet();
      expect(ka.difference(en), isEmpty);
      expect(en.difference(ka), isEmpty);
    });

    test('every transport and company has a label', () {
      for (final lang in ['ka', 'en']) {
        for (final t in transports) {
          expect(S.keys[lang]!.containsKey('transport_$t'), isTrue);
        }
        for (final c in companies) {
          expect(S.keys[lang]!.containsKey('company_$c'), isTrue);
        }
      }
    });
  });

  group('join link', () {
    test('finds the token', () {
      expect(joinToken('/join/abc_DEF-123'), 'abc_DEF-123');
    });
    test('ignores other routes', () {
      expect(joinToken('/'), isNull);
      expect(joinToken(null), isNull);
      expect(joinToken('/join/'), isNull);
      expect(joinToken('/join/a/b'), isNull);
    });
  });

  group('export', () {
    test('CSV keeps Georgian, quotes and new lines, with a BOM', () {
      final csv = answersToCsv([answer(place: 'თბილისი', reason: 'say "hi"\nnow')]);
      expect(csv.startsWith('﻿place,'), isTrue);
      expect(csv, contains('"თბილისი"'));
      expect(csv, contains('"say ""hi""\nnow"'));
    });

    test('CSV cannot carry a spreadsheet formula', () {
      for (final bad in ['=1+1', '+1', '-1', '@x']) {
        expect(answersToCsv([answer(reason: bad)]), contains('"\'$bad"'));
      }
    });

    test('GeoJSON is lon, lat', () {
      final data = jsonDecode(answersToGeoJson([answer()])) as Map<String, dynamic>;
      expect(data['type'], 'FeatureCollection');
      final feature = (data['features'] as List).single as Map<String, dynamic>;
      expect(feature['geometry']['coordinates'], [2.35, 48.85]);
      expect(feature['properties']['place'], 'Paris');
    });

    test('counts skip hidden answers and sort by size', () {
      final counts = countBy([
        answer(place: 'Rome'),
        answer(place: 'Paris'),
        answer(place: 'Paris'),
        answer(place: 'Oslo', hidden: true),
      ], (a) => a.place);
      expect(counts.map((e) => e.key), ['Paris', 'Rome']);
      expect(counts.first.value, 2);
    });
  });

  group('places', () {
    final index = PlaceIndex.parse(
      'Tokyo\tტოკიო\tJP\t35.690\t139.692\n'
      'Paris\tპარიზი\tFR\t48.853\t2.349\n'
      'São Paulo\t\tBR\t-23.548\t-46.636\n'
      'Comparis\t\tFR\t45.000\t3.000\n',
      {
        'FR': ['France', 'საფრანგეთი'],
      },
    );

    test('finds Latin and Georgian names', () {
      expect(index.search('par').first.name, 'Paris');
      expect(index.search('პარიზ').single.name, 'Paris');
    });

    test('ignores accents', () {
      expect(index.search('sao paulo').single.name, 'São Paulo');
    });

    test('names that start with the query come first', () {
      expect(index.search('paris').map((p) => p.name), ['Paris', 'Comparis']);
    });

    test('ignores one letter', () {
      expect(index.search('p'), isEmpty);
    });

    test('finds the nearest place, across the date line too', () {
      expect(index.nearest(48, 3)!.name, 'Paris');
      expect(index.nearest(35, -179)!.name, 'Tokyo');
    });

    test('names follow the language', () {
      final paris = index.search('paris').first;
      expect(paris.label('ka'), 'პარიზი');
      expect(paris.label('en'), 'Paris');
      expect(index.countryName('FR', 'ka'), 'საფრანგეთი');
      expect(index.countryName('XX', 'en'), 'XX');
    });
  });

  group('offline queue', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps answers while offline and sends them in order later', () async {
      final sent = <String>[];
      var online = false;
      final queue = SubmissionQueue((item) async {
        if (!online) throw NoConnection();
        sent.add(item['submissionId'] as String);
      });
      await queue.add({'submissionId': 'a'});
      await queue.add({'submissionId': 'b'});

      expect(await queue.flush(), isNull);
      expect(await queue.pending(), 2);
      expect(sent, isEmpty);

      online = true;
      await queue.flush();
      expect(sent, ['a', 'b']);
      expect(await queue.pending(), 0);
    });

    test('survives a restart', () async {
      final first = SubmissionQueue((_) async => throw NoConnection());
      await first.add({'submissionId': 'a'});
      await first.flush();
      final second = SubmissionQueue((_) async {});
      expect(await second.pending(), 1);
    });

    test('drops an answer the server refuses, and reports why', () async {
      final queue = SubmissionQueue((_) async => throw ApiError(409, 'session_closed'));
      await queue.add({'submissionId': 'a'});
      expect(await queue.flush(), 'session_closed');
      expect(await queue.pending(), 0);
    });

    test('keeps an answer on a server failure or rate limit', () async {
      for (final status in [429, 500, 503]) {
        SharedPreferences.setMockInitialValues({});
        final queue = SubmissionQueue((_) async => throw ApiError(status, 'x'));
        await queue.add({'submissionId': 'a'});
        await queue.flush();
        expect(await queue.pending(), 1);
      }
    });

    test('participant id stays the same on one device', () async {
      final a = await participantId();
      expect(await participantId(), a);
      expect(a.length, greaterThanOrEqualTo(8));
      expect(RegExp(r'^[A-Za-z0-9_-]+=*$').hasMatch(a), isTrue);
    });
  });
}
