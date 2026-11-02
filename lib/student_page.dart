import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'coordinates_play.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'models.dart';
import 'places.dart';
import 'queue.dart';
import 'settings.dart';
import 'settings_page.dart';

enum _Stage { loading, gone, noConnection, form, sent, queued }

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
  late final _queue = SubmissionQueue(_api.submit);
  final _map = MapController();
  final _placeCtl = TextEditingController();
  final _reasonCtl = TextEditingController();
  final _searchCtl = TextEditingController();
  Timer? _retry;

  _Stage _stage = _Stage.loading;
  String _name = '';
  String _status = 'open';
  String _game = 'travel';
  List<CoordTask> _tasks = const [];
  int _resetAt = 0;
  String? _error;
  bool _busy = false;

  LatLng? _point;
  String _country = '';
  String? _transport, _company;
  PlaceIndex? _index;
  List<Place> _results = const [];
  bool _searched = false;

  S get s => widget.settings.s;
  String get _cacheKey => 'join_${widget.token}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _map.dispose();
    _placeCtl.dispose();
    _reasonCtl.dispose();
    _searchCtl.dispose();
    super.dispose();
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
    if (_game == 'travel' && await _queue.pending() > 0) _flush();
  }

  void _apply(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      _name = data['name'] as String;
      _status = data['status'] as String;
      _game = data['game'] as String? ?? 'travel';
      final settings = data['settings'] as Map<String, dynamic>? ?? const {};
      _tasks = CoordTask.listFrom(settings);
      _resetAt = settings['resetAt'] as int? ?? 0;
      _stage = _Stage.form;
    });
  }

  Future<void> _flush() async {
    _retry?.cancel();
    final refused = await _queue.flush();
    if (!mounted) return;
    if (await _queue.pending() > 0) {
      setState(() => _stage = _Stage.queued);
      _retry = Timer(const Duration(seconds: 15), _flush);
    } else if (refused != null) {
      setState(() {
        _stage = _Stage.form;
        _error = refused;
        if (refused.startsWith('session_')) _status = refused.replaceFirst('session_', '');
      });
    } else if (_stage == _Stage.queued || _busy) {
      setState(() => _stage = _Stage.sent);
    }
  }

  Future<PlaceIndex> _places() async => _index ??= await PlaceIndex.load();

  Future<void> _search(String query) async {
    final index = await _places();
    if (!mounted || _searchCtl.text != query) return;
    setState(() {
      _results = index.search(query);
      _searched = query.trim().length >= 2;
    });
  }

  void _choose(Place place) {
    setState(() {
      _point = LatLng(place.lat, place.lon);
      _country = place.country;
      _placeCtl.text = place.label(widget.settings.lang);
      _results = const [];
      _searched = false;
      _searchCtl.clear();
    });
    _map.move(_point!, 9);
    FocusScope.of(context).unfocus();
  }

  Future<void> _tapMap(LatLng point) async {
    // The map repeats sideways, so a tap can land outside ±180°.
    final lon = (point.longitude + 180) % 360 - 180;
    final wrapped = LatLng(point.latitude, lon);
    setState(() => _point = wrapped);
    final index = await _places();
    final near = index.nearest(wrapped.latitude, wrapped.longitude);
    if (!mounted || near == null || _point != wrapped) return;
    setState(() {
      _country = near.country;
      _placeCtl.text = near.label(widget.settings.lang);
    });
  }

  Future<void> _submit() async {
    final String? problem = _point == null
        ? 'need_location'
        : _placeCtl.text.trim().isEmpty
            ? 'need_place'
            : _transport == null
                ? 'need_transport'
                : _company == null
                    ? 'need_company'
                    : null;
    setState(() => _error = problem);
    if (problem != null) return;

    setState(() => _busy = true);
    await _queue.add({
      'token': widget.token,
      'submissionId': randomId(),
      'participantId': await participantId(),
      'answer': {
        'place': _placeCtl.text.trim(),
        'country': _country,
        'reason': _reasonCtl.text.trim(),
        'transport': _transport,
        'company': _company,
      },
      'lat': _point!.latitude,
      'lon': _point!.longitude,
    });
    await _flush();
    if (mounted) setState(() => _busy = false);
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
            IconButton(
              tooltip: s['settings'],
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsPage(settings: widget.settings, teacherTools: false),
              )),
            ),
          ],
        ),
        body: SafeArea(child: _body()),
      );

  Widget _body() => switch (_stage) {
        _Stage.loading => const Center(child: CircularProgressIndicator()),
        _Stage.gone => _message(Icons.link_off, s['session_gone']),
        _Stage.noConnection => _message(Icons.wifi_off, s['no_connection'], action: _load, actionLabel: s['retry']),
        _Stage.sent => _message(Icons.check_circle, s['sent_title'],
            body: s['sent_body'],
            action: () => setState(() => _stage = _Stage.form),
            actionLabel: s['change_answer']),
        _Stage.queued => _message(Icons.cloud_upload, s['queued_title'], body: s['queued_body'], action: _flush, actionLabel: s['retry']),
        _Stage.form when _status == 'paused' => _message(Icons.pause_circle, s['session_paused'], action: _load, actionLabel: s['retry']),
        _Stage.form when _status == 'closed' => _message(Icons.lock, s['session_closed']),
        _Stage.form when _game == 'coordinates' => CoordinatesPlay(
            s: s,
            lang: widget.settings.lang,
            token: widget.token,
            tasks: _tasks,
            resetAt: _resetAt,
            api: _api,
            onStopped: (status) => setState(() => _status = status),
          ),
        _Stage.form => _form(),
      };

  Widget _message(IconData icon, String title, {String? body, VoidCallback? action, String? actionLabel}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(body, textAlign: TextAlign.center),
              ],
              if (action != null) ...[
                const SizedBox(height: 24),
                FilledButton(onPressed: action, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );

  Widget _chips(List<String> values, String prefix, String? selected, ValueChanged<String> onSelected) => Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final v in values)
            ChoiceChip(
              label: Text(s['${prefix}_$v']),
              selected: selected == v,
              onSelected: (_) => setState(() => onSelected(v)),
            ),
        ],
      );

  Widget _form() {
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(s['student_where'], style: text.headlineSmall),
            const SizedBox(height: 4),
            Text(s['student_pin_hint'], style: text.bodyMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                labelText: s['search_place'],
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: _search,
            ),
            for (final p in _results)
              ListTile(
                dense: true,
                leading: const Icon(Icons.place),
                title: Text(p.label(widget.settings.lang)),
                subtitle: Text(_index?.countryName(p.country, widget.settings.lang) ?? p.country),
                onTap: () => _choose(p),
              ),
            if (_searched && _results.isEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text(s['search_empty'])),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 300,
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: const LatLng(30, 30),
                    initialZoom: 2,
                    minZoom: 2,
                    onTap: (_, point) => _tapMap(point),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    ...baseLayers(BaseMap.osm, 1),
                    if (_point != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: _point!,
                          width: 44,
                          height: 44,
                          alignment: Alignment.topCenter,
                          child: Icon(Icons.location_pin, size: 44, color: Theme.of(context).colorScheme.error),
                        ),
                      ]),
                    ...mapFurniture(BaseMap.osm),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _placeCtl,
              maxLength: 120,
              decoration: InputDecoration(labelText: s['field_place'], border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonCtl,
              maxLength: 500,
              maxLines: 3,
              decoration: InputDecoration(labelText: s['field_reason'], border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(s['field_transport'], style: text.titleSmall),
            const SizedBox(height: 8),
            _chips(transports, 'transport', _transport, (v) => _transport = v),
            const SizedBox(height: 16),
            Text(s['field_company'], style: text.titleSmall),
            const SizedBox(height: 8),
            _chips(companies, 'company', _company, (v) => _company = v),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  s[_error!],
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: const Icon(Icons.send),
              label: Padding(padding: const EdgeInsets.all(8), child: Text(s['submit'])),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
