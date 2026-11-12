import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Random URL-safe id, used for the anonymous participant and each submission.
String randomId() {
  final r = Random.secure();
  return base64UrlEncode(List.generate(18, (_) => r.nextInt(256)));
}

/// The anonymous id of this student in one session (one QR code). Every session gets its own, so two sessions
/// can't be linked by it. Starting over removes it with the rest of the session (forgetSessionOnDevice), and the
/// next one is new. No name or contact is ever attached to it.
Future<String> participantId(String token) async {
  final p = await SharedPreferences.getInstance();
  final key = 'pid_$token';
  final id = p.getString(key);
  if (id != null) return id;
  // Before per-session ids one id served every session. A session this device was already playing keeps it,
  // so its earlier answers stay together; any other session gets a new one.
  final shared = p.getString('participant_id');
  final playing = shared != null && p.getKeys().any((k) => k.endsWith('_$token'));
  final fresh = playing ? shared : randomId();
  await p.setString(key, fresh);
  return fresh;
}

/// After the student erased their answers: nothing of this session stays on the device either
/// (unsent answers, game progress, the cached session).
Future<void> forgetSessionOnDevice(String token) async {
  final p = await SharedPreferences.getInstance();
  for (final key in p.getKeys().where((k) => k.endsWith('_$token')).toList()) {
    await p.remove(key);
  }
  final raw = p.getString(SubmissionQueue._key);
  if (raw != null) {
    final left = [for (final e in jsonDecode(raw) as List) if ((e as Map)['token'] != token) e];
    await p.setString(SubmissionQueue._key, jsonEncode(left));
  }
}

/// Answers waiting to be sent. Kept on the device so a lost connection loses nothing.
class SubmissionQueue {
  static const _key = 'pending_submissions';
  final Future<dynamic> Function(Map<String, dynamic>) send;

  /// Gets the server's reply to each accepted item, such as the score and the right answer of a game whose
  /// answers stay on the server.
  final void Function(Map<String, dynamic> item, Map<String, dynamic> reply)? onReply;
  SubmissionQueue(this.send, {this.onReply});

  Future<List<Map<String, dynamic>>> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    return [for (final e in jsonDecode(raw) as List) (e as Map).cast<String, dynamic>()];
  }

  Future<void> _write(List<Map<String, dynamic>> items) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(items));

  Future<int> pending() async => (await _read()).length;

  Future<void> add(Map<String, dynamic> submission) async => _write([...await _read(), submission]);

  /// Sends in order and removes what the server accepted or finally refused.
  /// Stops at the first connection problem, keeping the rest for later.
  /// Returns the error code of a refused item from the last pass, if any.
  Future<String?> flush() async {
    final items = await _read();
    String? refused;
    while (items.isNotEmpty) {
      try {
        final reply = await send(items.first);
        if (reply is Map<String, dynamic>) onReply?.call(items.first, reply);
      } on NoConnection {
        break;
      } on ApiError catch (e) {
        if (e.status == 429 || e.status >= 500) break;
        refused = e.key;
      }
      items.removeAt(0);
      await _write(items);
    }
    return refused;
  }
}
