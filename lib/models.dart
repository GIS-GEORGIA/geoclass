class SessionInfo {
  final String id, name, game, status;
  final int rev, createdAt;
  final bool archived;
  final int? responses;

  const SessionInfo({
    required this.id,
    required this.name,
    required this.game,
    required this.status,
    required this.rev,
    required this.createdAt,
    required this.archived,
    this.responses,
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
