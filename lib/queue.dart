import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Random URL-safe id, used for the anonymous participant and each submission.
String randomId() {
  final r = Random.secure();
  return base64UrlEncode(List.generate(18, (_) => r.nextInt(256)));
}

/// The anonymous id of this device. No name or contact is ever attached to it.
Future<String> participantId() async {
  final p = await SharedPreferences.getInstance();
  var id = p.getString('participant_id');
  if (id == null) {
    id = randomId();
    await p.setString('participant_id', id);
  }
  return id;
}

/// Answers waiting to be sent. Kept on the device so a lost connection loses nothing.
class SubmissionQueue {
  static const _key = 'pending_submissions';
  final Future<void> Function(Map<String, dynamic>) send;
  SubmissionQueue(this.send);

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
        await send(items.first);
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
