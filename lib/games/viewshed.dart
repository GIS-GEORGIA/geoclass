import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/viewshed_game.dart';
import '../terrain/viewshed_play.dart';
import '../terrain/viewshed_session_page.dart';
import 'game.dart';

/// Viewshed: the teacher puts an observer on a terrain area; students judge what it sees.
class ViewshedGame extends GameModule {
  const ViewshedGame();

  @override
  String get id => 'viewshed';
  @override
  IconData get icon => Icons.visibility;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => ViewshedSetupPage(s: s)));

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      ViewshedSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => ViewshedPlay(ctx: ctx);
}
