import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/hydro_play.dart';
import '../terrain/hydro_session_page.dart';
import '../terrain/watershed_game.dart';
import 'game.dart';

/// Watershed, level 2: the basin derived from the DEM step by step (D8 path, accumulation and threshold, pour
/// point); the teacher picks the area and the outlet as in level 1.
class HydroGame extends GameModule {
  const HydroGame();

  @override
  String get id => 'hydro';
  @override
  IconData get icon => Icons.account_tree;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => WatershedSetupPage(s: s, game: 'hydro'),
        ),
      );

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      HydroSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => HydroPlay(ctx: ctx);
}
