import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'l10n.dart';

const minPairs = 2;
const maxPairs = 12;
const rotations = ['none', 'quarter', 'any'];

/// One place in web/cards/index.json: two pictures of it, at different scales.
class CardPair {
  final String a, b, ka, en;
  final int level; // how different the scales are, 1 (same) to 3
  const CardPair({required this.a, required this.b, required this.ka, required this.en, required this.level});
}

final _fileName = RegExp(r'^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$');

/// Reads the list of pairs. An entry with a mistake is left out, and test/logic_test.dart names it.
List<CardPair> parseCardPairs(String json) {
  final pairs = <CardPair>[];
  for (final e in jsonDecode(json) as List) {
    if (e is! Map) continue;
    final a = e['a'], b = e['b'], ka = e['ka'], level = e['level'];
    if (a is! String || b is! String || a == b || !_fileName.hasMatch(a) || !_fileName.hasMatch(b)) continue;
    if (ka is! String || ka.isEmpty || ka.length > 120) continue;
    final en = e['en'];
    pairs.add(
      CardPair(
        a: a,
        b: b,
        ka: ka,
        en: en is String && en.length <= 120 ? en : '',
        level: level is int && level >= 1 && level <= 3 ? level : 1,
      ),
    );
  }
  return pairs;
}

String cardUrl(String file) => '$publicUrl/cards/$file';

/// The pairs on the server. A missing list means none have been added yet.
Future<List<CardPair>> loadCardPairs() async {
  final http.Response response;
  try {
    response = await http.get(Uri.parse('$publicUrl/cards/index.json')).timeout(const Duration(seconds: 15));
  } on Exception {
    throw NoConnection();
  }
  if (response.statusCode == 404) return const [];
  if (response.statusCode != 200) throw NoConnection();
  return parseCardPairs(utf8.decode(response.bodyBytes));
}

/// How far a card is turned clockwise, for each rotation setting. The two cards of a pair never match.
(int, int) pickAngles(String rotation, Random random) {
  switch (rotation) {
    case 'quarter':
      final first = random.nextInt(4);
      final second = (first + 1 + random.nextInt(3)) % 4;
      return (first * 90, second * 90);
    case 'any':
      final first = random.nextInt(360);
      // At least a quarter turn apart, or the pair would look the same way up.
      return (first, (first + 90 + random.nextInt(181)) % 360);
    default:
      return (0, 0);
  }
}

/// A pair as the teacher put it in the deck, with the turns that were chosen.
class DeckPair {
  final String a, b, label, labelEn;
  final int ra, rb;
  const DeckPair({
    required this.a,
    required this.b,
    required this.label,
    required this.labelEn,
    required this.ra,
    required this.rb,
  });

  String labelFor(String lang) => lang == 'en' && labelEn.isNotEmpty ? labelEn : label;

  Map<String, dynamic> toJson() => {
    'a': a,
    'b': b,
    'label': label,
    if (labelEn.isNotEmpty) 'labelEn': labelEn,
    'ra': ra,
    'rb': rb,
  };

  factory DeckPair.fromJson(Map<String, dynamic> j) => DeckPair(
    a: j['a'] as String,
    b: j['b'] as String,
    label: j['label'] as String? ?? '',
    labelEn: j['labelEn'] as String? ?? '',
    ra: j['ra'] as int? ?? 0,
    rb: j['rb'] as int? ?? 0,
  );
}

/// The session's deck: the pairs, and whether a north arrow shows on the cards.
class Deck {
  final List<DeckPair> pairs;
  final bool arrow;
  final String rotation;
  const Deck({required this.pairs, required this.arrow, required this.rotation});

  /// The arrow only means something when cards are turned.
  bool get showsArrow => arrow && rotation != 'none';

  factory Deck.fromSettings(Map<String, dynamic> settings) => Deck(
    pairs: [for (final p in settings['pairs'] as List? ?? const []) DeckPair.fromJson(p as Map<String, dynamic>)],
    arrow: settings['arrow'] == true,
    rotation: settings['rotation'] as String? ?? 'none',
  );

  Map<String, dynamic> toJson() => {
    'pairs': [for (final p in pairs) p.toJson()],
    'arrow': arrow,
    'rotation': rotation,
  };
}

/// One card on the table.
class DeckCard {
  final int pair, side; // side 0 is the pair's first picture; both -1 when the pairs stayed on the server
  final String file;
  final int angle;

  /// What the server is told when the card is turned: pair * 2 + side, or its id in an online deck.
  final int id;
  final String? imageUrl; // an online deck's pictures come under the card's id, not the file name
  const DeckCard(this.pair, this.side, this.file, this.angle, {int? id, this.imageUrl}) : id = id ?? pair * 2 + side;

  String get url => imageUrl ?? cardUrl(file);
}

/// The deck's cards in their own order. An online deck (answers checked on the server) comes as ids and turns,
/// without the pairs or the file names that would give them away.
List<DeckCard> deckCards(Map<String, dynamic> settings) {
  final online = settings['cards'];
  if (online is List) {
    return [
      for (final c in online.cast<Map<String, dynamic>>())
        DeckCard(-1, -1, '', c['r'] as int? ?? 0, id: c['id'] as int, imageUrl: '$publicUrl/api/card-image/${settings['session']}/${c['id']}'),
    ];
  }
  return [
    for (final (i, p) in Deck.fromSettings(settings).pairs.indexed) ...[DeckCard(i, 0, p.a, p.ra), DeckCard(i, 1, p.b, p.rb)],
  ];
}

/// Every card of the deck in a random order, which is each student's own.
List<DeckCard> dealCards(Deck deck, Random random) => [
  for (final (i, p) in deck.pairs.indexed) ...[DeckCard(i, 0, p.a, p.ra), DeckCard(i, 1, p.b, p.rb)],
]..shuffle(random);

/// A found pair or a wrong try, as a row on the server.
class CardTry {
  final String participantId;
  final bool ok;
  final int pair, x, y; // pair when ok, otherwise the pairs of the two cards that were turned
  final int createdAt;
  const CardTry({
    required this.participantId,
    required this.ok,
    this.pair = -1,
    this.x = -1,
    this.y = -1,
    required this.createdAt,
  });

  factory CardTry.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return CardTry(
      participantId: j['participantId'] as String,
      ok: a['ok'] as bool,
      pair: a['pair'] as int? ?? -1,
      x: a['x'] as int? ?? -1,
      y: a['y'] as int? ?? -1,
      createdAt: j['createdAt'] as int,
    );
  }
}

class CardsRow {
  final String participantId;
  final int found, mistakes, lastFoundAt;
  const CardsRow(this.participantId, this.found, this.mistakes, this.lastFoundAt);
}

/// Most pairs first, then fewer wrong tries, then whoever got there sooner.
List<CardsRow> cardsLeaderboard(List<CardTry> tries) {
  final found = <String, int>{}, mistakes = <String, int>{}, last = <String, int>{};
  for (final t in tries) {
    mistakes.putIfAbsent(t.participantId, () => 0);
    found.putIfAbsent(t.participantId, () => 0);
    if (t.ok) {
      found[t.participantId] = found[t.participantId]! + 1;
      if (t.createdAt > (last[t.participantId] ?? 0)) last[t.participantId] = t.createdAt;
    } else {
      mistakes[t.participantId] = mistakes[t.participantId]! + 1;
    }
  }
  final rows = [for (final id in found.keys) CardsRow(id, found[id]!, mistakes[id]!, last[id] ?? 0)];
  rows.sort((x, y) {
    final byFound = y.found.compareTo(x.found);
    if (byFound != 0) return byFound;
    final byMistakes = x.mistakes.compareTo(y.mistakes);
    if (byMistakes != 0) return byMistakes;
    return x.lastFoundAt.compareTo(y.lastFoundAt);
  });
  return rows;
}

/// For each pair: how many students found it, and how often one of its cards was in a wrong try.
({List<int> found, List<int> confused}) pairStats(List<CardTry> tries, int pairs) {
  final found = List.filled(pairs, 0), confused = List.filled(pairs, 0);
  for (final t in tries) {
    if (t.ok) {
      if (t.pair < pairs) found[t.pair]++;
    } else {
      if (t.x < pairs) confused[t.x]++;
      if (t.y < pairs) confused[t.y]++;
    }
  }
  return (found: found, confused: confused);
}

/// The credits the map licences ask for wherever these pictures are shown, in the wording they require.
class CardsCredit extends StatelessWidget {
  final Color? color;
  const CardsCredit({super.key, this.color});

  static const data = "Data: © OpenStreetMap contributors, SRTM, GEBCO, SONNY's LiDAR DTM, NASADEM, ESA WorldCover";
  static const maps = 'Maps © Tracestrack';

  Widget _link(BuildContext context, String text, String url) => TextButton(
    style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
    onPressed: () => launchUrl(Uri.parse(url)),
    child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
  );

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    children: [
      _link(context, data, 'https://www.openstreetmap.org/copyright'),
      _link(context, maps, 'https://www.tracestrack.com/credits/'),
    ],
  );
}

/// The north arrow that sits on a turned card.
class NorthArrow extends StatelessWidget {
  final int angle;
  final double size;
  const NorthArrow({super.key, required this.angle, this.size = 26});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(blurRadius: 3, color: Colors.black45)],
    ),
    child: Transform.rotate(
      angle: angle * pi / 180,
      child: Icon(Icons.navigation, size: size * 0.8, color: const Color(0xFFC62828)),
    ),
  );
}

/// The picture turned clockwise, scaled so that its corners still fill the square.
class TurnedImage extends StatelessWidget {
  final String url;
  final double angle; // degrees
  final BoxFit fit;
  final bool fill;
  final Widget Function(BuildContext)? onError;
  const TurnedImage({
    super.key,
    required this.url,
    required this.angle,
    this.fit = BoxFit.cover,
    this.fill = true,
    this.onError,
  });

  @override
  Widget build(BuildContext context) {
    final rad = angle * pi / 180;
    // A square turned by an angle is covered by one scaled by |cos| + |sin|.
    final scale = fill ? cos(rad).abs() + sin(rad).abs() : 1.0;
    return Transform.rotate(
      angle: rad,
      child: Transform.scale(
        scale: scale,
        child: Image.network(
          url,
          fit: fit,
          width: double.infinity,
          height: double.infinity,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          errorBuilder: (ctx, _, _) =>
              onError?.call(ctx) ?? const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
        ),
      ),
    );
  }
}

/// Only phones and tablets with the app have a compass sensor that this can use.
bool get compassAvailable =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// A card full screen, where it can be zoomed. With the compass on, the card is turned so
/// that its north points to the real north: hold the phone flat and compare it with the room.
Future<void> showCardZoom(BuildContext context, S s, DeckCard card, {required bool arrow}) => showDialog<void>(
  context: context,
  builder: (ctx) => _CardZoom(s: s, card: card, arrow: arrow),
);

class _CardZoom extends StatefulWidget {
  final S s;
  final DeckCard card;
  final bool arrow;
  const _CardZoom({required this.s, required this.card, required this.arrow});
  @override
  State<_CardZoom> createState() => _CardZoomState();
}

class _CardZoomState extends State<_CardZoom> {
  StreamSubscription<CompassEvent>? _sub;
  bool _compass = false;
  double? _heading; // degrees clockwise from north, smoothed
  bool _noSensor = false;

  S get s => widget.s;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toggleCompass() {
    if (_compass) {
      _sub?.cancel();
      setState(() {
        _compass = false;
        _heading = null;
      });
      return;
    }
    final events = FlutterCompass.events;
    if (events == null) {
      setState(() => _noSensor = true);
      return;
    }
    setState(() {
      _compass = true;
      _noSensor = false;
    });
    _sub = events.listen((e) {
      final h = e.heading;
      if (h == null || !mounted) return;
      setState(() => _heading = smoothHeading(_heading, h));
    });
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final live = _compass && _heading != null;
    // The picture itself is north up. Turned by minus the heading, its north points to the real one.
    final angle = live ? -_heading! : card.angle.toDouble();
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: TurnedImage(url: card.url, angle: angle, fit: BoxFit.contain, fill: false),
                ),
              ),
            ),
          ),
          if (widget.arrow && !live) Positioned(left: 12, top: 12, child: NorthArrow(angle: card.angle, size: 40)),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              children: [
                if (widget.arrow && compassAvailable)
                  IconButton.filledTonal(
                    tooltip: s['cards_compass'],
                    isSelected: _compass,
                    icon: const Icon(Icons.explore_outlined),
                    selectedIcon: const Icon(Icons.explore),
                    onPressed: _toggleCompass,
                  ),
                IconButton.filledTonal(
                  tooltip: s['close'],
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: const Center(child: CardsCredit(color: Colors.white70))),
          if (_compass || _noSensor)
            Positioned(
              left: 16,
              right: 16,
              bottom: 100,
              child: Text(
                _noSensor ? s['cards_compass_none'] : (live ? s['cards_compass_on'] : s['cards_compass_wait']),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
              ),
            ),
        ],
      ),
    );
  }
}

/// Moves a compass reading a part of the way to the new one, around the circle, so the card doesn't jitter.
double smoothHeading(double? old, double next) {
  if (old == null) return next;
  var delta = (next - old) % 360;
  if (delta > 180) delta -= 360;
  return (old + delta * 0.3) % 360;
}

/// A card on the table: the picture turned, the arrow if wanted, and a frame for its state.
class CardTile extends StatelessWidget {
  final DeckCard card;
  final bool arrow, selected, found, wrong;
  final VoidCallback? onTap;
  final VoidCallback onZoom;
  const CardTile({
    super.key,
    required this.card,
    required this.arrow,
    required this.selected,
    required this.found,
    required this.wrong,
    required this.onTap,
    required this.onZoom,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = found
        ? const Color(0xFF2E7D32)
        : wrong
        ? scheme.error
        : selected
        ? scheme.primary
        : Colors.transparent;
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: frame, width: 4),
                color: Colors.black,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Material(
                  color: Colors.black,
                  child: InkWell(
                    onTap: onTap,
                    onLongPress: onZoom,
                    child: Opacity(
                      opacity: found ? 0.55 : 1,
                      child: TurnedImage(url: card.url, angle: card.angle.toDouble()),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (arrow)
            Positioned(
              left: 8,
              top: 8,
              child: IgnorePointer(child: NorthArrow(angle: card.angle, size: 24)),
            ),
          // The long press is hard to find, so a small button says there is more.
          Positioned(
            right: 2,
            bottom: 2,
            child: IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              color: Colors.white,
              style: IconButton.styleFrom(backgroundColor: Colors.black38),
              icon: const Icon(Icons.zoom_in),
              onPressed: onZoom,
            ),
          ),
          if (found)
            const Positioned(right: 8, top: 8, child: Icon(Icons.check_circle, color: Color(0xFF66BB6A), size: 26)),
        ],
      ),
    );
  }
}
