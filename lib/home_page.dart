import 'package:flutter/material.dart';

import 'api.dart';
import 'l10n.dart';
import 'models.dart';
import 'session_page.dart';
import 'settings.dart';
import 'settings_page.dart';

/// The teacher's entry point: asks for the key once, then lists sessions.
class HomePage extends StatelessWidget {
  final Settings settings;
  const HomePage({super.key, required this.settings});

  @override
  Widget build(BuildContext context) => settings.isTeacher ? _SessionList(settings: settings) : _KeyPage(settings: settings);
}

void _openSettings(BuildContext context, Settings settings) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(settings: settings, teacherTools: settings.isTeacher),
    ));

class _KeyPage extends StatefulWidget {
  final Settings settings;
  const _KeyPage({required this.settings});
  @override
  State<_KeyPage> createState() => _KeyPageState();
}

class _KeyPageState extends State<_KeyPage> {
  final _ctl = TextEditingController();
  String? _error;
  bool _busy = false;

  S get s => widget.settings.s;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    final key = _ctl.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api(teacherKey: key).checkKey();
      await widget.settings.setTeacherKey(key);
    } on ApiError catch (e) {
      setState(() => _error = e.status == 401 ? 'key_wrong' : e.key);
    } on NoConnection {
      setState(() => _error = 'no_connection');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(s['app_title']),
          actions: [
            IconButton(
              tooltip: s['settings'],
              icon: const Icon(Icons.settings),
              onPressed: () => _openSettings(context, widget.settings),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(s['key_title'], style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(s['key_hint']),
                const SizedBox(height: 16),
                TextField(
                  controller: _ctl,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: s['key_label'],
                    border: const OutlineInputBorder(),
                    errorText: _error == null ? null : s[_error!],
                  ),
                  onSubmitted: (_) => _enter(),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _enter, child: Text(s['key_enter'])),
              ],
            ),
          ),
        ),
      );
}

class _SessionList extends StatefulWidget {
  final Settings settings;
  const _SessionList({required this.settings});
  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  late final _api = Api(teacherKey: widget.settings.teacherKey);
  List<SessionInfo>? _sessions;
  String? _error;
  String _query = '';
  bool _showArchived = false;

  S get s => widget.settings.s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.sessions();
      if (mounted) {
        setState(() {
          _sessions = list;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (e.status == 401) {
        await widget.settings.setTeacherKey(null);
      } else if (mounted) {
        setState(() => _error = e.key);
      }
    } on NoConnection {
      if (mounted) setState(() => _error = 'no_connection');
    }
  }

  Future<void> _open(SessionInfo session, {bool showQr = false}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionPage(settings: widget.settings, session: session, showQrOnOpen: showQr),
    ));
    _load();
  }

  Future<void> _create() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['new_session']),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s['game_travel'], style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: s['session_name'],
                hintText: s['session_name_hint'],
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s['cancel'])),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(s['create'])),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      final (session, token) = await _api.createSession(name.trim(), 'travel');
      await widget.settings.setToken(session.id, token);
      await _open(session, showQr: true);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.f('failed', [e is ApiError ? s[e.key] : s['no_connection']]))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final visible = (_sessions ?? const <SessionInfo>[])
        .where((x) => (_showArchived || !x.archived) && x.name.toLowerCase().contains(q))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(s['sessions']),
        actions: [
          IconButton(
            tooltip: s['show_archived'],
            isSelected: _showArchived,
            icon: const Icon(Icons.inventory_2_outlined),
            selectedIcon: const Icon(Icons.inventory_2),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
          IconButton(
            tooltip: s['settings'],
            icon: const Icon(Icons.settings),
            onPressed: () async {
              _openSettings(context, widget.settings);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(s['new_session']),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _error != null && _sessions == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s[_error!]),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: Text(s['retry'])),
                  ],
                )
              : _sessions == null
                  ? const CircularProgressIndicator()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
                        children: [
                          TextField(
                            decoration: InputDecoration(
                              labelText: s['search_sessions'],
                              prefixIcon: const Icon(Icons.search),
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                          const SizedBox(height: 12),
                          if (visible.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                _sessions!.isEmpty ? s['no_sessions'] : s['no_match'],
                                textAlign: TextAlign.center,
                              ),
                            ),
                          for (final x in visible)
                            Card(
                              child: ListTile(
                                leading: const Icon(Icons.travel_explore),
                                title: Text(x.name),
                                subtitle: Text([
                                  s['status_${x.status}'],
                                  s.f('answers_count', [x.responses ?? 0]),
                                  if (x.archived) s['archived'],
                                ].join(' · ')),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _open(x),
                              ),
                            ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}
