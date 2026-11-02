import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

class Place {
  final String name, ka, country;
  final double lat, lon;
  const Place(this.name, this.ka, this.country, this.lat, this.lon);

  String label(String lang) => lang == 'ka' && ka.isNotEmpty ? ka : name;
}

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ě': 'e', 'ę': 'e',
  'ğ': 'g', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ı': 'i', 'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ō': 'o', 'ő': 'o', 'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ș': 's',
  'ť': 't', 'ț': 't', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u', 'ý': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
};

String normalize(String text) {
  final lower = text.toLowerCase().trim();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    out.write(_accents[ch] ?? ch);
  }
  return out.toString();
}

/// Offline place search, bundled with the app (GeoNames, sorted by population).
class PlaceIndex {
  final List<Place> places;
  final List<String> _names;
  final List<String> _kaNames;
  final Map<String, List<String>> countries;

  PlaceIndex(this.places, this.countries)
      : _names = [for (final p in places) normalize(p.name)],
        _kaNames = [for (final p in places) p.ka];

  static PlaceIndex parse(String tsv, Map<String, List<String>> countries) {
    final places = <Place>[];
    for (final line in const LineSplitter().convert(tsv)) {
      final f = line.split('\t');
      if (f.length < 5) continue;
      places.add(Place(f[0], f[1], f[2], double.parse(f[3]), double.parse(f[4])));
    }
    return PlaceIndex(places, countries);
  }

  static Future<PlaceIndex>? _loading;

  /// Loaded on first use, so opening the form doesn't pay for it.
  static Future<PlaceIndex> load() => _loading ??= () async {
        final tsv = await rootBundle.loadString('assets/places.tsv');
        final raw = jsonDecode(await rootBundle.loadString('assets/countries.json')) as Map<String, dynamic>;
        return parse(tsv, {for (final e in raw.entries) e.key: (e.value as List).cast<String>()});
      }();

  String countryName(String code, String lang) {
    final names = countries[code];
    if (names == null) return code;
    return lang == 'ka' ? names[1] : names[0];
  }

  /// Names starting with the query come first, then names containing it.
  List<Place> search(String query, {int limit = 8}) {
    final q = normalize(query);
    if (q.length < 2) return const [];
    final starts = <Place>[];
    final contains = <Place>[];
    for (var i = 0; i < places.length && starts.length < limit; i++) {
      final name = _names[i];
      final ka = _kaNames[i];
      if (name.startsWith(q) || ka.startsWith(q)) {
        starts.add(places[i]);
      } else if (contains.length < limit && (name.contains(q) || ka.contains(q))) {
        contains.add(places[i]);
      }
    }
    return [...starts, ...contains].take(limit).toList();
  }

  /// Closest listed place to a point tapped on the map.
  Place? nearest(double lat, double lon) {
    Place? best;
    var bestDistance = double.infinity;
    final cosLat = math.cos(lat * math.pi / 180);
    for (final p in places) {
      final dLat = p.lat - lat;
      var dLon = (p.lon - lon).abs();
      if (dLon > 180) dLon = 360 - dLon;
      dLon *= cosLat;
      final d = dLat * dLat + dLon * dLon;
      if (d < bestDistance) {
        bestDistance = d;
        best = p;
      }
    }
    return best;
  }
}
