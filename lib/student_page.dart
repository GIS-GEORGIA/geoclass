import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cards_play.dart';
import 'coordinates_play.dart';
import 'evidence.dart';
import 'evidence_play.dart';
import 'games/game.dart';
import 'games/registry.dart';
import 'l10n.dart';
import 'mapping_play.dart';
import 'models.dart';
import 'plates_play.dart';
import 'puzzle_play.dart';
import 'layout_play.dart';
import 'privacy_info.dart';
import 'queue.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'student_message.dart';

enum _Stage { loading, gone, noConnection, form }

/// What a student sees after scanning the QR code. No account, no name.
class StudentPage extends StatefulWidget {
  final Settings settings;
  final String token;
  const StudentPage({super.key, required this.settings, required this.token});
  @override
  State<StudentPage> createState() => _StudentPageState();
}

class _StudentPageState extends State<StudentPage> {
  final _api = Api();

  _Stage _stage = _Stage.loading;
  String _name = '';
  String _status = 'open';
  String _game = 'travel';
  List<CoordTask> _tasks = const [];
  int _resetAt = 0;
  Map<String, dynamic> _settings = const {};
  int _now = 0;
  int _generation = 0; // a new one restarts the game widgets, after the student erased their answers

  S get s => widget.settings.s;
  String get _cacheKey => 'join_${widget.token}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _stage = _Stage.loading);
    final prefs = await SharedPreferences.getInstance();
    try {
      final data = await _api.join(widget.token);
      await prefs.setString(_cacheKey, jsonEncode(data));
      _apply(data);
    } on ApiError catch (e) {
      if (mounted) setState(() => _stage = e.status == 404 ? _Stage.gone : _Stage.noConnection);
    } on NoConnection {
      // Opened again without internet: the form still works, the answer waits in the queue.
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        _apply(jsonDecode(cached) as Map<String, dynamic>);
      } else if (mounted) {
        setState(() => _stage = _Stage.noConnection);
      }
    }
  }

  void _apply(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      _name = data['name'] as String;
      _status = data['status'] as String;
      _game = data['game'] as String? ?? 'travel';
      final settings = data['settings'] as Map<String, dynamic>? ?? const {};
      _tasks = _game == 'coordinates' ? CoordTask.listFrom(settings) : const [];
      _resetAt = settings['resetAt'] as int? ?? 0;
      _settings = settings;
      _now = data['now'] as int? ?? deviceSeconds();
      _stage = _Stage.form;
    });
  }

  /// The student erases their answers in this session, on the server and on this device, and starts afresh.
  Future<int> _forget() async {
    final n = await _api.forget(widget.token, await participantId());
    await forgetSessionOnDevice(widget.token);
    if (mounted) {
      setState(() => _generation++);
      _load();
    }
    return n;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(_name.isEmpty ? s['app_title'] : _name),
          actions: [
            TextButton(
              onPressed: () => widget.settings.setLang(widget.settings.lang == 'ka' ? 'en' : 'ka'),
              child: Text(widget.settings.lang == 'ka' ? 'EN' : 'KA'),
            ),
            PrivacyInfoButton(s: s, onForget: _stage == _Stage.loading || _stage == _Stage.gone ? null : _forget),
            IconButton(
              tooltip: s['settings'],
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsPage(settings: widget.settings, teacherTools: false),
              )),
            ),
          ],
        ),
        body: SafeArea(child: KeyedSubtree(key: ValueKey(_generation), child: _body())),
      );

  Widget _body() => switch (_stage) {
        _Stage.loading => const Center(child: CircularProgressIndicator()),
        _Stage.gone => _message(Icons.link_off, s['session_gone']),
        _Stage.noConnection => _message(Icons.wifi_off, s['no_connection'], action: _load, actionLabel: s['retry']),
        _Stage.form when _status == 'paused' => _message(Icons.pause_circle, s['session_paused'], action: _load, actionLabel: s['retry']),
        _Stage.form when _status == 'closed' => _message(Icons.lock, s['session_closed']),
        _Stage.form when gameModule(_game) != null => gameModule(_game)!.play(PlayContext(
              s: s,
              lang: widget.settings.lang,
              token: widget.token,
              settings: _settings,
              now: _now,
              resetAt: _resetAt,
              api: _api,
              onStopped: (status) => setState(() => _status = status),
            )),
        _Stage.form when _game == 'cards' => CardsPlay(
            s: s,
            token: widget.token,
            settings: _settings,
            now: _now,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form when _game == 'evidence' => EvidencePlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            tasks: EvidenceTask.listFrom(_settings),
            resetAt: _resetAt,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form when _game == 'layout' => LayoutPlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            settings: _settings,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form when _game == 'puzzle' => PuzzlePlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            settings: _settings,
            now: _now,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form when _game == 'plates' => PlatesPlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            settings: _settings,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form when _game == 'mapping' => MappingPlay(
            s: s,
            token: widget.token,
            settings: _settings,
            now: _now,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form => CoordinatesPlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            tasks: _tasks,
            resetAt: _resetAt,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
      };

  Widget _message(IconData icon, String title, {String? body, VoidCallback? action, String? actionLabel}) =>
      StudentMessage(icon, title, body: body, action: action, actionLabel: actionLabel);
}
