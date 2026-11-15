import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../timelapse/timelapse_play.dart';
import '../timelapse/timelapse_session_page.dart';
import '../timelapse/timelapse_setup.dart';
import 'game.dart';

/// Time-lapse: a site's satellite pictures year by year (open pits, a delta, a city). The teacher outlines
/// what to find on two years as a template; each student draws the same, sees the areas and the change, and
/// is scored on how well both outlines match.
class TimelapseGame extends GameModule {
  const TimelapseGame();

  @override
  String get id => 'timelapse';
  @override
  IconData get icon => Icons.satellite_alt;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) => setupWith(context, s, lang, Api());

  @override
  Future<Map<String, dynamic>?> setupWith(BuildContext context, S s, String lang, Api api) =>
      Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => TimelapseSetupPage(s: s, lang: lang, api: api),
        ),
      );

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      TimelapseSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => TimelapsePlay(ctx: ctx);
}
