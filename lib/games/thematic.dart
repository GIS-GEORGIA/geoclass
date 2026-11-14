import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../thematic/thematic_play.dart';
import '../thematic/thematic_session_page.dart';
import '../thematic/thematic_setup.dart';
import 'game.dart';

/// Thematic map: the teacher's table by region or municipality; students classify it into a choropleth.
class ThematicGame extends GameModule {
  const ThematicGame();

  @override
  String get id => 'thematic';
  @override
  IconData get icon => Icons.layers;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => ThematicSetupPage(s: s, lang: lang),
        ),
      );

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      ThematicSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => ThematicPlay(ctx: ctx);
}
