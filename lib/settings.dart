import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

const githubUrl = 'https://github.com/GIS-GEORGIA/geoclass';

/// Device preferences. The teacher key and QR tokens stay on this device only.
class Settings extends ChangeNotifier {
  String lang = 'ka';
  ThemeMode theme = ThemeMode.system;
  String? teacherKey;
  LatLng origin = const LatLng(41.691, 44.834); // Tbilisi until the teacher sets a start point
  Map<String, String> _tokens = {};

  S get s => S(lang);
  bool get isTeacher => teacherKey != null;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      lang = p.getString('lang') ?? lang;
      theme = ThemeMode.values.firstWhere(
        (m) => m.name == p.getString('theme'),
        orElse: () => ThemeMode.system,
      );
      teacherKey = p.getString('teacher_key');
      final o = p.getStringList('origin');
      if (o != null && o.length == 2) origin = LatLng(double.parse(o[0]), double.parse(o[1]));
      final t = p.getString('qr_tokens');
      if (t != null) _tokens = (jsonDecode(t) as Map).cast<String, String>();
    } catch (_) {}
  }

  Future<void> setLang(String v) async {
    lang = v;
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).setString('lang', v);
    } catch (_) {}
  }

  Future<void> setTheme(ThemeMode v) async {
    theme = v;
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).setString('theme', v.name);
    } catch (_) {}
  }

  Future<void> setTeacherKey(String? v) async {
    teacherKey = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (v == null) {
      await p.remove('teacher_key');
    } else {
      await p.setString('teacher_key', v);
    }
  }

  Future<void> setOrigin(LatLng v) async {
    origin = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setStringList('origin', ['${v.latitude}', '${v.longitude}']);
  }

  String? tokenFor(String sessionId) => _tokens[sessionId];

  Future<void> setToken(String sessionId, String token) async {
    _tokens[sessionId] = token;
    (await SharedPreferences.getInstance()).setString('qr_tokens', jsonEncode(_tokens));
  }
}
