import 'dart:math';

const _adjectives = <List<String>>[
  ['ლურჯი', 'Blue'], ['მწვანე', 'Green'], ['წითელი', 'Red'], ['ყვითელი', 'Yellow'], ['იისფერი', 'Purple'],
  ['ნარინჯისფერი', 'Orange'], ['ვერცხლისფერი', 'Silver'], ['ოქროსფერი', 'Golden'], ['სწრაფი', 'Swift'], ['ჭკვიანი', 'Clever'],
  ['მამაცი', 'Brave'], ['მხიარული', 'Merry'], ['ცნობისმოყვარე', 'Curious'], ['წყნარი', 'Calm'], ['ძლიერი', 'Strong'],
  ['პატარა', 'Little'], ['დიდი', 'Great'], ['მთის', 'Mountain'], ['ზღვის', 'Sea'], ['ტყის', 'Forest'],
];

const _animals = <List<String>>[
  ['მელა', 'Fox'], ['მგელი', 'Wolf'], ['დათვი', 'Bear'], ['არწივი', 'Eagle'], ['ჯიხვი', 'Ibex'],
  ['ფოცხვერი', 'Lynx'], ['ზღარბი', 'Hedgehog'], ['ციყვი', 'Squirrel'], ['კურდღელი', 'Hare'], ['ბუ', 'Owl'],
  ['დელფინი', 'Dolphin'], ['ვეფხვი', 'Tiger'], ['ირემი', 'Deer'], ['წავი', 'Otter'], ['შევარდენი', 'Falcon'],
  ['თხა', 'Goat'], ['კატა', 'Cat'], ['ძაღლი', 'Dog'], ['მერცხალი', 'Swallow'], ['ლომი', 'Lion'],
];

/// Nicknames students picked themselves, by their random id. Ids are made for one session, so one list serves
/// every session the app has open. The teacher's polling and the student's own page fill it.
final _chosen = <String, String>{};

/// Sets what the server said for these ids: a picked nickname, or none (back to the one made from the id).
void rememberNicknames(Map<String, String> picked, {Iterable<String> forIds = const []}) {
  for (final id in forIds) {
    _chosen.remove(id);
  }
  _chosen.addAll(picked);
}

/// The same rule as the server: letters, digits, spaces, - and _, at most 20 characters.
const maxNicknameChars = 20;
final _nicknameRe = RegExp(r'^[\p{L}\p{N}][\p{L}\p{N}\p{M} _-]*$', unicode: true);

/// The nickname as the server would keep it, or null if it isn't allowed. An empty one is ''.
String? cleanNickname(String text) {
  final n = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (n.isEmpty) return '';
  return n.runes.length <= maxNicknameChars && _nicknameRe.hasMatch(n) ? n : null;
}

/// A few made-up names from the same word lists, for a student who'd rather pick one.
List<String> suggestedNicknames(String lang, {int count = 6, Random? random}) {
  final r = random ?? Random();
  final i = lang == 'ka' ? 0 : 1;
  final out = <String>{};
  while (out.length < count) {
    out.add('${_adjectives[r.nextInt(_adjectives.length)][i]} ${_animals[r.nextInt(_animals.length)][i]}');
  }
  return out.toList();
}

/// The student's name in the game: the one they picked, or a friendly one worked out from the random id.
/// Nothing about the student is asked for.
String nickname(String participantId, String lang) {
  final picked = _chosen[participantId];
  if (picked != null) return picked;
  var hash = 0x811c9dc5;
  for (final unit in participantId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  final i = lang == 'ka' ? 0 : 1;
  return '${_adjectives[hash % _adjectives.length][i]} ${_animals[(hash >> 8) % _animals.length][i]}';
}
