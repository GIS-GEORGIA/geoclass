import 'package:flutter/material.dart';

import '../api.dart';
import '../emergency/emergency_play.dart';
import '../emergency/emergency_session_page.dart';
import '../emergency/emergency_setup.dart';
import '../l10n.dart';
import '../models.dart';
import '../settings.dart';
import 'game.dart';

/// 112: telling the emergency service where you are, as an exercise. The teacher prepares the points,
/// scenarios and photos as a template; each student reads the place off the map in the format asked for,
/// says what happened and picks the most useful photo.
class EmergencyGame extends GameModule {
  const EmergencyGame();

  @override
  String get id => 'emergency';
  @override
  IconData get icon => Icons.emergency;
  @override
  bool get hasSetup => true;

  @override
  Future<Map<String, dynamic>?> setup(BuildContext context, S s, String lang) => setupWith(context, s, lang, Api());

  @override
  Future<Map<String, dynamic>?> setupWith(BuildContext context, S s, String lang, Api api) =>
      Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => EmergencySetupPage(s: s, api: api),
        ),
      );

  @override
  Widget teacherSession(Settings settings, SessionInfo session, {bool showQr = false}) =>
      EmergencySessionPage(settings: settings, session: session, showQrOnOpen: showQr);

  @override
  Widget play(PlayContext ctx) => EmergencyPlay(ctx: ctx);
}
