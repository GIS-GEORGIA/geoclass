import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../api.dart';

/// Time-lapse: what changed between two years, seen from a satellite.
///
/// The frames (one clear summer picture a year, Landsat to 2016 and Sentinel-2 from 2017, all on one grid per
/// site) are built by tool/timelapse/build_timelapse.py and served under /timelapse/. The teacher outlines what
/// is to be found on two years as a template; the student draws the same and is scored by the server
/// (worker/src/games/timelapse.ts): the mean of the two years' IoU × 100. The IoU and the areas are worked out
/// here the same way, for the student's and the teacher's pages; test/fixtures/timelapse/iou.json holds
/// GDAL/OGR's IoU and PROJ's geodesic areas for both sides to agree with.

/// An outline: rings of points, each a polygon without holes; together one shape (overlaps count once).
typedef Outline = List<List<LatLng>>;

const maxTruthRings = 20, maxTruthVertices = 300;
const maxAnswerRings = 10, maxAnswerVertices = 100;

Outline outlineFromJson(Object? raw) => [
  for (final ring in raw as List)
    [for (final p in ring as List) LatLng(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
];

/// Six decimals (a few centimetres), as the server keeps them.
List<List<List<double>>> outlineToJson(Outline o) => [
  for (final ring in o)
    [
      for (final p in ring) [_round6(p.latitude), _round6(p.longitude)],
    ],
];

double _round6(double v) => (v * 1e6).round() / 1e6;

int vertexCount(Outline o) => o.fold(0, (n, r) => n + r.length);

// --- The sums: the same lines across both outlines as the server ---

typedef _Span = (double, double);

/// The parts of the horizontal line at y inside an outline, as sorted, separate spans.
List<_Span> _spans(List<List<(double, double)>> rings, double y) {
  final out = <_Span>[];
  for (final ring in rings) {
    final xs = <double>[];
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final (x1, y1) = ring[j];
      final (x2, y2) = ring[i];
      // Half-open, so a line through a vertex crosses once.
      if ((y1 <= y) != (y2 <= y)) xs.add(x1 + (y - y1) / (y2 - y1) * (x2 - x1));
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      out.add((xs[k], xs[k + 1]));
    }
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <_Span>[];
  for (final s in out) {
    if (merged.isNotEmpty && s.$1 <= merged.last.$2) {
      merged.last = (merged.last.$1, math.max(merged.last.$2, s.$2));
    } else {
      merged.add(s);
    }
  }
  return merged;
}

double _length(List<_Span> s) => s.fold(0.0, (t, x) => t + x.$2 - x.$1);

double _overlap(List<_Span> a, List<_Span> b) {
  var t = 0.0;
  for (var i = 0, j = 0; i < a.length && j < b.length;) {
    t += math.max(0, math.min(a[i].$2, b[j].$2) - math.max(a[i].$1, b[j].$1));
    if (a[i].$2 < b[j].$2) {
      i++;
    } else {
      j++;
    }
  }
  return t;
}

/// The middle of an outline's extent, the origin of the flat projection both sides use.
(double, double) _middle(Outline o) {
  final pts = o.expand((r) => r);
  final lats = pts.map((p) => p.latitude), lons = pts.map((p) => p.longitude);
  return ((lats.reduce(math.min) + lats.reduce(math.max)) / 2, (lons.reduce(math.min) + lons.reduce(math.max)) / 2);
}

List<List<(double, double)>> _project(Outline o, double lat0, double lon0) {
  final k = math.cos(lat0 * math.pi / 180);
  return [
    for (final r in o) [for (final p in r) ((p.longitude - lon0) * k, p.latitude - lat0)],
  ];
}

/// The IoU of two outlines, 0 to 1, as worker/src/games/timelapse.ts's iou: on a local flat projection about
/// the truth's middle, on [rows] horizontal lines across both, exact along each line.
double iou(Outline truth, Outline answer, {int rows = 2000}) {
  if (truth.isEmpty || answer.isEmpty) return 0;
  final (lat0, lon0) = _middle(truth);
  final t = _project(truth, lat0, lon0), a = _project(answer, lat0, lon0);
  final ys = [...t, ...a].expand((r) => r).map((p) => p.$2);
  final y0 = ys.reduce(math.min);
  final dy = (ys.reduce(math.max) - y0) / rows;
  if (!(dy > 0)) return 0;
  var both = 0.0, either = 0.0;
  for (var r = 0; r < rows; r++) {
    final y = y0 + (r + 0.5) * dy;
    final st = _spans(t, y), sa = _spans(a, y);
    final o = _overlap(st, sa);
    both += o;
    either += _length(st) + _length(sa) - o;
  }
  return either > 0 ? both / either : 0;
}

/// The score of an answer, as the server gives it: the mean of the two IoUs × 100.
int scoreOf(double iouA, double iouB) => ((iouA + iouB) / 2 * 100).round();

// WGS 84: the radii of curvature that turn degrees into metres about a latitude.
const _a = 6378137.0, _e2 = 6.69437999014e-3;

/// The area an outline covers on the ground, in m² (overlapping rings once). The same lines as [iou], with
/// degrees turned into metres by the ellipsoid's radii at the outline's middle: over a site's few tens of
/// kilometres within 0.1 % of PROJ's geodesic area (test/timelapse_test.dart).
double outlineArea(Outline o, {int rows = 2000}) {
  if (o.isEmpty || vertexCount(o) < 3) return 0;
  final (lat0, lon0) = _middle(o);
  final p = _project(o, lat0, lon0);
  final ys = p.expand((r) => r).map((q) => q.$2);
  final y0 = ys.reduce(math.min);
  final dy = (ys.reduce(math.max) - y0) / rows;
  if (!(dy > 0)) return 0;
  var sum = 0.0;
  for (var r = 0; r < rows; r++) {
    sum += _length(_spans(p, y0 + (r + 0.5) * dy));
  }
  final phi = lat0 * math.pi / 180;
  final w = 1 - _e2 * math.sin(phi) * math.sin(phi);
  final m = _a * (1 - _e2) / math.pow(w, 1.5); // north-south, metres per radian
  final n = _a / math.sqrt(w); // east-west at the equator of the projection, metres per radian
  // x was scaled by cos(lat0) already, so both axes are in degrees of the meridian.
  final deg = math.pi / 180;
  return sum * dy * (m * deg) * (n * deg);
}

/// Areas as the page writes them: km² with two decimals.
String km2Text(double m2) => (m2 / 1e6).toStringAsFixed(2);

/// The change from year A to year B, as "+1.23 km² (+15 %)"; the per cent is left out when A is nothing.
String changeText(double a, double b) {
  final d = (b - a) / 1e6;
  final sign = d >= 0 ? '+' : '−';
  final abs = d.abs().toStringAsFixed(2);
  if (a <= 0) return '$sign$abs km²';
  final pct = ((b - a) / a * 100).round();
  return '$sign$abs km² (${pct >= 0 ? '+' : '−'}${pct.abs()} %)';
}

// --- The frames ---

String timelapseUrl(String path) => '$publicUrl/timelapse/$path';

/// One site of the catalog.
class TimelapseSite {
  final String id, ka, en, kind;
  final int version;
  final List<int> years;
  const TimelapseSite(this.id, this.version, this.ka, this.en, this.kind, this.years);

  factory TimelapseSite.fromJson(Map<String, dynamic> j) => TimelapseSite(
    j['id'] as String,
    (j['version'] as num).toInt(),
    j['ka'] as String? ?? j['id'] as String,
    j['en'] as String? ?? j['id'] as String,
    j['kind'] as String? ?? '',
    [for (final y in j['years'] as List) (y as num).toInt()],
  );
  String title(String lang) => lang == 'ka' ? ka : en;
}

class Frame {
  final int year, resolution;
  final String date, sensor, file;
  const Frame(this.year, this.date, this.sensor, this.resolution, this.file);
  factory Frame.fromJson(Map<String, dynamic> j) => Frame(
    (j['year'] as num).toInt(),
    j['date'] as String,
    j['sensor'] as String,
    (j['resolution'] as num).toInt(),
    j['file'] as String,
  );
}

/// A site's frames and where they lie: [corners] north-west, north-east, south-east, south-west.
class SiteFrames {
  final String id;
  final int version;
  final List<LatLng> corners;
  final List<Frame> frames;
  final List<String> attribution;
  const SiteFrames(this.id, this.version, this.corners, this.frames, this.attribution);

  factory SiteFrames.fromJson(Map<String, dynamic> j) => SiteFrames(
    j['id'] as String,
    (j['version'] as num).toInt(),
    [for (final c in j['corners'] as List) LatLng(((c as List)[0] as num).toDouble(), (c[1] as num).toDouble())],
    [for (final f in j['frames'] as List) Frame.fromJson(f as Map<String, dynamic>)]
      ..sort((a, b) => a.year.compareTo(b.year)),
    [for (final a in (j['attribution'] as List? ?? const [])) a as String],
  );

  Frame? frameOf(int year) => frames.where((f) => f.year == year).firstOrNull;
  String urlOf(Frame f) => timelapseUrl('$id/$version/${f.file}');
}

/// Reads the catalog and the sites' frames. Tests give their own.
class FrameLoader {
  final http.Client _client;
  FrameLoader([http.Client? client]) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await _client.get(Uri.parse(timelapseUrl(path))).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw ApiError(res.statusCode, 'timelapse_unavailable');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<TimelapseSite>> catalog() async => [
    for (final s in (await _get('catalog.json'))['sites'] as List) TimelapseSite.fromJson(s as Map<String, dynamic>),
  ];

  final _sites = <String, Future<SiteFrames>>{};

  /// A site's frames, read once; a failed read is tried again next time.
  Future<SiteFrames> site(String id, int version) {
    final key = '$id/$version';
    final cached = _sites[key];
    if (cached != null) return cached;
    final f = _get('$key/site.json').then(SiteFrames.fromJson);
    _sites[key] = f;
    f.then((_) {}, onError: (Object _) => _sites.remove(key));
    return f;
  }
}

// --- Templates ---

/// What a template holds: the site, two years and the teacher's outline on each.
class TimelapseData {
  final String site;
  final int version;
  final int yearA, yearB;
  final Outline truthA, truthB;
  const TimelapseData(this.site, this.version, this.yearA, this.yearB, this.truthA, this.truthB);

  factory TimelapseData.fromJson(Map<String, dynamic> j) {
    final years = j['years'] as List, truth = j['truth'] as List;
    return TimelapseData(
      j['site'] as String,
      (j['version'] as num).toInt(),
      (years[0] as num).toInt(),
      (years[1] as num).toInt(),
      outlineFromJson(truth[0]),
      outlineFromJson(truth[1]),
    );
  }
  Map<String, dynamic> toJson() => {
    'site': site,
    'version': version,
    'years': [yearA, yearB],
    'truth': [outlineToJson(truthA), outlineToJson(truthB)],
  };

  /// What still keeps a session from being made from it: null when it is ready.
  String? missing() {
    if (yearA >= yearB) return 'years';
    if (truthA.isEmpty || truthB.isEmpty) return 'outline';
    return null;
  }
}

class TimelapseTemplate {
  final String id, name;
  final int updatedAt;
  final TimelapseData? data;
  const TimelapseTemplate(this.id, this.name, this.updatedAt, this.data);

  factory TimelapseTemplate.fromJson(Map<String, dynamic> j) {
    final d = j['data'];
    return TimelapseTemplate(
      j['id'] as String,
      j['name'] as String,
      (j['updatedAt'] as num?)?.toInt() ?? 0,
      d is Map<String, dynamic> && d.containsKey('site') ? TimelapseData.fromJson(d) : null,
    );
  }
}

/// The teacher's time-lapse templates on the server (worker/src/templates.ts).
class TimelapseTemplateApi {
  final Api api;
  const TimelapseTemplateApi(this.api);

  Future<List<TimelapseTemplate>> list() async => [
    for (final t in (await api.request('GET', 'templates?game=timelapse'))['templates'] as List)
      TimelapseTemplate.fromJson(t as Map<String, dynamic>),
  ];

  Future<TimelapseTemplate> get(String id) async =>
      TimelapseTemplate.fromJson((await api.request('GET', 'templates/$id'))['template'] as Map<String, dynamic>);

  Future<TimelapseTemplate> create(String name, TimelapseData data) async => TimelapseTemplate.fromJson(
    (await api.request('POST', 'templates', {'game': 'timelapse', 'name': name, 'data': data.toJson()}))['template']
        as Map<String, dynamic>,
  );

  Future<void> save(String id, String name, TimelapseData data) =>
      api.request('PATCH', 'templates/$id', {'name': name, 'data': data.toJson()});

  Future<void> delete(String id) => api.request('DELETE', 'templates/$id');
}
