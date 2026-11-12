import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
  // pending_<token> went with the keys above; answers still in the old shared list go too.
  final raw = p.getString(SubmissionQueue._sharedKey);
  if (raw != null) {
    final left = [for (final e in jsonDecode(raw) as List) if ((e as Map)['token'] != token) e];
    await p.setString(SubmissionQueue._sharedKey, jsonEncode(left));
  }
}

/// Answers waiting to be sent, one queue per session (QR token). Kept on the device so a lost connection loses
/// nothing, and sent with the id made for each answer, so sending one again never stores it twice.
///
/// - Changes to the stored list go one at a time (a lock per session), and each sent answer is removed by its
///   id, so an answer added while others are being sent is never written over.
/// - Only one flush per session runs at a time; a second one waits for it and then sends what is left.
/// - An answer stays until the server has it or refuses it for good: a lost connection, a busy or failing
///   server, a paused session or an unexpected error keep it for the next try.
class SubmissionQueue {
  /// Before per-session queues, every session's answers were kept here together.
  static const _sharedKey = 'pending_submissions';
  static final _locks = <String, Future<void>>{};
  static final _flushing = <String, Future<String?>>{};

  final String token;
  final Future<dynamic> Function(Map<String, dynamic>) send;

  /// Gets the server's reply to each accepted item, such as the score and the right answer of a game whose
  /// answers stay on the server.
  final void Function(Map<String, dynamic> item, Map<String, dynamic> reply)? onReply;
  SubmissionQueue(this.token, this.send, {this.onReply});

  /// For tests: forgets the locks and running flushes. A widget test can end with a send still waiting on its
  /// fake clock, which would otherwise hold up the next test of the same session forever.
  @visibleForTesting
  static void forgetRunning() {
    _locks.clear();
    _flushing.clear();
  }

  // Ends with the token, so starting over (forgetSessionOnDevice) removes it with the rest of the session.
  String get _key => 'pending_$token';

  /// Runs [action] after every earlier change to this session's queue has finished.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = (_locks[_key] ?? Future<void>.value()).then((_) => action());
    _locks[_key] = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<List<Map<String, dynamic>>> _read() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    final items = raw == null ? <Map<String, dynamic>>[] : _decode(raw);
    // Answers of this session still in the old shared list move here, once.
    final shared = p.getString(_sharedKey);
    if (shared != null) {
      final all = _decode(shared);
      final mine = all.where((e) => e['token'] == token).toList();
      if (mine.isNotEmpty) {
        final known = items.map((e) => e['submissionId']).toSet();
        items.addAll(mine.where((e) => !known.contains(e['submissionId'])));
        await p.setString(_key, jsonEncode(items));
        final rest = all.where((e) => e['token'] != token).toList();
        rest.isEmpty ? await p.remove(_sharedKey) : await p.setString(_sharedKey, jsonEncode(rest));
      }
    }
    return items;
  }

  static List<Map<String, dynamic>> _decode(String raw) =>
      [for (final e in jsonDecode(raw) as List) (e as Map).cast<String, dynamic>()];

  Future<void> _write(List<Map<String, dynamic>> items) async {
    final p = await SharedPreferences.getInstance();
    items.isEmpty ? await p.remove(_key) : await p.setString(_key, jsonEncode(items));
  }

  Future<int> pending() => _locked(() async => (await _read()).length);

  /// Keeps an answer for sending. The same submission id twice is kept once.
  Future<void> add(Map<String, dynamic> submission) => _locked(() async {
    final items = await _read();
    if (items.any((e) => e['submissionId'] == submission['submissionId'])) return;
    await _write([...items, submission]);
  });

  Future<void> _remove(Object? submissionId) => _locked(() async {
    final items = await _read();
    await _write(items.where((e) => e['submissionId'] != submissionId).toList());
  });

  /// Sends in order and removes what the server accepted or refused for good. Stops at the first problem that
  /// may pass (no connection, a busy or failing server, a paused session), keeping the rest for later.
  /// Returns the error code of the last refused item, or 'session_paused' if the session is paused.
  Future<String?> flush() async {
    while (_flushing[_key] != null) {
      await _flushing[_key];
    }
    final run = _flushOnce();
    _flushing[_key] = run;
    try {
      return await run;
    } finally {
      if (identical(_flushing[_key], run)) _flushing.remove(_key);
    }
  }

  Future<String?> _flushOnce() async {
    String? refused;
    while (true) {
      final items = await _locked(_read);
      if (items.isEmpty) break;
      final item = items.first;
      try {
        final reply = await send(item);
        await _remove(item['submissionId']);
        if (reply is Map<String, dynamic>) onReply?.call(item, reply);
      } on NoConnection {
        break;
      } on ApiError catch (e) {
        // Not refused for good: tried again later. The server keeps the first copy of an answer, so a retry
        // of one it already has is harmless.
        if (e.status == 408 || e.status == 429 || e.status >= 500) break;
        if (e.key == 'session_paused') {
          refused = e.key;
          break;
        }
        refused = e.key;
        await _remove(item['submissionId']);
      } on Exception {
        // A reply that couldn't be read: the answer may or may not have arrived, so it is sent again later.
        break;
      }
    }
    return refused;
  }
}
