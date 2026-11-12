import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../settings.dart';

/// What every play screen gets from the student page.
class PlayContext {
  final S s;
  final String lang;
  final String token;

  /// The session's settings as join gave them: only what students may see.
  final Map<String, dynamic> settings;

  /// The server's clock when the session was loaded, for games against the teacher's clock.
  final int now;

  /// Bumped by the teacher's reset; a game starts over when it changes.
  final int resetAt;
  final Api api;

  /// The server refused an answer because the session is paused or closed: the student page shows that.
  final ValueChanged<String> onStopped;

  const PlayContext({
    required this.s,
    required this.lang,
    required this.token,
    required this.settings,
    required this.now,
    required this.resetAt,
    required this.api,
    required this.onStopped,
  });
}

/// One game, everything the app needs to know about it in one place: the home page, the teacher's session
/// page and the student page ask the registry (games/registry.dart) for the module instead of switching on the
/// game's name. Games not moved yet are still handled in those pages directly. The Worker has the same
/// registry (worker/src/games), which checks and scores the answers.
abstract class GameModule {
  const GameModule();

  /// The name stored on the server, in sessions.game.
  String get id;
  IconData get icon;
  String title(S s) => s['game_$id'];

  /// Played against the teacher's clock.
  bool get timed => false;

  /// Whether the teacher sets something up after naming the session: the button says "Next", not "Create".
  bool get hasSetup;

  /// The teacher's settings for a new session, sent with it to the server; null if the teacher cancelled.
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang);

  /// The teacher's page for a running session.
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false});

  /// The student's screen while the session is open.
  Widget play(PlayContext ctx);
}
