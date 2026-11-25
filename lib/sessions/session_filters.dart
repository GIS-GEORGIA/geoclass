import '../l10n.dart';
import '../models.dart';

/// The teacher's session list: which sessions show, in what order. Kept apart from the page so the rules are
/// tested on their own (test/sessions_test.dart).

enum SessionSort { newest, oldest, name }

/// Who made a session, as the list groups them: the signed-in teacher's own are [mine]. The owner's list names
/// the other teachers (teacherName); a teacher's own list has only their own sessions.
const mine = '';

String creatorOf(SessionInfo s) => s.teacherName ?? mine;

/// The filters of the list; the defaults show every session that isn't archived, newest first.
class SessionFilter {
  final String query;

  /// null: every status; else 'open', 'paused' or 'closed'.
  final String? status;

  /// null: everyone's; else a [creatorOf] value.
  final String? creator;
  final SessionSort sort;
  final bool archived;

  const SessionFilter({
    this.query = '',
    this.status,
    this.creator,
    this.sort = SessionSort.newest,
    this.archived = false,
  });

  /// Whether anything differs from the defaults (archived is the app bar's switch, not a filter to reset).
  bool get isFiltered => query.trim().isNotEmpty || status != null || creator != null || sort != SessionSort.newest;

  SessionFilter copyWith({
    String? query,
    String? Function()? status,
    String? Function()? creator,
    SessionSort? sort,
    bool? archived,
  }) => SessionFilter(
    query: query ?? this.query,
    status: status == null ? this.status : status(),
    creator: creator == null ? this.creator : creator(),
    sort: sort ?? this.sort,
    archived: archived ?? this.archived,
  );

  /// Back to the defaults, keeping the archived switch.
  SessionFilter reset() => SessionFilter(archived: archived);
}

/// The sessions [f] lets through, in its order. The name search ignores case and spaces at either end.
List<SessionInfo> filterSessions(List<SessionInfo> all, SessionFilter f) {
  final q = f.query.trim().toLowerCase();
  final out = [
    for (final s in all)
      if ((f.archived || !s.archived) &&
          (q.isEmpty || s.name.toLowerCase().contains(q)) &&
          (f.status == null || s.status == f.status) &&
          (f.creator == null || creatorOf(s) == f.creator))
        s,
  ];
  int byName(SessionInfo a, SessionInfo b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  out.sort(switch (f.sort) {
    SessionSort.newest => (a, b) => b.createdAt != a.createdAt ? b.createdAt.compareTo(a.createdAt) : byName(a, b),
    SessionSort.oldest => (a, b) => a.createdAt != b.createdAt ? a.createdAt.compareTo(b.createdAt) : byName(a, b),
    SessionSort.name => byName,
  });
  return out;
}

/// Everyone who made one of [all], the signed-in teacher first, then the others by name.
List<String> creators(List<SessionInfo> all) {
  final others = {for (final s in all) creatorOf(s)}..remove(mine);
  return [if (all.any((s) => creatorOf(s) == mine)) mine, ...(others.toList()..sort())];
}

/// The longest name the server takes (worker/src/index.ts cleanName).
const maxSessionName = 100;

/// A name the server takes: not empty once trimmed, at most [maxSessionName] characters.
bool validSessionName(String name) {
  final t = name.trim();
  return t.isNotEmpty && t.length <= maxSessionName;
}

/// Names offered for a new session of a game titled [game], in the app's language. [count]: how many sessions
/// of that game the teacher has, so the numbered one comes next.
List<String> suggestedNames(S s, String game, int count) {
  final number = (count + 1).toString().padLeft(2, '0');
  // A title that is a question ("Where did you travel?") reads badly before "Practice": drop its end mark.
  game = game.trim().replaceFirst(RegExp(r'[?!.:;…]+$'), '');
  return [
    for (final k in const ['practice', 'challenge', 'team', 'beginner', 'advanced']) s.f('session_suggest_$k', [game]),
    s.f('session_suggest_number', [game, number]),
  ].map((n) => n.length > maxSessionName ? n.substring(0, maxSessionName).trimRight() : n).toList();
}
