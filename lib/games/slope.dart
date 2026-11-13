import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/slope_game.dart';
import '../terrain/slope_play.dart';
import '../terrain/slope_session_page.dart';
import 'game.dart';

/// Slope: the teacher puts a box of squares on a terrain area; students mark the squares that are too steep.
class SlopeGame extends GameModule {
  const SlopeGame();

  @override
  String get id => 'slope';
  @override
  IconData get icon => Icons.landscape;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => SlopeSetupPage(s: s)));

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      SlopeSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => SlopePlay(ctx: ctx);
}
