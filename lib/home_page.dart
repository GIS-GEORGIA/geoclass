import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'aerial_setup_page.dart';
import 'cards.dart';
import 'cards_setup_page.dart';
import 'evidence.dart';
import 'evidence_setup_page.dart';
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
      builder: (_) => sessionPageFor(widget.settings, session, showQr: showQr),
    ));
    _load();
  }

  Future<void> _create() async {
    final ctl = TextEditingController();
    var game = 'travel';
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(s['new_session']),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s['game_choose'], style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              RadioGroup<String>(
                groupValue: game,
                onChanged: (v) => setDialog(() => game = v!),
                child: Column(
                  children: [
                    for (final g in const ['travel', 'coordinates', 'aerial', 'evidence', 'mapping', 'cards', 'plates', 'puzzle', 'layout'])
                      RadioListTile<String>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: g,
                        title: Text(s['game_$g']),
                      ),
                  ],
                ),
              ),
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
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: Text(game == 'travel' || game == 'mapping' ? s['create'] : s['next']),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;

    List<CoordTask>? tasks;
    Deck? deck;
    List<EvidenceTask>? evidence;
    List<PlateSpec>? plates;
    PuzzleSpec? puzzle;
    LayoutSpec? layout;
    if (game == 'layout') {
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
      evidence = await Navigator.of(context).push<List<EvidenceTask>>(MaterialPageRoute(
        builder: (_) => EvidenceSetupPage(s: s),
      ));
      if (evidence == null) return;
    } else if (game == 'cards') {
      deck = await Navigator.of(context).push<Deck>(MaterialPageRoute(
        builder: (_) => CardsSetupPage(s: s, lang: widget.settings.lang),
      ));
      if (deck == null) return;
    } else if (game == 'coordinates') {
      tasks = await Navigator.of(context).push<List<CoordTask>>(MaterialPageRoute(
        builder: (_) => CoordinatesSetupPage(s: s),
      ));
      if (tasks == null) return;
    } else if (game == 'aerial') {
      tasks = await Navigator.of(context).push<List<CoordTask>>(MaterialPageRoute(
        builder: (_) => AerialSetupPage(s: s, lang: widget.settings.lang),
      ));
      if (tasks == null) return;
    }
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
      );
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
            tooltip: s['site_qr_title'],
            icon: const Icon(Icons.qr_code),
            onPressed: () => _showSiteQr(context, s),
          ),
          IconButton(
            tooltip: s['show_archived'],
            isSelected: _showArchived,
            icon: const Icon(Icons.inventory_2_outlined),
            selectedIcon: const Icon(Icons.inventory_2),
            onPressed: () => setState(() => _showArchived = !_showArchived),
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
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(s['keep_note'], style: Theme.of(context).textTheme.bodySmall),
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
                                leading: Icon(switch (x.game) {
                                  'coordinates' => Icons.my_location,
                                  'aerial' => Icons.satellite_alt,
                                  'mapping' => Icons.draw,
                                  'cards' => Icons.style,
                                  'evidence' => Icons.receipt_long,
                                  'plates' => Icons.palette_outlined,
                                  'puzzle' => Icons.extension,
                                  'layout' => Icons.map_outlined,
                                  _ => Icons.travel_explore,
                                }),
                                title: Text(x.name),
                                subtitle: Text([
                                  s['game_${x.game}'],
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
