import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../l10n.dart';
import 'frame_map.dart';
import 'timelapse.dart';

String _errorText(S s, Object e) => e is ApiError ? s[e.key] : s['no_connection'];

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<String?> _askName(BuildContext context, S s, String initial) async {
  final ctl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s['emergency_template_name']),
      content: TextField(
        key: const Key('timelapse_template_name'),
        controller: ctl,
        autofocus: true,
        maxLength: 80,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s['cancel'])),
        FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: Text(s['ok'])),
      ],
    ),
  );
  ctl.dispose();
  return name == null || name.trim().isEmpty ? null : name.trim();
}

/// The teacher's time-lapse templates: make one for a site, outline its two years, pick the one a new
/// session uses. Returns the session's settings, {timelapse: {template: id}}.
class TimelapseSetupPage extends StatefulWidget {
  final S s;
  final String lang;
  final Api api;
  final FrameLoader? loader;
  const TimelapseSetupPage({super.key, required this.s, required this.lang, required this.api, this.loader});
  @override
  State<TimelapseSetupPage> createState() => _TimelapseSetupPageState();
}

class _TimelapseSetupPageState extends State<TimelapseSetupPage> {
  late final _templates = TimelapseTemplateApi(widget.api);
  late final _loader = widget.loader ?? FrameLoader();
  List<TimelapseTemplate>? _list;
  List<TimelapseSite> _sites = const [];
  String? _error, _chosen;
  bool _busy = false;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (list, sites) = (await _templates.list(), await _loader.catalog());
      if (!mounted) return;
      setState(() {
        _list = list;
        _sites = sites;
        _error = null;
        if (!list.any((t) => t.id == _chosen)) _chosen = list.isEmpty ? null : list.first.id;
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = _errorText(s, e));
    }
  }

  Future<void> _new() async {
    if (_sites.isEmpty) return;
    final site = await showDialog<TimelapseSite>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(s['timelapse_pick_site']),
        children: [
          for (final x in _sites)
            SimpleDialogOption(
              key: Key('timelapse_site_${x.id}'),
              onPressed: () => Navigator.pop(context, x),
              child: Text('${x.title(widget.lang)} (${x.years.first}–${x.years.last})'),
            ),
        ],
      ),
    );
    if (site == null || !mounted) return;
    final name = await _askName(context, s, site.title(widget.lang));
    if (name == null || !mounted) return;
    try {
      final t = await _templates.create(
        name,
        TimelapseData(site.id, site.version, site.years.first, site.years.last, const [], const []),
      );
      _chosen = t.id;
      await _edit(t.id);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    }
  }

  Future<void> _edit(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TimelapseEditorPage(s: s, lang: widget.lang, templates: _templates, loader: _loader, id: id),
      ),
    );
    await _load();
  }

  Future<void> _delete(TimelapseTemplate t) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.f('emergency_delete_template', [t.name])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s['cancel'])),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s['delete'])),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await _templates.delete(t.id);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    }
    await _load();
  }

  /// Only a finished template makes a session: two years in order, an outline on each.
  Future<void> _use() async {
    final id = _chosen;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final t = await _templates.get(id);
      if (!mounted) return;
      final missing = t.data == null ? 'outline' : t.data!.missing();
      if (missing == null) {
        Navigator.pop(context, {
          'timelapse': {'template': id},
        });
        return;
      }
      _say(context, s['timelapse_unfinished_$missing']);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text(s['game_timelapse'])),
      floatingActionButton: _sites.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('timelapse_new_template'),
              onPressed: _new,
              icon: const Icon(Icons.add),
              label: Text(s['emergency_new_template']),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            key: const Key('timelapse_use'),
            onPressed: _chosen == null || _busy ? null : _use,
            child: Text(s['create']),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Card(
                child: Padding(padding: const EdgeInsets.all(12), child: Text(s['timelapse_setup_hint'])),
              ),
              const SizedBox(height: 8),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (list == null && _error == null) const Center(child: CircularProgressIndicator()),
              if (list != null && list.isEmpty)
                Padding(padding: const EdgeInsets.all(16), child: Text(s['emergency_no_templates'])),
              RadioGroup<String>(
                groupValue: _chosen,
                onChanged: (v) => setState(() => _chosen = v),
                child: Column(
                  children: [
                    for (final t in list ?? const <TimelapseTemplate>[])
                      ListTile(
                        key: Key('timelapse_template_${t.id}'),
                        leading: Radio<String>(value: t.id),
                        title: Text(t.name),
                        onTap: () => setState(() => _chosen = t.id),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(tooltip: s['edit'], icon: const Icon(Icons.edit), onPressed: () => _edit(t.id)),
                            IconButton(
                              tooltip: s['delete'],
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(t),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One template: its two years and the outline on each, drawn on that year's frame.
class TimelapseEditorPage extends StatefulWidget {
  final S s;
  final String lang;
  final TimelapseTemplateApi templates;
  final FrameLoader loader;
  final String id;
  const TimelapseEditorPage({
    super.key,
    required this.s,
    required this.lang,
    required this.templates,
    required this.loader,
    required this.id,
  });
  @override
  State<TimelapseEditorPage> createState() => _TimelapseEditorPageState();
}

class _TimelapseEditorPageState extends State<TimelapseEditorPage> {
  final _map = MapController();
  String? _name, _error;
  TimelapseData? _data;
  SiteFrames? _site;
  late OutlineDraft _a, _b;
  int _which = 0; // 0: year A, 1: year B
  bool _changed = false, _saving = false;

  S get s => widget.s;

  OutlineDraft _draft(Outline o) => OutlineDraft(o, const [], maxRings: maxTruthRings, maxVertices: maxTruthVertices);

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final t = await widget.templates.get(widget.id);
      final d = t.data;
      if (d == null) throw ApiError(400, 'bad_timelapse');
      final site = await widget.loader.site(d.site, d.version);
      if (!mounted) return;
      setState(() {
        _name = t.name;
        _data = d;
        _site = site;
        _a = _draft(d.truthA);
        _b = _draft(d.truthB);
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = _errorText(s, e));
    }
  }

  TimelapseData get _current =>
      TimelapseData(_data!.site, _data!.version, _data!.yearA, _data!.yearB, _a.outline, _b.outline);

  void _set(OutlineDraft d) => setState(() {
    _which == 0 ? _a = d : _b = d;
    _changed = true;
  });

  void _tap(LatLng p) {
    final d = _which == 0 ? _a : _b;
    final near = d.draft.isNotEmpty && nearOnScreen(_map.camera, d.draft.first, p);
    _set(d.tap(p, near: near));
  }

  void _year(int which, int year) => setState(() {
    final d = _data!;
    _data = TimelapseData(
      d.site,
      d.version,
      which == 0 ? year : d.yearA,
      which == 1 ? year : d.yearB,
      d.truthA,
      d.truthB,
    );
    _changed = true;
  });

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final data = _current;
      await widget.templates.save(widget.id, _name!, data);
      if (!mounted) return;
      setState(() {
        _data = data;
        _a = _draft(data.truthA);
        _b = _draft(data.truthB);
        _changed = false;
      });
      _say(context, s['saved']);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename() async {
    final name = await _askName(context, s, _name ?? '');
    if (name != null) {
      setState(() {
        _name = name;
        _changed = true;
      });
    }
  }

  Widget _yearPicker(int which, List<Frame> frames, int year) => DropdownButton<int>(
    key: Key('timelapse_year_${which == 0 ? 'a' : 'b'}'),
    value: frames.any((f) => f.year == year) ? year : null,
    items: [for (final f in frames) DropdownMenuItem(value: f.year, child: Text('${f.year}'))],
    onChanged: (v) {
      if (v != null) _year(which, v);
    },
  );

  @override
  Widget build(BuildContext context) {
    final name = _name, data = _data, site = _site;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s['emergency_unsaved']),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s['cancel'])),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s['emergency_leave'])),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          setState(() => _changed = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(name ?? ''),
          actions: [
            if (name != null)
              IconButton(tooltip: s['emergency_rename'], icon: const Icon(Icons.edit), onPressed: _rename),
            IconButton(
              key: const Key('timelapse_save'),
              tooltip: s['save'],
              icon: const Icon(Icons.save),
              onPressed: name == null || _saving || !_changed ? null : _save,
            ),
          ],
        ),
        body: _error != null
            ? Center(child: Text(_error!))
            : name == null || data == null || site == null
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, box) {
                  final d = _which == 0 ? _a : _b;
                  final year = _which == 0 ? data.yearA : data.yearB;
                  final colour = _which == 0 ? Colors.amber : Colors.cyanAccent;
                  final controls = ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Text(s['timelapse_editor_hint']),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(s['timelapse_year_a']),
                          const SizedBox(width: 8),
                          _yearPicker(0, site.frames, data.yearA),
                          const SizedBox(width: 16),
                          Text(s['timelapse_year_b']),
                          const SizedBox(width: 8),
                          _yearPicker(1, site.frames, data.yearB),
                        ],
                      ),
                      if (data.yearA >= data.yearB)
                        Text(s['timelapse_unfinished_years'], style: TextStyle(color: scheme.error)),
                      const SizedBox(height: 12),
                      SegmentedButton<int>(
                        key: const Key('timelapse_which'),
                        segments: [
                          ButtonSegment(value: 0, label: Text('${s['timelapse_year_a']} ${data.yearA}')),
                          ButtonSegment(value: 1, label: Text('${s['timelapse_year_b']} ${data.yearB}')),
                        ],
                        selected: {_which},
                        onSelectionChanged: (v) => setState(() => _which = v.first),
                      ),
                      const SizedBox(height: 8),
                      drawTools(s, d, _set),
                      const SizedBox(height: 8),
                      Text(
                        '${s['timelapse_year_a']} ${data.yearA}: ${km2Text(outlineArea(_a.outline))} km² · '
                        '${s['timelapse_year_b']} ${data.yearB}: ${km2Text(outlineArea(_b.outline))} km²',
                      ),
                      Text(s.f('timelapse_change', [changeText(outlineArea(_a.outline), outlineArea(_b.outline))])),
                      const SizedBox(height: 8),
                      Text(site.attribution.join(' · '), style: Theme.of(context).textTheme.bodySmall),
                    ],
                  );
                  final map = FrameMap(
                    controller: _map,
                    site: site,
                    frame: site.frameOf(year),
                    onTap: _tap,
                    layers: [outlineLayer(d.rings, colour), ...draftLayers(d.draft, colour)],
                  );
                  return box.maxWidth >= 900
                      ? Row(
                          children: [
                            Expanded(child: map),
                            SizedBox(width: 360, child: controls),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 3, child: map),
                            Expanded(flex: 2, child: controls),
                          ],
                        );
                },
              ),
      ),
    );
  }
}
