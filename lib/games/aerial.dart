import 'package:flutter/material.dart';

import '../aerial_setup_page.dart';
import '../coordinates_play.dart';
import '../coordinates_session_page.dart';
import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import 'game.dart';

/// Aerial photos: find where each photo was taken. It plays like the coordinates game, with photos as tasks.
class AerialGame extends GameModule {
  const AerialGame();

  @override
  String get id => 'aerial';
  @override
  IconData get icon => Icons.satellite_alt;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) async {
    final picked = await Navigator.of(context).push<(List<CoordTask>, bool)>(
      MaterialPageRoute(
        builder: (_) => AerialSetupPage(s: s, lang: lang),
      ),
    );
    if (picked == null) return null;
    final (tasks, offline) = picked;
    // Online (the default) the places stay on the server until each photo is answered.
    return {'tasks': tasks.map((t) => t.toJson()).toList(), 'answers': offline ? 'offline' : 'online'};
  }

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      CoordinatesSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => CoordinatesPlay(
    s: ctx.s,
    lang: ctx.lang,
    token: ctx.token,
    tasks: CoordTask.listFrom(ctx.settings),
    resetAt: ctx.resetAt,
    api: ctx.api,
    onStopped: ctx.onStopped,
  );
}
