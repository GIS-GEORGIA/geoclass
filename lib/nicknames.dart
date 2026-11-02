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

/// A friendly name for the leaderboard, worked out from the random participant id.
/// Nothing about the student is stored or asked for.
String nickname(String participantId, String lang) {
  var hash = 0x811c9dc5;
  for (final unit in participantId.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  final i = lang == 'ka' ? 0 : 1;
  return '${_adjectives[hash % _adjectives.length][i]} ${_animals[(hash >> 8) % _animals.length][i]}';
}
