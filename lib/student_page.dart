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
import 'nickname_dialog.dart';
import 'nicknames.dart';
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
  // Ends with the token, so starting over (forgetSessionOnDevice) removes it too.
  String get _nickKey => 'nick_${widget.token}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _stage = _Stage.loading);
    final prefs = await SharedPreferences.getInstance();
    // Made before anything of this session is kept on the device: a session the device was already playing
    // before ids were per session is told apart from a new one by what is kept (see participantId).
    final pid = await participantId(widget.token);
    final picked = prefs.getString(_nickKey);
    rememberNicknames(picked == null ? const {} : {pid: picked}, forIds: [pid]);
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
    final n = await _api.forget(widget.token, await participantId(widget.token));
    await forgetSessionOnDevice(widget.token);
    if (mounted) {
      setState(() => _generation++);
      _load();
    }
    return n;
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _problem(Object e) => s.f('failed', [e is ApiError ? s[e.key] : s['no_connection']]);

  /// The student picks a made-up name for this session, or goes back to the automatic one.
  Future<void> _pickNickname() async {
    final pid = await participantId(widget.token);
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => NicknameDialog(s: s, lang: widget.settings.lang, current: nickname(pid, widget.settings.lang)),
    );
    if (picked == null || !mounted) return;
    try {
      final saved = await _api.setNickname(widget.token, pid, picked.isEmpty ? null : picked);
      final prefs = await SharedPreferences.getInstance();
      saved == null ? await prefs.remove(_nickKey) : await prefs.setString(_nickKey, saved);
      rememberNicknames(saved == null ? const {} : {pid: saved}, forIds: [pid]);
      if (!mounted) return;
      setState(() {});
      _say(s.f('nick_saved', [nickname(pid, widget.settings.lang)]));
    } on ApiError catch (e) {
      if (mounted) _say(_problem(e));
    } on NoConnection catch (e) {
      if (mounted) _say(_problem(e));
    }
  }

  /// Finish / start over: the answers go, on the server and here, and a new id and name come with the next start.
  Future<void> _startOver() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['start_over']),
        content: Text(s['start_over_body']),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s['start_over_do']),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      final n = await _forget();
      if (mounted) _say(s.f('forget_done', [n]));
    } on ApiError catch (e) {
      if (mounted) _say(_problem(e));
    } on NoConnection catch (e) {
      if (mounted) _say(_problem(e));
    }
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
            if (_stage == _Stage.form)
              PopupMenuButton<String>(
                tooltip: s['nick_menu'],
                icon: const Icon(Icons.person_outline),
                onSelected: (v) => v == 'nick' ? _pickNickname() : _startOver(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'nick', child: ListTile(leading: const Icon(Icons.badge_outlined), title: Text(s['nick_title']))),
                  PopupMenuItem(value: 'over', child: ListTile(leading: const Icon(Icons.restart_alt), title: Text(s['start_over']))),
                ],
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
