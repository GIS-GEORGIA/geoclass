import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../coords.dart';
import '../geo_map.dart';
import '../l10n.dart';
import 'emergency.dart';

/// Picks a picture and returns its bytes, or null if the teacher cancelled. Tests give their own.
typedef PickPhoto = Future<Uint8List?> Function();

Future<Uint8List?> _pickPhoto() async {
  final picked = await FilePicker.pickFile(type: FileType.image);
  return picked?.xFile.readAsBytes();
}

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
        key: const Key('emergency_template_name'),
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

/// The teacher's templates for the 112 game: make, change, delete, and pick the one a new session uses.
/// Returns the session's settings, {emergency: {template: id}}.
class EmergencySetupPage extends StatefulWidget {
  final S s;
  final Api api;
  final PickPhoto? pick;
  const EmergencySetupPage({super.key, required this.s, required this.api, this.pick});
  @override
  State<EmergencySetupPage> createState() => _EmergencySetupPageState();
}

class _EmergencySetupPageState extends State<EmergencySetupPage> {
  late final _templates = TemplateApi(widget.api);
  List<EmergencyTemplate>? _list;
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
      final list = await _templates.list();
      if (!mounted) return;
      setState(() {
        _list = list;
        _error = null;
        if (!list.any((t) => t.id == _chosen)) _chosen = list.isEmpty ? null : list.first.id;
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = _errorText(s, e));
    }
  }

  Future<void> _new() async {
    final name = await _askName(context, s, '');
    if (name == null || !mounted) return;
    try {
      final t = await _templates.create(name);
      _chosen = t.id;
      await _edit(t.id);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    }
  }

  Future<void> _edit(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TemplateEditorPage(s: s, templates: _templates, id: id, pick: widget.pick),
      ),
    );
    await _load();
  }

  Future<void> _delete(EmergencyTemplate t) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.f('emergency_delete_template', [t.name])),
        content: Text(s['emergency_delete_template_hint']),
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

  /// Only a finished template makes a session: every point with its title, scenario and photos.
  Future<void> _use() async {
    final id = _chosen;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final t = await _templates.get(id);
      if (!mounted) return;
      final missing = t.points.isEmpty ? 'points' : t.points.map((p) => p.missing()).nonNulls.firstOrNull;
      if (missing != null) {
        _say(context, s['emergency_unfinished_$missing']);
        return;
      }
      Navigator.pop(context, {
        'emergency': {'template': id},
      });
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
      appBar: AppBar(title: Text(s['game_emergency'])),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('emergency_new_template'),
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: Text(s['emergency_new_template']),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            key: const Key('emergency_use'),
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
                child: Padding(padding: const EdgeInsets.all(12), child: Text(s['emergency_setup_hint'])),
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
                    for (final t in list ?? const <EmergencyTemplate>[])
                      ListTile(
                        key: Key('emergency_template_${t.id}'),
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

/// One template: its name and points. Saved with the Save button; photos are sent as soon as they are added.
class TemplateEditorPage extends StatefulWidget {
  final S s;
  final TemplateApi templates;
  final String id;
  final PickPhoto? pick;
  const TemplateEditorPage({super.key, required this.s, required this.templates, required this.id, this.pick});
  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> {
  String? _name, _error;
  List<EmergencyPoint> _points = const [];
  bool _changed = false, _saving = false;

  /// Photos taken out of a point here: deleted from the server once the template is saved without them.
  final _dropped = <String>{};

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    widget.templates
        .get(widget.id)
        .then(
          (t) {
            if (mounted) {
              setState(() {
                _name = t.name;
                _points = t.points;
              });
            }
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = _errorText(s, e));
          },
        );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.templates.save(widget.id, _name!, _points);
      final used = {for (final p in _points) ...p.photos.map((x) => x.id)};
      for (final photo in _dropped.where((x) => !used.contains(x)).toList()) {
        await widget.templates.deletePhoto(widget.id, photo);
        _dropped.remove(photo);
      }
      if (!mounted) return;
      setState(() => _changed = false);
      _say(context, s['saved']);
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editPoint(int? index) async {
    final result = await Navigator.of(context).push<(EmergencyPoint, Set<String>)>(
      MaterialPageRoute(
        builder: (_) => PointEditorPage(
          s: s,
          templates: widget.templates,
          templateId: widget.id,
          point: index == null ? null : _points[index],
          pick: widget.pick,
        ),
      ),
    );
    if (result == null) return;
    final (point, dropped) = result;
    setState(() {
      _points = [..._points];
      index == null ? _points.add(point) : _points[index] = point;
      _dropped.addAll(dropped);
      _changed = true;
    });
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

  @override
  Widget build(BuildContext context) {
    final name = _name;
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
              key: const Key('emergency_save'),
              tooltip: s['save'],
              icon: const Icon(Icons.save),
              onPressed: name == null || _saving || !_changed ? null : _save,
            ),
          ],
        ),
        floatingActionButton: name == null || _points.length >= maxPoints
            ? null
            : FloatingActionButton.extended(
                key: const Key('emergency_add_point'),
                onPressed: () => _editPoint(null),
                icon: const Icon(Icons.add_location_alt),
                label: Text(s['emergency_add_point']),
              ),
        body: _error != null
            ? Center(child: Text(_error!))
            : name == null
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 700),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    children: [
                      Text(s.f('emergency_points_count', [_points.length, maxPoints])),
                      const SizedBox(height: 8),
                      for (final (i, p) in _points.indexed)
                        Card(
                          child: ListTile(
                            key: Key('emergency_point_$i'),
                            leading: CircleAvatar(child: Text('${i + 1}')),
                            title: Text(p.title.isEmpty ? s['emergency_untitled'] : p.title),
                            subtitle: Text(
                              [
                                formatAs(p.format, p.lat, p.lon),
                                s['format_${p.format}'],
                                s.f('emergency_photos_count', [p.photos.length]),
                                if (p.missing() != null) s['emergency_unfinished_${p.missing()}'],
                              ].join(' · '),
                            ),
                            onTap: () => _editPoint(i),
                            trailing: IconButton(
                              tooltip: s['delete'],
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => setState(() {
                                _dropped.addAll(p.photos.map((x) => x.id));
                                _points = [..._points]..removeAt(i);
                                _changed = true;
                              }),
                            ),
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

/// One point: where (a tap on the map or typed), the scenario and its facts, the format asked for, and the
/// photos with the best one marked. Returns the point and the photos taken out of it.
class PointEditorPage extends StatefulWidget {
  final S s;
  final TemplateApi templates;
  final String templateId;
  final EmergencyPoint? point;
  final PickPhoto? pick;
  const PointEditorPage({
    super.key,
    required this.s,
    required this.templates,
    required this.templateId,
    this.point,
    this.pick,
  });
  @override
  State<PointEditorPage> createState() => _PointEditorPageState();
}

class _PointEditorPageState extends State<PointEditorPage> {
  late LatLng? _at = widget.point == null ? null : LatLng(widget.point!.lat, widget.point!.lon);
  late String _format = widget.point?.format ?? 'dd';
  late final _title = TextEditingController(text: widget.point?.title);
  late final _text = TextEditingController(text: widget.point?.text);
  late final _landmark = TextEditingController(text: widget.point?.facts.landmark);
  late final _coords = TextEditingController(
    text: widget.point == null ? '' : formatDd(widget.point!.lat, widget.point!.lon),
  );
  late String _kind = widget.point?.facts.kind ?? 'injury';
  late int _people = widget.point?.facts.people ?? 1;
  late bool _injured = widget.point?.facts.injured ?? true;
  late List<PointPhoto> _photos = [...?widget.point?.photos];
  late final _notes = [for (final p in _photos) TextEditingController(text: p.note)];
  late int _best = widget.point?.best ?? 0;
  final _dropped = <String>{};
  String? _coordError;
  bool _uploading = false;

  S get s => widget.s;

  @override
  void dispose() {
    for (final c in [_title, _text, _landmark, _coords, ..._notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Within Georgia and around it, as the server accepts.
  bool _inside(LatLng p) => p.latitude >= 40 && p.latitude <= 44.5 && p.longitude >= 39.5 && p.longitude <= 47.5;

  void _place(LatLng p) {
    if (!_inside(p)) {
      setState(() => _coordError = s['emergency_outside']);
      return;
    }
    setState(() {
      _at = p;
      _coordError = null;
      _coords.text = formatDd(p.latitude, p.longitude);
    });
  }

  void _typed() {
    final p = parseAny(_coords.text.trim());
    if (p == null) {
      setState(() => _coordError = s['setup_bad_coord']);
      return;
    }
    _place(p);
  }

  Future<void> _addPhoto() async {
    final bytes = await (widget.pick ?? _pickPhoto)();
    if (bytes == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final jpeg = preparePhoto(bytes);
      if (jpeg == null) {
        _say(context, s['emergency_photo_bad']);
        return;
      }
      final id = await widget.templates.upload(widget.templateId, jpeg);
      if (!mounted) return;
      setState(() {
        _photos = [..._photos, PointPhoto(id, '')];
        _notes.add(TextEditingController());
      });
    } on Exception catch (e) {
      if (mounted) _say(context, s.f('failed', [_errorText(s, e)]));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removePhoto(int i) => setState(() {
    _dropped.add(_photos[i].id);
    _photos = [..._photos]..removeAt(i);
    _notes.removeAt(i).dispose();
    if (_best >= _photos.length) _best = 0;
  });

  void _done() {
    final at = _at;
    if (at == null) {
      setState(() => _coordError = s['emergency_place_first']);
      return;
    }
    Navigator.pop(context, (
      EmergencyPoint(
        lat: double.parse(at.latitude.toStringAsFixed(6)),
        lon: double.parse(at.longitude.toStringAsFixed(6)),
        format: _format,
        title: _title.text.trim(),
        text: _text.text.trim(),
        facts: Facts(kind: _kind, people: _people, injured: _injured, landmark: _landmark.text.trim()),
        photos: [for (final (i, p) in _photos.indexed) PointPhoto(p.id, _notes[i].text.trim())],
        best: _best,
      ),
      _dropped,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final at = _at;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(s['emergency_point']),
        actions: [
          TextButton(
            key: const Key('emergency_point_done'),
            onPressed: _uploading ? null : _done,
            child: Text(s['ok']),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(s['emergency_place_hint']),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 280,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: at ?? const LatLng(42.2, 43.5),
                      initialZoom: at == null ? 6.5 : 15,
                      minZoom: 5,
                      onTap: (_, p) => _place(p),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      ...baseLayers(BaseMap.osm, 1),
                      if (at != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: at,
                              width: 36,
                              height: 36,
                              alignment: Alignment.topCenter,
                              child: Icon(Icons.location_on, color: scheme.error, size: 36),
                            ),
                          ],
                        ),
                      ...mapFurniture(BaseMap.osm),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('emergency_point_coords'),
                controller: _coords,
                decoration: InputDecoration(
                  labelText: s['setup_add_label'],
                  hintText: '41.69380, 44.80150',
                  errorText: _coordError,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(tooltip: s['ok'], icon: const Icon(Icons.check), onPressed: _typed),
                ),
                onSubmitted: (_) => _typed(),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('emergency_point_format'),
                initialValue: _format,
                isExpanded: true,
                decoration: InputDecoration(labelText: s['emergency_format_asked'], border: const OutlineInputBorder()),
                items: [for (final f in emergencyFormats) DropdownMenuItem(value: f, child: Text(s['format_$f']))],
                onChanged: (v) => setState(() => _format = v ?? _format),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('emergency_point_title'),
                controller: _title,
                maxLength: maxTitle,
                decoration: InputDecoration(labelText: s['emergency_title'], border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('emergency_point_text'),
                controller: _text,
                maxLength: maxText,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: s['emergency_scenario'],
                  helperText: s['emergency_scenario_hint'],
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(s['emergency_facts'], style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              factsFields(
                s: s,
                kind: _kind,
                people: _people,
                injured: _injured,
                landmark: _landmark,
                onKind: (v) => setState(() => _kind = v),
                onPeople: (v) => setState(() => _people = v),
                onInjured: (v) => setState(() => _injured = v),
                minPeople: 1,
              ),
              const SizedBox(height: 16),
              Text(s.f('emergency_photos', [minPhotos, maxPhotos]), style: Theme.of(context).textTheme.titleSmall),
              Text(s['emergency_photos_hint'], style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              RadioGroup<int>(
                groupValue: _best,
                onChanged: (v) => setState(() => _best = v ?? _best),
                child: Column(
                  children: [
                    for (final (i, p) in _photos.indexed)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 120,
                                height: 90,
                                child: Image.network(
                                  photoUrl(widget.templateId, p.id),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Radio<int>(key: Key('emergency_best_$i'), value: i),
                                        Expanded(child: Text(s['emergency_best'])),
                                        IconButton(
                                          tooltip: s['delete'],
                                          icon: const Icon(Icons.delete_outline),
                                          onPressed: () => _removePhoto(i),
                                        ),
                                      ],
                                    ),
                                    TextField(
                                      key: Key('emergency_note_$i'),
                                      controller: _notes[i],
                                      maxLength: maxNote,
                                      decoration: InputDecoration(labelText: s['emergency_note'], isDense: true),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_photos.length < maxPhotos)
                OutlinedButton.icon(
                  key: const Key('emergency_add_photo'),
                  onPressed: _uploading ? null : _addPhoto,
                  icon: _uploading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_photo_alternate),
                  label: Text(s['emergency_add_photo']),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The message fields, shared by the teacher's facts and the student's call.
Widget factsFields({
  required S s,
  required String? kind,
  required int? people,
  required bool? injured,
  required TextEditingController landmark,
  required ValueChanged<String> onKind,
  required ValueChanged<int> onPeople,
  required ValueChanged<bool> onInjured,
  int minPeople = 0,
  String keyPrefix = 'emergency',
}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    DropdownButtonFormField<String>(
      key: Key('${keyPrefix}_kind'),
      initialValue: kind,
      isExpanded: true,
      decoration: InputDecoration(labelText: s['emergency_kind'], border: const OutlineInputBorder()),
      items: [for (final k in emergencyKinds) DropdownMenuItem(value: k, child: Text(s['emergency_kind_$k']))],
      onChanged: (v) {
        if (v != null) onKind(v);
      },
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        Expanded(child: Text(s['emergency_people'])),
        IconButton(
          key: Key('${keyPrefix}_people_minus'),
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: people == null || people <= minPeople ? null : () => onPeople(people - 1),
        ),
        SizedBox(
          width: 32,
          child: Text(people == null ? '–' : '$people', key: Key('${keyPrefix}_people'), textAlign: TextAlign.center),
        ),
        IconButton(
          key: Key('${keyPrefix}_people_plus'),
          icon: const Icon(Icons.add_circle_outline),
          onPressed: (people ?? minPeople - 1) >= maxPeople
              ? null
              : () => onPeople(people == null ? minPeople.clamp(1, maxPeople) : people + 1),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        Expanded(child: Text(s['emergency_injured'])),
        SegmentedButton<bool>(
          key: Key('${keyPrefix}_injured'),
          emptySelectionAllowed: true,
          selected: {?injured},
          segments: [
            ButtonSegment(value: true, label: Text(s['yes'])),
            ButtonSegment(value: false, label: Text(s['no'])),
          ],
          onSelectionChanged: (v) {
            if (v.isNotEmpty) onInjured(v.first);
          },
        ),
      ],
    ),
    const SizedBox(height: 8),
    TextField(
      key: Key('${keyPrefix}_landmark'),
      controller: landmark,
      maxLength: maxLandmark,
      inputFormatters: [LengthLimitingTextInputFormatter(maxLandmark)],
      decoration: InputDecoration(
        labelText: s['emergency_landmark'],
        helperText: s['emergency_landmark_hint'],
        border: const OutlineInputBorder(),
      ),
    ),
  ],
);
