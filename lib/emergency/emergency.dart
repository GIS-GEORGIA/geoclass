import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../api.dart';
import '../coords.dart';

/// 112: telling the emergency service where you are. An exercise only: nothing here reaches 112.
///
/// The teacher prepares a template once (points, scenarios, facts and photos) and makes sessions from it. The
/// server checks and scores the answers (worker/src/games/emergency.ts); the same rules are here so the app can
/// show the parts of a score. test/fixtures/emergency/formats.json holds cases both sides must agree on.

const emergencyFormats = ['dd', 'dm', 'dms', 'utm'];
const emergencyKinds = ['injury', 'lost', 'fire', 'traffic', 'flood', 'other'];
const maxPoints = 8, minPhotos = 2, maxPhotos = 4, maxPeople = 99;
const maxTitle = 80, maxText = 600, maxLandmark = 120, maxNote = 200, maxCoords = 80;

/// The facts a scenario tells: what an operator needs to hear.
class Facts {
  final String kind;
  final int people;
  final bool injured;
  final String landmark;
  const Facts({this.kind = 'injury', this.people = 1, this.injured = true, this.landmark = ''});

  factory Facts.fromJson(Map<String, dynamic> j) => Facts(
    kind: j['kind'] as String,
    people: (j['people'] as num).toInt(),
    injured: j['injured'] as bool,
    landmark: j['landmark'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {'kind': kind, 'people': people, 'injured': injured, 'landmark': landmark};
}

class PointPhoto {
  final String id, note;
  const PointPhoto(this.id, this.note);
  factory PointPhoto.fromJson(Map<String, dynamic> j) => PointPhoto(j['id'] as String, j['note'] as String? ?? '');
  Map<String, dynamic> toJson() => {'id': id, 'note': note};
}

/// One place of a template, as the teacher wrote it.
class EmergencyPoint {
  final double lat, lon;
  final String format, title, text;
  final Facts facts;
  final List<PointPhoto> photos;
  final int best;
  const EmergencyPoint({
    required this.lat,
    required this.lon,
    this.format = 'dd',
    this.title = '',
    this.text = '',
    this.facts = const Facts(),
    this.photos = const [],
    this.best = 0,
  });

  factory EmergencyPoint.fromJson(Map<String, dynamic> j) => EmergencyPoint(
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    format: j['format'] as String,
    title: j['title'] as String? ?? '',
    text: j['text'] as String? ?? '',
    facts: Facts.fromJson(j['facts'] as Map<String, dynamic>),
    photos: [for (final p in j['photos'] as List) PointPhoto.fromJson(p as Map<String, dynamic>)],
    best: (j['best'] as num).toInt(),
  );
  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'format': format,
    'title': title,
    'text': text,
    'facts': facts.toJson(),
    'photos': [for (final p in photos) p.toJson()],
    'best': best,
  };

  EmergencyPoint copyWith({
    double? lat,
    double? lon,
    String? format,
    String? title,
    String? text,
    Facts? facts,
    List<PointPhoto>? photos,
    int? best,
  }) => EmergencyPoint(
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    format: format ?? this.format,
    title: title ?? this.title,
    text: text ?? this.text,
    facts: facts ?? this.facts,
    photos: photos ?? this.photos,
    best: best ?? this.best,
  );

  /// What still keeps a session from being made from it: null when it is ready.
  String? missing() {
    if (title.trim().isEmpty) return 'title';
    if (text.trim().isEmpty) return 'text';
    if (photos.length < minPhotos) return 'photos';
    return null;
  }
}

/// A template: its name, and its points once it is loaded.
class EmergencyTemplate {
  final String id, name;
  final int updatedAt;
  final List<EmergencyPoint> points;
  const EmergencyTemplate(this.id, this.name, this.updatedAt, this.points);

  factory EmergencyTemplate.fromJson(Map<String, dynamic> j) {
    final data = j['data'] as Map<String, dynamic>?;
    return EmergencyTemplate(j['id'] as String, j['name'] as String, (j['updatedAt'] as num?)?.toInt() ?? 0, [
      for (final p in (data?['points'] as List?) ?? const []) EmergencyPoint.fromJson(p as Map<String, dynamic>),
    ]);
  }
}

/// A point as the student sees it: no facts, no best photo, no notes. The photos are in the session's order.
class StudentPoint {
  final double lat, lon;
  final String format, title, text;
  final List<String> photos;
  const StudentPoint(this.lat, this.lon, this.format, this.title, this.text, this.photos);

  static (String, List<StudentPoint>) listFrom(Map<String, dynamic> settings) => (
    settings['template'] as String,
    [
      for (final p in settings['points'] as List)
        StudentPoint(
          ((p as Map<String, dynamic>)['lat'] as num).toDouble(),
          (p['lon'] as num).toDouble(),
          p['format'] as String,
          p['title'] as String,
          p['text'] as String,
          [for (final x in p['photos'] as List) x as String],
        ),
    ],
  );
}

String photoUrl(String template, String photo) => '$publicUrl/photos/$template/$photo.jpg';

// --- The rules, as on the server ---

/// Which format coordinates are written in, or null: as classifyCoords in worker/src/games/emergency.ts.
String? classifyCoords(String text) {
  final t = text
      .trim()
      .toUpperCase()
      .replaceAll('º', '°')
      .replaceAll(RegExp('[′’\']'), "'")
      .replaceAll(RegExp('[″”"]|\'\''), '"');
  if (t.isEmpty || t.length > maxCoords) return null;
  if (RegExp('[^0-9A-Z.,;:°\'"\\s+\\-]').hasMatch(t)) return null;
  if (RegExp(r'^\d{1,2}\s*[C-X]?\s+\d{6}(\.\d+)?\s*(M?\s*E)?[\s,;]+\d{7}(\.\d+)?\s*(M?\s*N)?$').hasMatch(t)) {
    return 'utm';
  }
  if (RegExp('[A-DF-MO-RT-VX-Z]').hasMatch(t)) return null; // letters other than N, S, E, W
  final n = [for (final m in RegExp(r'\d+(?:[.,]\d+)?').allMatches(t)) m.group(0)!];
  bool whole(String v) => !v.contains('.') && !v.contains(',');
  bool below60(String v) => double.parse(v.replaceAll(',', '.')) < 60;
  if (n.length == 2 && n.every((v) => !whole(v))) return 'dd';
  if (n.length == 4 && whole(n[0]) && whole(n[2]) && below60(n[1]) && below60(n[3])) return 'dm';
  if (n.length == 6 && [0, 1, 3, 4].every((i) => whole(n[i])) && [1, 2, 4, 5].every((i) => below60(n[i]))) {
    return 'dms';
  }
  return null;
}

/// Where typed coordinates point, read in the format they are written in (or any format), or null.
({double lat, double lon})? readCoords(String text) {
  final format = classifyCoords(text);
  final p = format == null ? parseAny(text.trim()) : parseAs(format, text.trim().replaceAll('º', '°'));
  return p == null ? null : (lat: p.latitude, lon: p.longitude);
}

/// 40 within 50 m, 0 from 5 km, the log of the distance in between.
int distancePoints(double? d) {
  if (d == null) return 0;
  if (d <= 50) return 40;
  if (d >= 5000) return 0;
  return (40 * (1 - log(d / 50) / ln10 / 2)).round();
}

/// A student's answer to one point.
class EmergencyAnswer {
  final String coords;
  final ({double lat, double lon})? at;
  final String kind;
  final int people;
  final bool injured;
  final String landmark, photo;
  const EmergencyAnswer({
    required this.coords,
    required this.at,
    required this.kind,
    required this.people,
    required this.injured,
    required this.landmark,
    required this.photo,
  });

  factory EmergencyAnswer.fromJson(Map<String, dynamic> j) {
    final at = j['at'] as List?;
    return EmergencyAnswer(
      coords: j['coords'] as String,
      at: at == null ? null : (lat: (at[0] as num).toDouble(), lon: (at[1] as num).toDouble()),
      kind: j['kind'] as String,
      people: (j['people'] as num).toInt(),
      injured: j['injured'] as bool,
      landmark: j['landmark'] as String,
      photo: j['photo'] as String,
    );
  }
  Map<String, dynamic> toJson() => {
    'coords': coords,
    'at': at == null ? null : [at!.lat, at!.lon],
    'kind': kind,
    'people': people,
    'injured': injured,
    'landmark': landmark,
    'photo': photo,
  };
}

/// A score and its parts: as scoreAnswer on the server.
class ScoreParts {
  final double? distance;
  final int place, format, message, photo;
  const ScoreParts(this.distance, this.place, this.format, this.message, this.photo);
  int get total => place + format + message + photo;
}

ScoreParts scoreParts(
  ({double lat, double lon}) truth,
  String format,
  Facts facts,
  String bestPhoto,
  EmergencyAnswer a,
) {
  final at = a.at;
  final d = at == null ? null : distanceM(at.lat, at.lon, truth.lat, truth.lon);
  return ScoreParts(
    d,
    distancePoints(d),
    classifyCoords(a.coords) == format ? 20 : 0,
    (a.kind == facts.kind ? 5 : 0) +
        (a.people == facts.people ? 5 : 0) +
        (a.injured == facts.injured ? 5 : 0) +
        (a.landmark.trim().length >= 3 ? 5 : 0),
    a.photo == bestPhoto ? 20 : 0,
  );
}

// --- Photos ---

const photoMaxSide = 1280, photoTargetBytes = 300 * 1024, photoMaxBytes = 400 * 1024;

/// A photo made small enough to send: at most 1280 px on its longer side, a JPEG of about 300 KB, turned the
/// way the camera meant, and with nothing else kept: the EXIF data (where and when it was taken, the phone)
/// is dropped. Null if it isn't a picture this app can read (HEIC, for one).
Uint8List? preparePhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final side = max(image.width, image.height);
  if (side > photoMaxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: photoMaxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: photoMaxSide, interpolation: img.Interpolation.average);
  }
  image.exif = img.ExifData();
  image.iccProfile = null;
  for (final quality in [82, 72, 62, 52]) {
    final out = img.encodeJpg(image, quality: quality);
    if (out.length <= photoTargetBytes) return out;
  }
  // Still too big (a very busy picture): smaller, at the lowest quality tried.
  final smaller = img.copyResize(image, width: (image.width * 0.75).round(), interpolation: img.Interpolation.average);
  smaller.exif = img.ExifData();
  final out = img.encodeJpg(smaller, quality: 52);
  return out.length <= photoMaxBytes ? out : null;
}

// --- The templates API (worker/src/templates.ts) ---

class TemplateApi {
  final Api api;
  const TemplateApi(this.api);

  Future<List<EmergencyTemplate>> list() async => [
    for (final t in (await api.request('GET', 'templates?game=emergency'))['templates'] as List)
      EmergencyTemplate.fromJson(t as Map<String, dynamic>),
  ];

  Future<EmergencyTemplate> get(String id) async =>
      EmergencyTemplate.fromJson((await api.request('GET', 'templates/$id'))['template'] as Map<String, dynamic>);

  Future<EmergencyTemplate> create(String name) async => EmergencyTemplate.fromJson(
    (await api.request('POST', 'templates', {
          'game': 'emergency',
          'name': name,
          'data': {'points': []},
        }))['template']
        as Map<String, dynamic>,
  );

  Future<void> save(String id, String name, List<EmergencyPoint> points) => api.request('PATCH', 'templates/$id', {
    'name': name,
    'data': {
      'points': [for (final p in points) p.toJson()],
    },
  });

  Future<void> delete(String id) => api.request('DELETE', 'templates/$id');
  Future<void> deletePhoto(String id, String photo) => api.request('DELETE', 'templates/$id/photos/$photo');

  /// Sends a photo prepared by preparePhoto; returns its id.
  Future<String> upload(String id, Uint8List jpeg) async =>
      (await api.sendBytes('templates/$id/photos', jpeg, 'image/jpeg'))['id'] as String;
}
