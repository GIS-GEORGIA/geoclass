import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import '../terrain/profile_game.dart';
import '../terrain/profile_play.dart';
import '../terrain/profile_session_page.dart';
import 'game.dart';

/// Terrain profile: the teacher draws a line on a terrain area; students read its height profile and answer.
class ProfileGame extends GameModule {
  const ProfileGame();

  @override
  String get id => 'profile';
  @override
  IconData get icon => Icons.area_chart;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) =>
      Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => ProfileSetupPage(s: s)));

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      ProfileSessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => ProfilePlay(ctx: ctx);
}
