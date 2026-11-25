import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'cards.dart';
import 'cards_setup_page.dart';
import 'evidence.dart';
import 'evidence_setup_page.dart';
import 'games/registry.dart';
import 'plates.dart';
import 'plates_setup_page.dart';
import 'puzzle.dart';
import 'puzzle_setup_page.dart';
import 'layout.dart';
import 'layout_setup_page.dart';
import 'privacy_info.dart';
import 'api.dart';
import 'coordinates_setup_page.dart';
import 'l10n.dart';
import 'models.dart';
import 'session_page.dart';
import 'sessions/create_session_page.dart';
import 'sessions/session_filters.dart';
import 'sessions/session_widgets.dart';
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

/// A QR code of the site's own address, so nobody has to type it.
class _SiteQr extends StatelessWidget {
  final double size;
  const _SiteQr({required this.size});

  @override
  Widget build(BuildContext context) => ColoredBox(
        // White in both themes: phones read dark-on-light best.
        color: Colors.white,
        child: QrImageView(data: '$publicUrl/', size: size, backgroundColor: Colors.white, padding: const EdgeInsets.all(12)),
      );
}

void _showSiteQr(BuildContext context, S s) {
  final side = (MediaQuery.of(context).size.shortestSide - 96).clamp(180.0, 480.0);
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s['site_qr_title']),
      content: SizedBox(
        width: side,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SiteQr(size: side),
            const SizedBox(height: 8),
            SelectableText('$publicUrl/'),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s['close']))],
    ),
  );
}

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
      setState(() => _error = e.status == 401 && e.key != 'key_expired' ? 'key_wrong' : e.key);
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
            PrivacyInfoButton(s: s),
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
                Text(s['tagline'], style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
                const SizedBox(height: 16),
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
                const SizedBox(height: 16),
                Center(
                  child: InkWell(
                    onTap: () => _showSiteQr(context, s),
                    child: const _SiteQr(size: 140),
                  ),
                ),
                const SizedBox(height: 4),
                Center(child: Text(s['site_qr_hint'], style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center)),
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
  var _filter = const SessionFilter();
  final _search = TextEditingController();

  /// A session being made: a second click on Create while the first is on its way does nothing.
  bool _creating = false;

  S get s => widget.settings.s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _action(SessionInfo x, SessionAction a) async {
    switch (a) {
      case SessionAction.open:
        return _open(x);
      case SessionAction.qr:
        return _open(x, showQr: true);
      case SessionAction.delete:
        return _delete(x);
    }
  }

  /// Deletes a session after asking, naming it. The server deletes only the teacher's own (the owner's: any);
  /// its answers go with it.
  Future<void> _delete(SessionInfo x) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['delete_session']),
        content: Text(s.f('delete_confirm', [x.name, x.responses ?? 0])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
          FilledButton(
            key: const Key('session_delete_confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s['delete']),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await _api.deleteSession(x.id);
      if (!mounted) return;
      setState(() => _sessions = [...?_sessions]..removeWhere((y) => y.id == x.id));
      _say(s.f('session_deleted', [x.name]));
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        // Gone already, or not this teacher's: either way it isn't theirs to see.
        setState(() => _sessions = [...?_sessions]..removeWhere((y) => y.id == x.id));
      }
      _say(s.f('failed', [s[e.key]]));
    } on Exception {
      if (mounted) _say(s.f('failed', [s['no_connection']]));
    }
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
      builder: (_) => sessionPageFor(widget.settings, session, showQr: showQr),
    ));
    _load();
  }

  Future<void> _create() async {
    if (_creating) return;
    final counts = <String, int>{};
    for (final x in _sessions ?? const <SessionInfo>[]) {
      if (x.teacherName == null) counts[x.game] = (counts[x.game] ?? 0) + 1;
    }
    final picked = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => CreateSessionPage(s: s, counts: counts)),
    );
    if (picked == null || !mounted) return;
    final (game, name) = picked;
    if (!validSessionName(name)) return;

    List<CoordTask>? tasks;
    Deck? deck;
    List<EvidenceTask>? evidence;
    List<PlateSpec>? plates;
    PuzzleSpec? puzzle;
    LayoutSpec? layout;
    bool? offline; // evidence and cards: answers checked on the devices instead of the server
    Map<String, dynamic>? fields; // a game module's settings
    final module = gameModule(game);
    if (module != null) {
      fields = await module.setupWith(context, s, widget.settings.lang, _api);
      if (fields == null) return;
    } else if (game == 'layout') {
      layout = await Navigator.of(context).push<LayoutSpec>(MaterialPageRoute(
        builder: (_) => LayoutSetupPage(s: s, lang: widget.settings.lang),
      ));
      if (layout == null) return;
    } else if (game == 'puzzle') {
      puzzle = await Navigator.of(context).push<PuzzleSpec>(MaterialPageRoute(
        builder: (_) => PuzzleSetupPage(s: s, lang: widget.settings.lang),
      ));
      if (puzzle == null) return;
    } else if (game == 'plates') {
      plates = await Navigator.of(context).push<List<PlateSpec>>(MaterialPageRoute(
        builder: (_) => PlatesSetupPage(s: s),
      ));
      if (plates == null) return;
    } else if (game == 'evidence') {
      final picked = await Navigator.of(context).push<(List<EvidenceTask>, bool)>(MaterialPageRoute(
        builder: (_) => EvidenceSetupPage(s: s),
      ));
      if (picked == null) return;
      (evidence, offline) = picked;
    } else if (game == 'cards') {
      final picked = await Navigator.of(context).push<(Deck, bool)>(MaterialPageRoute(
        builder: (_) => CardsSetupPage(s: s, lang: widget.settings.lang),
      ));
      if (picked == null) return;
      (deck, offline) = picked;
    } else if (game == 'coordinates') {
      tasks = await Navigator.of(context).push<List<CoordTask>>(MaterialPageRoute(
        builder: (_) => CoordinatesSetupPage(s: s),
      ));
      if (tasks == null) return;
    }
    if (_creating || !mounted) return;
    setState(() => _creating = true);
    try {
      final (session, token) = await _api.createSession(
        name.trim(),
        game,
        tasks: tasks,
        evidence: evidence?.map((t) => t.toJson()).toList(),
        cards: deck?.toJson(),
        plates: plates?.map((p) => p.toJson()).toList(),
        puzzle: puzzle?.toJson(),
        layout: layout?.toJson(),
        answers: offline == null ? null : (offline ? 'offline' : 'online'),
        fields: fields,
      );
      await widget.settings.setToken(session.id, token);
      if (mounted) setState(() => _creating = false);
      await _open(session, showQr: true);
    } on Exception catch (e) {
      if (mounted) _say(s.f('failed', [e is ApiError ? s[e.key] : s['no_connection']]));
    } finally {
      if (mounted && _creating) setState(() => _creating = false);
    }
  }

  Widget _grid(List<SessionInfo> all) {
    final visible = filterSessions(all, _filter);
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 1100 ? 3 : (box.maxWidth >= 620 ? 2 : 1);
        return RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SessionToolbar(
                        s: s,
                        filter: _filter,
                        creators: creators(all),
                        search: _search,
                        onChanged: (f) => setState(() => _filter = f),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${s.f('sessions_shown', [visible.length, all.where((x) => _filter.archived || !x.archived).length])} · ${s['keep_note']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              if (visible.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Text(all.isEmpty ? s['no_sessions'] : s['no_match'], textAlign: TextAlign.center),
                        if (all.isNotEmpty && _filter.isFiltered)
                          TextButton(
                            onPressed: () => setState(() {
                              _search.clear();
                              _filter = _filter.reset();
                            }),
                            child: Text(s['filter_reset']),
                          ),
                      ],
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: sessionCardHeight,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => SessionCard(
                        s: s,
                        session: visible[i],
                        onAction: (a) => _action(visible[i], a),
                      ),
                      childCount: visible.length,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(s['sessions']),
        actions: [
          IconButton(
            tooltip: s['site_qr_title'],
            icon: const Icon(Icons.qr_code),
            onPressed: () => _showSiteQr(context, s),
          ),
          IconButton(
            tooltip: s['show_archived'],
            isSelected: _filter.archived,
            icon: const Icon(Icons.inventory_2_outlined),
            selectedIcon: const Icon(Icons.inventory_2),
            onPressed: () => setState(() => _filter = _filter.copyWith(archived: !_filter.archived)),
          ),
          PrivacyInfoButton(s: s),
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
        key: const Key('new_session'),
        onPressed: _creating ? null : _create,
        icon: _creating
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add),
        label: Text(s['new_session']),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
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
              : _grid(_sessions!),
        ),
      ),
    );
  }
}
