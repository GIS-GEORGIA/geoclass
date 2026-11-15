import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coords.dart';
import '../games/game.dart';
import '../geo_map.dart';
import '../l10n.dart';
import '../queue.dart';
import 'emergency.dart';
import 'emergency_setup.dart' show factsFields;

/// What the server told about one point after the answer: the score, the true place, the facts, the best photo
/// and the teacher's notes on each photo.
class PointResult {
  final int score;
  final ({double lat, double lon}) truth;
  final Facts facts;
  final String best;
  final Map<String, String> notes;
  final EmergencyAnswer answer;
  const PointResult(this.score, this.truth, this.facts, this.best, this.notes, this.answer);

  static PointResult? fromReply(Map<String, dynamic> r, EmergencyAnswer answer) {
    final truth = r['truth'];
    if (r['score'] is! num || truth is! List || r['facts'] is! Map || r['best'] is! String) return null;
    return PointResult(
      (r['score'] as num).toInt(),
      (lat: (truth[0] as num).toDouble(), lon: (truth[1] as num).toDouble()),
      Facts.fromJson(r['facts'] as Map<String, dynamic>),
      r['best'] as String,
      {for (final e in ((r['notes'] as Map?) ?? const {}).entries) e.key as String: e.value as String},
      answer,
    );
  }

  Map<String, dynamic> toJson() => {
    'score': score,
    'truth': [truth.lat, truth.lon],
    'facts': facts.toJson(),
    'best': best,
    'notes': notes,
    'answer': answer.toJson(),
  };
  static PointResult? fromJson(Map<String, dynamic> j) =>
      fromReply(j, EmergencyAnswer.fromJson(j['answer'] as Map<String, dynamic>));
}

/// The student's 112 exercise: each point is a call. Read the place off the map in the format the operator
/// asks for, say what happened, pick the photo that helps most, and send. Then the right answers show.
class EmergencyPlay extends StatefulWidget {
  final PlayContext ctx;
  const EmergencyPlay({super.key, required this.ctx});
  @override
  State<EmergencyPlay> createState() => _EmergencyPlayState();
}

class _EmergencyPlayState extends State<EmergencyPlay> {
  late final _queue = SubmissionQueue(widget.ctx.token, widget.ctx.api.submit, onReply: _onReply);
  final _replies = <String, Map<String, dynamic>>{};
  Timer? _retry;

  String _template = '';
  List<StudentPoint> _points = const [];
  bool _bad = false, _loaded = false, _busy = false;
  String _participant = '';
  int _index = 0;
  final _results = <int, PointResult>{};

  // The call being written for the current point.
  final _coords = TextEditingController();
  final _landmark = TextEditingController();
  String? _kind, _photo, _error;
  int? _people;
  bool? _injured;

  S get s => widget.ctx.s;
  String get _progressKey => 'progress_${widget.ctx.token}';

  @override
  void initState() {
    super.initState();
    try {
      final (template, points) = StudentPoint.listFrom(widget.ctx.settings);
      _template = template;
      _points = points;
    } on Object {
      _bad = true;
    }
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _coords.dispose();
    _landmark.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.ctx.token);
    final saved = prefs.getString(_progressKey);
    if (saved != null) {
      try {
        final d = jsonDecode(saved) as Map<String, dynamic>;
        if (d['resetAt'] == widget.ctx.resetAt) {
          for (final e in (d['results'] as Map<String, dynamic>).entries) {
            final r = PointResult.fromJson(e.value as Map<String, dynamic>);
            if (r != null) _results[int.parse(e.key)] = r;
          }
        }
      } on Object {
        // A damaged save starts again; the server still has the answers.
      }
    }
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _index = _firstOpen();
    });
    _send();
  }

  int _firstOpen() {
    for (var i = 0; i < _points.length; i++) {
      if (!_results.containsKey(i)) return i;
    }
    return 0;
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _progressKey,
    jsonEncode({
      'results': {for (final e in _results.entries) '${e.key}': e.value.toJson()},
      'resetAt': widget.ctx.resetAt,
    }),
  );

  void _onReply(Map<String, dynamic> item, Map<String, dynamic> reply) {
    if (item['token'] != widget.ctx.token) return;
    _replies[item['submissionId'] as String] = reply;
    // An answer sent later, after the connection came back.
    final round = item['round'] as int;
    final r = PointResult.fromReply(reply, EmergencyAnswer.fromJson(item['answer'] as Map<String, dynamic>));
    if (r != null && mounted) {
      setState(() => _results[round] = r);
      _save();
    }
  }

  Future<bool> _send() async {
    _retry?.cancel();
    final refused = await _queue.flush();
    final pending = await _queue.pending();
    if (!mounted) return false;
    if (refused == 'session_paused' || refused == 'session_closed') {
      widget.ctx.onStopped(refused!.replaceFirst('session_', ''));
      return false;
    }
    if (refused != null) setState(() => _error = s[refused]);
    if (pending > 0) _retry = Timer(const Duration(seconds: 15), _send);
    return true;
  }

  void _open(int i) => setState(() {
    _index = i;
    _coords.clear();
    _landmark.clear();
    _kind = _photo = _error = null;
    _people = null;
    _injured = null;
  });

  String? get _incomplete {
    if (_coords.text.trim().isEmpty) return 'emergency_need_coords';
    if (_kind == null || _people == null || _injured == null) return 'emergency_need_message';
    if (_photo == null) return 'emergency_need_photo';
    return null;
  }

  Future<void> _call() async {
    final missing = _incomplete;
    if (missing != null) {
      setState(() => _error = s[missing]);
      return;
    }
    if (_busy) return;
    final p = _points[_index];
    final at = readCoords(_coords.text);
    final answer = EmergencyAnswer(
      coords: _coords.text.trim(),
      at: at,
      kind: _kind!,
      people: _people!,
      injured: _injured!,
      landmark: _landmark.text.trim(),
      photo: _photo!,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = randomId();
    final round = _index;
    await _queue.add({
      'token': widget.ctx.token,
      'submissionId': id,
      'participantId': _participant,
      'round': round,
      'answer': answer.toJson(),
      // Where the answer points, or the scenario's place when the coordinates couldn't be read.
      'lat': at?.lat ?? p.lat,
      'lon': at?.lon ?? p.lon,
    });
    await _send();
    if (!mounted) return;
    setState(() {
      _busy = false;
      final reply = _replies.remove(id);
      final r = reply == null ? null : PointResult.fromReply(reply, answer);
      if (r != null) _results[round] = r;
      if (r == null && _error == null) _error = s['emergency_queued'];
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (_bad) return Center(child: Text(s['session_unreadable']));
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final p = _points[_index];
    final result = _results[_index];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _exerciseNote(context),
            const SizedBox(height: 8),
            if (_points.length > 1)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _points.length; i++)
                    ChoiceChip(
                      key: Key('emergency_tab_$i'),
                      label: Text('${i + 1}'),
                      avatar: _results.containsKey(i) ? const Icon(Icons.check, size: 16) : null,
                      selected: i == _index,
                      showCheckmark: false,
                      onSelected: (_) => _open(i),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Text(p.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(p.text),
            const SizedBox(height: 12),
            _map(context, p, result),
            const SizedBox(height: 12),
            if (result == null) ..._form(context, p) else ..._feedback(context, p, result),
          ],
        ),
      ),
    );
  }

  Widget _exerciseNote(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: ListTile(
      leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.onErrorContainer),
      title: Text(s['emergency_exercise'], style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
    ),
  );

  Widget _map(BuildContext context, StudentPoint p, PointResult? result) {
    final scheme = Theme.of(context).colorScheme;
    final here = LatLng(p.lat, p.lon);
    final at = result?.answer.at;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 320,
        child: FlutterMap(
          key: ValueKey('emergency_map_$_index'),
          options: MapOptions(
            initialCenter: here,
            initialZoom: 15,
            minZoom: 8,
            maxZoom: 18,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            ...baseLayers(BaseMap.osm, 1),
            if (p.format == 'utm') UtmGridLayer(zone: utmZone(p.lon)) else GraticuleLayer(format: p.format),
            if (at != null)
              PolylineLayer(
                polylines: [
                  Polyline(points: [here, LatLng(at.lat, at.lon)], color: scheme.tertiary, strokeWidth: 2),
                ],
              ),
            MarkerLayer(
              markers: [
                if (at != null)
                  Marker(
                    point: LatLng(at.lat, at.lon),
                    width: 30,
                    height: 30,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_on, color: scheme.tertiary, size: 30),
                  ),
                Marker(
                  point: here,
                  width: 140,
                  height: 64,
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(6)),
                        child: Text(s['emergency_you_are_here'], style: TextStyle(color: scheme.onError, fontSize: 11)),
                      ),
                      Icon(Icons.person_pin_circle, color: scheme.error, size: 32),
                    ],
                  ),
                ),
              ],
            ),
            ...mapFurniture(BaseMap.osm),
          ],
        ),
      ),
    );
  }

  Widget _picture(String id, {bool selected = false, bool best = false, VoidCallback? onTap, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: best ? Colors.green : (selected ? scheme.primary : Colors.transparent), width: 4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.network(
              photoUrl(_template, id),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image)),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context, StudentPoint p) => [
    Text(s.f('emergency_operator_asks', [s['format_${p.format}']]), style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 6),
    TextField(
      key: const Key('emergency_coords'),
      controller: _coords,
      maxLength: maxCoords,
      decoration: InputDecoration(
        labelText: s['emergency_your_coords'],
        hintText: s.f('emergency_example', [formatAs(p.format, 41.69380, 44.80150)]),
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 8),
    Text(s['emergency_message'], style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 6),
    factsFields(
      s: s,
      kind: _kind,
      people: _people,
      injured: _injured,
      landmark: _landmark,
      onKind: (v) => setState(() => _kind = v),
      onPeople: (v) => setState(() => _people = v),
      onInjured: (v) => setState(() => _injured = v),
      keyPrefix: 'emergency_call',
    ),
    const SizedBox(height: 8),
    Text(s['emergency_pick_photo'], style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 6),
    GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 4 / 3,
      children: [
        for (final id in p.photos)
          _picture(
            id,
            selected: id == _photo,
            onTap: () => setState(() => _photo = id),
            key: Key('emergency_photo_$id'),
          ),
      ],
    ),
    const SizedBox(height: 12),
    if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    const SizedBox(height: 6),
    FilledButton.icon(
      key: const Key('emergency_call'),
      style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700, minimumSize: const Size.fromHeight(48)),
      onPressed: _busy ? null : _call,
      icon: const Icon(Icons.phone_in_talk),
      label: Text(s['emergency_send']),
    ),
  ];

  List<Widget> _feedback(BuildContext context, StudentPoint p, PointResult r) {
    final parts = scoreParts(r.truth, p.format, r.facts, r.best, r.answer);
    final a = r.answer;
    final theme = Theme.of(context).textTheme;
    String kind(String k) => s['emergency_kind_$k'];
    String yesNo(bool v) => s[v ? 'yes' : 'no'];
    // "Anyone injured?" as a label: "Anyone injured: yes".
    String label(String key) => s[key].replaceFirst(RegExp(r'\?$'), '');
    return [
      Text(s.f('points', [r.score]), key: const Key('emergency_score'), style: theme.headlineSmall),
      const SizedBox(height: 4),
      Text(
        a.at == null
            ? s.f('emergency_part_place_none', [parts.place])
            : s.f('emergency_part_place', [
                parts.place,
                (parts.distance! >= 1000
                    ? '${(parts.distance! / 1000).toStringAsFixed(1)} km'
                    : '${parts.distance!.round()} m'),
              ]),
      ),
      Text(
        s.f('emergency_part_format', [
          parts.format,
          s['format_${classifyCoords(a.coords) ?? 'unknown'}'],
          s['format_${p.format}'],
        ]),
      ),
      Text(s.f('emergency_part_message', [parts.message])),
      Text(s.f('emergency_part_photo', [parts.photo])),
      const Divider(),
      Text(s['emergency_truth'], style: theme.titleSmall),
      for (final f in emergencyFormats)
        SelectableText('${s['format_$f']}: ${formatAs(f, r.truth.lat, r.truth.lon)}', key: Key('emergency_truth_$f')),
      Text(s.f('emergency_you_wrote', [a.coords])),
      const SizedBox(height: 8),
      Text(s['emergency_facts_compare'], style: theme.titleSmall),
      Text(s.f('emergency_compare', [label('emergency_kind'), kind(a.kind), kind(r.facts.kind)])),
      Text(s.f('emergency_compare', [label('emergency_people'), a.people, r.facts.people])),
      Text(s.f('emergency_compare', [label('emergency_injured'), yesNo(a.injured), yesNo(r.facts.injured)])),
      Text(
        s.f('emergency_compare', [
          label('emergency_landmark'),
          a.landmark.isEmpty ? '–' : a.landmark,
          r.facts.landmark.isEmpty ? '–' : r.facts.landmark,
        ]),
      ),
      const Divider(),
      Text(s['emergency_photos_explained'], style: theme.titleSmall),
      const SizedBox(height: 6),
      for (final id in p.photos)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                child: _picture(id, selected: id == a.photo, best: id == r.best),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (id == r.best)
                      Text(
                        s['emergency_best_photo'],
                        style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                      ),
                    if (id == a.photo) Text(s['emergency_your_photo'], style: theme.labelMedium),
                    Text(r.notes[id] ?? ''),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (_results.length < _points.length)
        FilledButton(
          key: const Key('emergency_next'),
          onPressed: () => _open(_firstOpen()),
          child: Text(s['emergency_next_call']),
        )
      else
        Text(s['emergency_all_done'], style: theme.titleMedium),
    ];
  }
}
