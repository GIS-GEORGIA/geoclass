import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/watershed_game.dart';
import '../terrain/watershed_play.dart';
import '../terrain/watershed_session_page.dart';
import 'game.dart';

/// Watershed: the teacher picks an outlet on a stream; students draw the basin that drains to it.
class WatershedGame extends GameModule {
  const WatershedGame();

  @override
  String get id => 'watershed';
  @override
  IconData get icon => Icons.water;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => WatershedSetupPage(s: s)));

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      WatershedSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => WatershedPlay(ctx: ctx);
}
