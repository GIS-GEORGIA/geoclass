import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

// --- Distance and score. worker/src/validate.ts has the same formulas and decides the real score. ---

double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad;
  final dLon = (lon2 - lon1) * rad;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371008.8 * math.asin(math.min(1.0, math.sqrt(a)));
}

/// 100 within 1 km, 50 at 10 km, 0 from 100 km.
int scoreFor(double distance) {
  if (distance <= 1000) return 100;
  if (distance >= 100000) return 0;
  return (100 * (1 - (math.log(distance / 1000) / math.ln10) / 2)).round();
}

String formatDistance(double metres) =>
    metres < 1000 ? '${metres.round()} m' : '${(metres / 1000).toStringAsFixed(metres < 10000 ? 2 : 1)} km';

// --- UTM (WGS84, northern hemisphere) ---

class Utm {
  final int zone;
  final double easting, northing;
  const Utm(this.zone, this.easting, this.northing);
}

final _wgs84 = proj4.Projection.get('EPSG:4326')!;
final _zones = <int, proj4.Projection>{};

proj4.Projection _utm(int zone) => _zones.putIfAbsent(
      zone,
      () => proj4.Projection.parse('+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'),
    );

/// Georgia falls in zones 37 (west of 42°E) and 38.
int utmZone(double lon) => ((lon + 180) / 6).floor() % 60 + 1;

Utm toUtm(double lat, double lon, {int? zone}) {
  final z = zone ?? utmZone(lon);
  final p = _wgs84.transform(_utm(z), proj4.Point(x: lon, y: lat));
  return Utm(z, p.x, p.y);
}

LatLng fromUtm(int zone, double easting, double northing) {
  final p = _utm(zone).transform(_wgs84, proj4.Point(x: easting, y: northing));
  return LatLng(p.y, p.x);
}

// --- Writing coordinates ---

String formatDd(double lat, double lon) => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

String _dms(double value, String positive, String negative) {
  final seconds = (value.abs() * 3600).round();
  final d = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = '$m'.padLeft(2, '0');
  final ss = '$s'.padLeft(2, '0');
  return '$d°$mm′$ss″ ${value < 0 ? negative : positive}';
}

String _dm(double value, String positive, String negative) {
  final thousandths = (value.abs() * 60000).round();
  final d = thousandths ~/ 60000;
  final m = (thousandths % 60000 / 1000).toStringAsFixed(3).padLeft(6, '0');
  return '$d°$m′ ${value < 0 ? negative : positive}';
}

String formatDm(double lat, double lon) => '${_dm(lat, 'N', 'S')}, ${_dm(lon, 'E', 'W')}';

String formatDms(double lat, double lon) => '${_dms(lat, 'N', 'S')}, ${_dms(lon, 'E', 'W')}';

/// A grid line's label, only as long as it needs to be: 41°, 41°40′ or 41°40′30″.
String dmsTick(double value) {
  final seconds = (value.abs() * 3600).round();
  final d = seconds ~/ 3600;
  final m = '${(seconds % 3600) ~/ 60}'.padLeft(2, '0');
  final s = '${seconds % 60}'.padLeft(2, '0');
  final sign = value < 0 ? '-' : '';
  if (seconds % 60 != 0) return '$sign$d°$m′$s″';
  return seconds % 3600 != 0 ? '$sign$d°$m′' : '$sign$d°';
}

/// A grid line's label in degrees and decimal minutes: 41°, 41°40′ or 41°40.5′.
String dmTick(double value) {
  final thousandths = (value.abs() * 60000).round();
  final d = thousandths ~/ 60000;
  final m = thousandths % 60000;
  final sign = value < 0 ? '-' : '';
  if (m == 0) return '$sign$d°';
  final text = (m / 1000).toString().replaceFirst(RegExp(r'\.0$'), '');
  return '$sign$d°${m < 10000 ? '0' : ''}$text′';
}

/// Writes the boxes of the answer frame as one answer, or '' when a required box is empty.
/// dd: lat, lon. dm: degrees, minutes twice. dms: degrees, minutes, seconds twice. utm: easting, northing.
/// Empty minutes or seconds count as 0, and a decimal comma counts as a point.
String joinBoxes(String format, List<String> boxes, {bool south = false, bool west = false, int? zone}) {
  final b = boxes.map((v) => v.trim().replaceAll(',', '.')).toList();
  final ns = south ? 'S' : 'N';
  final ew = west ? 'W' : 'E';
  String two(String v) => (v.isEmpty ? '0' : v).padLeft(2, '0');
  switch (format) {
    case 'dms':
      if (b[0].isEmpty || b[3].isEmpty) return '';
      return '${b[0]}°${two(b[1])}′${two(b[2])}″ $ns, ${b[3]}°${two(b[4])}′${two(b[5])}″ $ew';
    case 'dm':
      if (b[0].isEmpty || b[2].isEmpty) return '';
      return '${b[0]}°${two(b[1])}′ $ns, ${b[2]}°${two(b[3])}′ $ew';
    case 'utm':
      if (b[0].isEmpty || b[1].isEmpty) return '';
      return '${zone}N ${b[0]} ${b[1]}';
    default:
      if (b[0].isEmpty || b[1].isEmpty) return '';
      return '${b[0]} $ns, ${b[1]} $ew';
  }
}

String formatUtm(double lat, double lon) {
  final u = toUtm(lat, lon);
  return '${u.zone}N ${u.easting.round()} ${u.northing.round()}';
}

String formatAs(String format, double lat, double lon) => switch (format) {
      'dms' => formatDms(lat, lon),
      'dm' => formatDm(lat, lon),
      'utm' => formatUtm(lat, lon),
      _ => formatDd(lat, lon),
    };

// --- Reading what a student or teacher typed. Returns null when it can't be understood. ---

LatLng? _valid(double lat, double lon) =>
    lat.abs() <= 90 && lon.abs() <= 180 ? LatLng(lat, lon) : null;

List<double> _numbers(String text) =>
    RegExp(r'\d+(?:\.\d+)?').allMatches(text).map((m) => double.parse(m.group(0)!)).toList();

/// "41.69, 44.80", "41.69 44.80" and "41,69 44,80".
LatLng? parseDd(String text) {
  var t = text.trim();
  if (!t.contains('.') && ','.allMatches(t).length >= 2) t = t.replaceAll(',', '.');
  final m = RegExp(r'^(-?\d+(?:\.\d+)?)°?\s*([NSns])?\s*[,;\s]\s*(-?\d+(?:\.\d+)?)°?\s*([EWew])?$').firstMatch(t);
  if (m == null) return null;
  var lat = double.parse(m.group(1)!);
  var lon = double.parse(m.group(3)!);
  if (m.group(2)?.toUpperCase() == 'S') lat = -lat;
  if (m.group(4)?.toUpperCase() == 'W') lon = -lon;
  return _valid(lat, lon);
}

/// Degrees, minutes and seconds in any common writing: 41°41′38″ N, 44°48′05″ E or 41 41 38 44 48 5.
/// Degrees and decimal minutes also work: 41 41.63 44 48.08.
LatLng? parseDms(String text) {
  final t = text.toUpperCase();
  final n = _numbers(t);
  final double lat, lon;
  if (n.length == 6) {
    if (n[1] >= 60 || n[2] >= 60 || n[4] >= 60 || n[5] >= 60) return null;
    lat = n[0] + n[1] / 60 + n[2] / 3600;
    lon = n[3] + n[4] / 60 + n[5] / 3600;
  } else if (n.length == 4) {
    if (n[1] >= 60 || n[3] >= 60) return null;
    lat = n[0] + n[1] / 60;
    lon = n[2] + n[3] / 60;
  } else {
    return null;
  }
  return _valid(t.contains('S') ? -lat : lat, t.contains('W') ? -lon : lon);
}

/// "38N 483482 4615799" or, with a zone known from the task, "483482 4615799".
LatLng? parseUtm(String text, {int? zone}) {
  final t = text.trim();
  final full = RegExp(r'^(\d{1,2})\s*[A-Za-z]?[\s,;]+(\d+(?:\.\d+)?)[\s,;]+(\d+(?:\.\d+)?)$').firstMatch(t);
  final bare = RegExp(r'^(\d+(?:\.\d+)?)[\s,;]+(\d+(?:\.\d+)?)$').firstMatch(t);
  final int z;
  final double e, n;
  if (full != null) {
    z = int.parse(full.group(1)!);
    e = double.parse(full.group(2)!);
    n = double.parse(full.group(3)!);
  } else if (bare != null && zone != null) {
    z = zone;
    e = double.parse(bare.group(1)!);
    n = double.parse(bare.group(2)!);
  } else {
    return null;
  }
  if (z < 1 || z > 60 || e < 100000 || e > 900000 || n < 0 || n > 10000000) return null;
  return fromUtm(z, e, n);
}

LatLng? parseAs(String format, String text, {int? zone}) => switch (format) {
      'dms' || 'dm' => parseDms(text),
      'utm' => parseUtm(text, zone: zone),
      _ => parseDd(text),
    };

/// One latitude or longitude: 41.6938, 41 41.63, 41°41′38″ N or 41,6938. S, W or a minus make it negative.
double? parseOne(String text) {
  final t = text.trim().toUpperCase().replaceAll(',', '.');
  final n = _numbers(t);
  if (n.isEmpty || n.length > 3) return null;
  if (n.length > 1 && (n[0] != n[0].truncateToDouble() || n[1] >= 60)) return null;
  if (n.length > 2 && (n[1] != n[1].truncateToDouble() || n[2] >= 60)) return null;
  final value = n[0] + (n.length > 1 ? n[1] / 60 : 0) + (n.length > 2 ? n[2] / 3600 : 0);
  return t.startsWith('-') || t.contains('S') || t.contains('W') ? -value : value;
}

/// For the teacher's box, which takes any format.
LatLng? parseAny(String text) => parseDd(text) ?? parseUtm(text) ?? parseDms(text);

// --- Opening a point elsewhere ---

Uri googleMapsUrl(double lat, double lon) =>
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon');

Uri osmUrl(double lat, double lon) =>
    Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=15/$lat/$lon');
