import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

const _productionUrl = 'https://geoclass.qgis.ge';
const _apiBase = String.fromEnvironment('API_BASE');

/// Where the app is reachable. On web that is the page's own origin.
String get publicUrl => _apiBase.isNotEmpty ? _apiBase : (kIsWeb ? Uri.base.origin : _productionUrl);

/// The server answered with an error. `key` is a translation key or error code.
class ApiError implements Exception {
  final int status;
  final String key;
  ApiError(this.status, this.key);
  @override
  String toString() => key;
}

/// The server could not be reached at all.
class NoConnection implements Exception {}

class Polled {
  final SessionInfo session;
  final List<Map<String, dynamic>>? rows; // null when nothing changed
  Polled(this.session, this.rows);
}

class Api {
  final String? teacherKey;
  final http.Client _client;
  Api({this.teacherKey, http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _send(String method, String path, [Object? body]) async {
    final request = http.Request(method, Uri.parse('$publicUrl/api/$path'));
    request.headers['Content-Type'] = 'application/json';
    if (teacherKey != null) request.headers['Authorization'] = 'Bearer $teacherKey';
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 15)),
      );
    } on TimeoutException {
      throw NoConnection();
    } on http.ClientException {
      throw NoConnection();
    }

    Map<String, dynamic> data = const {};
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      if (response.statusCode < 400) throw ApiError(response.statusCode, 'internal');
    }
    if (response.statusCode >= 400) {
      throw ApiError(response.statusCode, data['error'] as String? ?? 'internal');
    }
    return data;
  }

  // Student
  Future<Map<String, dynamic>> join(String token) => _send('POST', 'join', {'token': token});
  Future<Map<String, dynamic>> submit(Map<String, dynamic> submission) => _send('POST', 'submit', submission);

  /// Deletes this device's answers in the session; returns how many there were.
  Future<int> forget(String token, String participantId) async =>
      ((await _send('POST', 'forget', {'token': token, 'participantId': participantId}))['deleted'] as num).toInt();

  // Teacher
  Future<void> checkKey() => _send('GET', 'me');

  /// Who this key is: {role: 'owner' | 'teacher', name, expiresAt}.
  Future<Map<String, dynamic>> me() => _send('GET', 'me');

  // Owner only: teacher accounts.
  Future<List<Map<String, dynamic>>> teachers() async =>
      ((await _send('GET', 'teachers'))['teachers'] as List).cast<Map<String, dynamic>>();

  /// A new teacher with a key valid for [amount] days, months or years ([unit]). The key is given only this once.
  Future<(Map<String, dynamic>, String)> createTeacher(String name, int amount, String unit) async {
    final data = await _send('POST', 'teachers', {'name': name, 'amount': amount, 'unit': unit});
    return (data['teacher'] as Map<String, dynamic>, data['key'] as String);
  }

  Future<void> updateTeacher(String id, Map<String, dynamic> changes) => _send('PATCH', 'teachers/$id', changes);

  Future<List<SessionInfo>> sessions() async {
    final data = await _send('GET', 'sessions');
    return [for (final s in data['sessions'] as List) SessionInfo.fromJson(s as Map<String, dynamic>)];
  }

  Future<(SessionInfo, String)> createSession(
    String name,
    String game, {
    List<CoordTask>? tasks,
    List<Map<String, dynamic>>? evidence,
    Map<String, dynamic>? cards,
    List<Map<String, dynamic>>? plates,
    Map<String, dynamic>? puzzle,
    Map<String, dynamic>? layout,
  }) async {
    final data = await _send('POST', 'sessions', {
      'name': name,
      'game': game,
      'tasks': ?(evidence ?? tasks?.map((t) => t.toJson()).toList()),
      'cards': ?cards,
      'plates': ?(plates == null ? null : {'deck': plates}),
      'puzzle': ?puzzle,
      'layout': ?layout,
    });
    return (SessionInfo.fromJson(data['session'] as Map<String, dynamic>), data['token'] as String);
  }

  Future<void> updateSession(String id, Map<String, dynamic> changes) => _send('PATCH', 'sessions/$id', changes);
  Future<void> deleteSession(String id) => _send('DELETE', 'sessions/$id');
  Future<void> resetResponses(String id) => _send('DELETE', 'sessions/$id/responses');
  Future<void> setTimer(String id, {required int seconds, List<double>? center, double? zoom}) => _send('POST', 'sessions/$id/timer', {
        'seconds': seconds,
        'center': ?center,
        'zoom': ?zoom,
      });
  /// The plates game: moves everyone to a plate (the deck's length is the end) and shows or hides its answer.
  Future<SessionInfo> setPlate(String id, {required int at, required bool revealed}) async {
    final data = await _send('POST', 'sessions/$id/plate', {'at': at, 'revealed': revealed});
    return SessionInfo.fromJson(data['session'] as Map<String, dynamic>);
  }

  Future<String> newToken(String id) async => (await _send('POST', 'sessions/$id/token'))['token'] as String;

  Future<Polled> poll(String id, int? rev) async {
    final data = await _send('GET', 'sessions/$id/responses${rev == null ? '' : '?rev=$rev'}');
    final session = SessionInfo.fromJson(data['session'] as Map<String, dynamic>);
    if (data['changed'] != true) return Polled(session, null);
    return Polled(session, (data['responses'] as List).cast<Map<String, dynamic>>());
  }

  Future<void> setHidden(String responseId, bool hidden) => _send('PATCH', 'responses/$responseId', {'hidden': hidden});
  Future<void> setAccepted(String responseId, bool accepted) =>
      _send('PATCH', 'responses/$responseId', {'accepted': accepted});
  Future<void> deleteResponse(String responseId) => _send('DELETE', 'responses/$responseId');

  Future<Map<String, dynamic>> backup({String? sessionId}) =>
      _send('GET', 'backup${sessionId == null ? '' : '?session=$sessionId'}');
  Future<void> restore(Map<String, dynamic> file) => _send('POST', 'restore', file);
}
