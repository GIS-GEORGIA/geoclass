class SessionInfo {
  final String id, name, game, status;
  final int rev, createdAt;
  final bool archived;
  final int? responses;
  final Map<String, dynamic> settings;

  const SessionInfo({
    required this.id,
    required this.name,
    required this.game,
    required this.status,
    required this.rev,
    required this.createdAt,
    required this.archived,
    this.responses,
    this.settings = const {},
  });

  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        game: j['game'] as String,
        status: j['status'] as String,
        rev: j['rev'] as int,
        createdAt: j['createdAt'] as int,
        archived: j['archived'] as bool,
        responses: j['responses'] as int?,
        settings: j['settings'] as Map<String, dynamic>? ?? const {},
      );
}

class TravelAnswer {
  final String id, place, country, reason, transport, company;
  final double lat, lon;
  final bool hidden;
  final int createdAt;

  const TravelAnswer({
    required this.id,
    required this.place,
    required this.country,
    required this.reason,
    required this.transport,
    required this.company,
    required this.lat,
    required this.lon,
    required this.hidden,
    required this.createdAt,
  });

  factory TravelAnswer.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return TravelAnswer(
      id: j['id'] as String,
      place: a['place'] as String,
      country: a['country'] as String? ?? '',
      reason: a['reason'] as String? ?? '',
      transport: a['transport'] as String,
      company: a['company'] as String,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      hidden: j['hidden'] as bool? ?? false,
      createdAt: j['createdAt'] as int,
    );
  }
}

const transports = ['plane', 'train', 'car', 'bus', 'ship', 'bike', 'foot'];
const companies = ['alone', 'family', 'friends', 'class'];

/// One task of the coordinates game.
class CoordTask {
  final double lat, lon;
  final String mode; // to_map: coordinates are given, find the point. read: a point is given, write its coordinates.
  final String format; // dd, dm, dms or utm
  final String label, labelEn;
  final String photo; // aerial game: a file in web/aerial

  const CoordTask({
    required this.lat,
    required this.lon,
    required this.mode,
    required this.format,
    this.label = '',
    this.labelEn = '',
    this.photo = '',
  });

  String labelFor(String lang) => lang == 'en' && labelEn.isNotEmpty ? labelEn : label;

  factory CoordTask.fromJson(Map<String, dynamic> j) => CoordTask(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        mode: j['mode'] as String,
        format: j['format'] as String,
        label: j['label'] as String? ?? '',
        labelEn: j['labelEn'] as String? ?? '',
        photo: j['photo'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'mode': mode,
        'format': format,
        'label': label,
        if (labelEn.isNotEmpty) 'labelEn': labelEn,
        if (photo.isNotEmpty) 'photo': photo,
      };

  static List<CoordTask> listFrom(Map<String, dynamic> settings) => [
        for (final t in settings['tasks'] as List? ?? const []) CoordTask.fromJson(t as Map<String, dynamic>),
      ];
}

class CoordAnswer {
  final String id, participantId, raw;
  final int round, score, createdAt;
  final double lat, lon, distanceM;

  const CoordAnswer({
    required this.id,
    required this.participantId,
    required this.raw,
    required this.round,
    required this.score,
    required this.lat,
    required this.lon,
    required this.distanceM,
    required this.createdAt,
  });

  factory CoordAnswer.fromJson(Map<String, dynamic> j) => CoordAnswer(
        id: j['id'] as String,
        participantId: j['participantId'] as String,
        raw: (j['answer'] as Map<String, dynamic>)['raw'] as String? ?? '',
        round: j['round'] as int,
        score: j['score'] as int,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        distanceM: (j['distanceM'] as num).toDouble(),
        createdAt: j['createdAt'] as int,
      );
}
