import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'answer_mode.dart';
import 'coords.dart';
import 'evidence.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'places.dart';

const maxEvidenceTasks = 30;

/// Picks well-known Georgian places as ready tasks: their names are the accepted answers.
List<EvidenceTask> randomEvidenceTasks(PlaceIndex index, int count, {Random? random}) {
  final r = random ?? Random();
  final pool = index.places.where((p) => p.country == 'GE' && p.ka.isNotEmpty).toList()..shuffle(r);
  return [
    for (final (i, p) in pool.take(count).indexed)
      () {
        final shown = evidenceFormats[r.nextInt(evidenceFormats.length)];
        final others = evidenceFormats.where((f) => f != shown).toList();
        return EvidenceTask(
          kind: evidenceKinds[i % evidenceKinds.length],
          lat: p.lat,
          lon: p.lon,
          shown: shown,
          ask: others[r.nextInt(others.length)],
          questions: evidenceQuestions,
          names: [p.ka, if (p.name != p.ka) p.name],
          converter: true,
          seed: randomSeed(r),
        );
      }(),
  ];
}

String _questionLetters(S s, EvidenceTask t) => [
  for (final q in evidenceQuestions)
    if (t.asks(q)) s['ev_short_$q'],
].join(', ');

/// The teacher's list of tasks. Returns it when done, with whether the answers are checked on the students'
/// devices (offline) instead of the server.
class EvidenceSetupPage extends StatefulWidget {
  final S s;
  const EvidenceSetupPage({super.key, required this.s});
  @override
  State<EvidenceSetupPage> createState() => _EvidenceSetupPageState();
}

class _EvidenceSetupPageState extends State<EvidenceSetupPage> {
  List<EvidenceTask> _tasks = [];
  PlaceIndex? _index;
  bool _offline = false;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    PlaceIndex.load().then((index) {
      if (mounted) setState(() => _index = index);
    });
  }

  Future<void> _edit([int? at]) async {
    final task = await Navigator.of(context).push<EvidenceTask>(
      MaterialPageRoute(builder: (_) => EvidenceTaskEditor(s: s, task: at == null ? null : _tasks[at])),
    );
    if (task == null || !mounted) return;
    setState(() => _tasks = at == null ? [..._tasks, task] : ([..._tasks]..[at] = task));
  }

  void _addRandom() {
    final room = maxEvidenceTasks - _tasks.length;
    if (_index == null || room <= 0) return;
    setState(() => _tasks = [..._tasks, ...randomEvidenceTasks(_index!, min(3, room))]);
  }

  @override
  Widget build(BuildContext context) {
    final full = _tasks.length >= maxEvidenceTasks;
    return Scaffold(
      appBar: AppBar(
        title: Text(s['ev_setup_title']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _tasks.isEmpty ? null : () => Navigator.pop(context, (_tasks, _offline)),
              child: Text(s['create']),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(s['ev_setup_hint']),
              const SizedBox(height: 12),
              OfflineAnswersSwitch(s: s, value: _offline, onChanged: (v) => setState(() => _offline = v)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: full ? null : _edit,
                    icon: const Icon(Icons.add),
                    label: Text(s['ev_add']),
                  ),
                  OutlinedButton.icon(
                    onPressed: full || _index == null ? null : _addRandom,
                    icon: const Icon(Icons.casino),
                    label: Text(s['ev_add_random']),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_tasks.isEmpty) Text(s['setup_empty']),
              for (final (i, t) in _tasks.indexed)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${i + 1}')),
                    title: Text(t.title),
                    subtitle: Text(
                      '${s['ev_kind_${t.kind}']} · ${t.shown.toUpperCase()} → ${t.ask.toUpperCase()} · ${_questionLetters(s, t)}'
                      '${t.converter ? '' : ' · ${s['ev_no_converter']}'}',
                    ),
                    onTap: () => _edit(i),
                    trailing: IconButton(
                      tooltip: s['delete'],
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _tasks = [..._tasks]..removeAt(i)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One task: the picture, its coordinates and formats, and which questions to ask.
class EvidenceTaskEditor extends StatefulWidget {
  final S s;
  final EvidenceTask? task;
  const EvidenceTaskEditor({super.key, required this.s, this.task});
  @override
  State<EvidenceTaskEditor> createState() => _EvidenceTaskEditorState();
}

class _EvidenceTaskEditorState extends State<EvidenceTaskEditor> {
  late final _coordCtl = TextEditingController(
    text: widget.task == null ? '' : formatDd(widget.task!.lat, widget.task!.lon),
  );
  late final _namesCtl = TextEditingController(text: widget.task?.names.join('\n') ?? '');
  late String _kind = widget.task?.kind ?? 'receipt';
  late String _shown = widget.task?.shown ?? 'dms';
  late String _ask = widget.task?.ask ?? 'dd';
  late Set<String> _questions = {...(widget.task?.questions ?? evidenceQuestions)};
  late bool _converter = widget.task?.converter ?? true;
  late final int _seed = widget.task?.seed ?? randomSeed();
  late LatLng? _point = widget.task == null ? null : LatLng(widget.task!.lat, widget.task!.lon);
  String? _coordError;
  final _map = MapController();

  S get s => widget.s;

  @override
  void dispose() {
    _coordCtl.dispose();
    _namesCtl.dispose();
    _map.dispose();
    super.dispose();
  }

  List<String> get _names => [
    for (final n in _namesCtl.text.split('\n'))
      if (normaliseName(n).isNotEmpty) n.trim(),
  ];

  EvidenceTask? get _task {
    final p = _point;
    if (p == null) return null;
    return EvidenceTask(
      kind: _kind,
      lat: p.latitude,
      lon: p.longitude,
      shown: _shown,
      ask: _ask,
      questions: [
        for (final q in evidenceQuestions)
          if (_questions.contains(q)) q,
      ],
      names: _names,
      converter: _converter,
      seed: _seed,
    );
  }

  String? get _problem {
    if (_point == null) return s['ev_need_point'];
    if (_questions.isEmpty) return s['ev_need_question'];
    if (_questions.contains('name') && _names.isEmpty) return s['ev_need_names'];
    return null;
  }

  void _typed(String text) {
    final p = text.trim().isEmpty ? null : parseAny(text);
    setState(() {
      _coordError = text.trim().isNotEmpty && p == null ? s['setup_bad_coord'] : null;
      if (p != null) _point = p;
    });
    if (p != null) _map.move(p, max(_map.camera.zoom, 12));
  }

  void _tapped(LatLng p) {
    final point = LatLng(p.latitude, (p.longitude + 180) % 360 - 180);
    setState(() {
      _point = point;
      _coordError = null;
      _coordCtl.text = formatDd(point.latitude, point.longitude);
    });
  }

  Widget _formats(String title, String value, ValueChanged<String> onChanged) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [for (final f in evidenceFormats) ButtonSegment(value: f, label: Text(f.toUpperCase()))],
        selected: {value},
        onSelectionChanged: (v) => onChanged(v.first),
      ),
      const SizedBox(height: 4),
      Text(s['format_$value'], style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final problem = _problem;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s[widget.task == null ? 'ev_add' : 'ev_edit']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: problem == null ? () => Navigator.pop(context, task) : null,
              child: Text(s['ev_save']),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(s['ev_kind'], style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final k in evidenceKinds)
                    ButtonSegment(value: k, icon: Icon(k == 'receipt' ? Icons.receipt_long : Icons.videocam), label: Text(s['ev_kind_$k'])),
                ],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 16),
              Text(s['ev_point'], style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                controller: _coordCtl,
                decoration: InputDecoration(
                  labelText: s['setup_add_label'],
                  hintText: '41.69380, 44.80150',
                  errorText: _coordError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: _typed,
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 260,
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: _point ?? const LatLng(42.2, 43.5),
                      initialZoom: _point == null ? 6.5 : 13,
                      minZoom: 2,
                      onTap: (_, p) => _tapped(p),
                      interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    ),
                    children: [
                      ...baseLayers(BaseMap.osm, 1),
                      MarkerLayer(
                        markers: [
                          if (_point != null)
                            Marker(
                              point: _point!,
                              width: 40,
                              height: 40,
                              alignment: Alignment.topCenter,
                              child: Icon(Icons.location_pin, size: 40, color: theme.colorScheme.error),
                            ),
                        ],
                      ),
                      ...mapFurniture(BaseMap.osm),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _formats(s['ev_shown'], _shown, (v) => setState(() => _shown = v)),
              const SizedBox(height: 12),
              _formats(s['ev_ask'], _ask, (v) => setState(() => _ask = v)),
              const SizedBox(height: 12),
              Text(s['ev_questions'], style: theme.textTheme.titleSmall),
              for (final q in evidenceQuestions)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _questions.contains(q),
                  title: Text(s['ev_setup_q_$q']),
                  onChanged: (v) => setState(() => _questions = v! ? ({..._questions, q}) : ({..._questions}..remove(q))),
                ),
              if (_questions.contains('name')) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _namesCtl,
                  minLines: 2,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: s['ev_names'],
                    helperText: s['ev_names_hint'],
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _converter,
                title: Text(s['ev_converter_on']),
                onChanged: (v) => setState(() => _converter = v),
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(problem, style: TextStyle(color: theme.colorScheme.error)),
                ),
              if (task != null) ...[
                const SizedBox(height: 8),
                Text(s['ev_preview'], style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: _kind == 'receipt' ? 420 : 300),
                    child: EvidencePicture(s: s, task: task),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
