import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/least_cost_game.dart';
import '../terrain/least_cost_play.dart';
import '../terrain/least_cost_session_page.dart';
import 'game.dart';

/// Least-cost path: the teacher puts A and B on a terrain area; students draw the easiest route between them.
class LeastCostGame extends GameModule {
  const LeastCostGame();

  @override
  String get id => 'least-cost';
  @override
  IconData get icon => Icons.route;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => LeastCostSetupPage(s: s)));

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      LeastCostSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => LeastCostPlay(ctx: ctx);
}
