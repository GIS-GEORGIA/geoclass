import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'export.dart';
import 'files.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'models.dart';
import 'places.dart';
import 'settings.dart';

const _pollFast = Duration(seconds: 3);
const _pollSlow = Duration(seconds: 30);
const _idleAfter = Duration(minutes: 10);

/// One session: live answers on the map, QR code, moderation and data tools.
class SessionPage extends StatefulWidget {
  final Settings settings;
  final SessionInfo session;
  final bool showQrOnOpen;
  const SessionPage({super.key, required this.settings, required this.session, this.showQrOnOpen = false});
  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> with WidgetsBindingObserver {
  late final _api = Api(teacherKey: widget.settings.teacherKey);
  final _map = MapController();
  // Keeps one live map (position, loaded tiles) when the layout changes around it.
  final _mapKey = GlobalKey();
  late SessionInfo _session = widget.session;
  List<TravelAnswer> _answers = const [];
  int? _rev;
  bool _offline = false;
  bool _mapReady = false;
  bool _fitted = false;

  Timer? _timer;
  bool _visible = true;
  DateTime _lastChange = DateTime.now();

  bool _present = false;
  int _tab = 0; // narrow layout: 0 map, 1 panel
  bool _showStats = false;
  bool _showLayers = false;
  String _query = '';
  TravelAnswer? _selected;

  BaseMap _base = BaseMap.osm;
  double _opacity = 1;
  bool _showAnswers = true;
  bool _showRoutes = false;

  PlaceIndex? _index;
  List<Place> _placeResults = const [];
  final _placeCtl = TextEditingController();

  S get s => widget.settings.s;
  List<TravelAnswer> get _shown => _answers.where((a) => !a.hidden).toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll();
    if (widget.showQrOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showQr());
    }
    PlaceIndex.load().then((i) {
      if (mounted) setState(() => _index = i);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _map.dispose();
    _placeCtl.dispose();
    super.dispose();
  }

  // A forgotten open tab must not use up the daily request limit.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (visible == _visible) return;
    _visible = visible;
    _timer?.cancel();
    if (visible) {
      _lastChange = DateTime.now();
      _poll();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted || !_visible) return;
    final idle = _session.status != 'open' || DateTime.now().difference(_lastChange) > _idleAfter;
    _timer = Timer(idle ? _pollSlow : _pollFast, _poll);
  }

  Future<void> _poll() async {
    _timer?.cancel();
    try {
      final result = await _api.poll(_session.id, _rev);
      if (!mounted) return;
      setState(() {
        _session = result.session;
        _rev = result.session.rev;
        _offline = false;
        if (result.answers != null) {
          _answers = result.answers!;
          _lastChange = DateTime.now();
          if (_selected != null) {
            final id = _selected!.id;
            _selected = _answers.where((a) => a.id == id && !a.hidden).firstOrNull;
          }
        }
      });
      _fitOnce();
    } on NoConnection {
      if (mounted) setState(() => _offline = true);
    } on ApiError catch (e) {
      if (e.status == 401) {
        await widget.settings.setTeacherKey(null);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      if (e.status == 404 && mounted) {
        Navigator.of(context).pop();
        return;
      }
      if (mounted) setState(() => _offline = true);
    }
    _schedule();
  }

  void _fitOnce() {
    if (_fitted || !_mapReady || _shown.isEmpty) return;
    _fitted = true;
    _fitAll();
  }

  void _fitAll() {
    final points = [for (final a in _shown) LatLng(a.lat, a.lon)];
    if (points.isEmpty) return;
    if (points.length == 1) {
      _map.move(points.first, 6);
      return;
    }
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(48),
      maxZoom: 10,
    ));
  }

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs a teacher action, then refreshes at once.
  Future<void> _do(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null) _say(done);
    } on ApiError catch (e) {
      _say(s.f('failed', [s[e.key]]));
    } on NoConnection {
      _say(s.f('failed', [s['no_connection']]));
    }
    if (mounted) _poll();
  }

  Future<bool> _confirm(String title, String body, String action, {bool offerBackup = false}) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
          if (offerBackup) TextButton(onPressed: _backup, child: Text(s['backup_first'])),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return answer == true;
  }

  String get _fileLabel => _session.name.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');

  Future<void> _backup() => _do(() async {
        await saveJsonBackup(await _api.backup(sessionId: _session.id), _fileLabel);
      }, done: s['saved']);

  Future<void> _menu(String action) async {
    final id = _session.id;
    switch (action) {
      case 'pause':
        return _do(() => _api.updateSession(id, {'status': 'paused'}));
      case 'resume':
        return _do(() => _api.updateSession(id, {'status': 'open'}));
      case 'close':
        return _do(() => _api.updateSession(id, {'status': 'closed'}));
      case 'archive':
        return _do(() => _api.updateSession(id, {'archived': !_session.archived}));
      case 'csv':
        return _do(() => saveText(answersToCsv(_answers), 'geoclass-$_fileLabel', 'csv', 'text/csv'), done: s['saved']);
      case 'geojson':
        return _do(() => saveText(answersToGeoJson(_answers), 'geoclass-$_fileLabel', 'geojson', 'application/geo+json'), done: s['saved']);
      case 'json':
        return _backup();
      case 'rename':
        return _rename();
      case 'reset':
        final yes = await _confirm(s['reset'], s.f('reset_confirm', [_session.name, _answers.length]), s['reset'], offerBackup: true);
        if (yes) return _do(() => _api.resetResponses(id), done: s['reset_done']);
      case 'delete':
        final yes = await _confirm(s['delete_session'], s.f('delete_confirm', [_session.name, _answers.length]), s['delete'], offerBackup: true);
        if (yes) {
          _timer?.cancel();
          try {
            await _api.deleteSession(id);
            if (mounted) Navigator.of(context).pop();
          } on Exception catch (_) {
            _say(s.f('failed', [s['no_connection']]));
            _schedule();
          }
        }
    }
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: _session.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['rename']),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 100,
          decoration: InputDecoration(labelText: s['session_name'], border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s['cancel'])),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(s['save'])),
        ],
      ),
    );
    ctl.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await _do(() => _api.updateSession(_session.id, {'name': name.trim()}));
    }
  }

  String _joinUrl(String token) => '$publicUrl/#/join/$token';

  Future<void> _showQr() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _QrDialog(
        s: s,
        name: _session.name,
        token: widget.settings.tokenFor(_session.id),
        urlFor: _joinUrl,
        renew: () async {
          final token = await _api.newToken(_session.id);
          await widget.settings.setToken(_session.id, token);
          return token;
        },
      ),
    );
  }

  void _searchPlace(String query) {
    setState(() => _placeResults = _index?.search(query, limit: 6) ?? const []);
  }

  void _goToPlace(Place place) {
    _map.move(LatLng(place.lat, place.lon), 9);
    _placeCtl.clear();
    setState(() => _placeResults = const []);
    FocusScope.of(context).unfocus();
  }

  // --- Map ---

  Color _colorFor(String transport) => switch (transport) {
        'plane' => const Color(0xFF1565C0),
        'train' => const Color(0xFF6A1B9A),
        'car' => const Color(0xFFC62828),
        'bus' => const Color(0xFFEF6C00),
        'ship' => const Color(0xFF00838F),
        'bike' => const Color(0xFF2E7D32),
        _ => const Color(0xFF5D4037),
      };

  Widget get _liveMap => KeyedSubtree(key: _mapKey, child: _mapView());

  Widget _mapView() {
    final shown = _shown;
    final markers = [
      for (final a in shown)
        Marker(
          point: LatLng(a.lat, a.lon),
          width: 36,
          height: 36,
          child: GestureDetector(
            onTap: () => setState(() => _selected = a),
            child: Tooltip(
              message: a.place,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _colorFor(a.transport),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Icon(transportIcon(a.transport), color: Colors.white, size: 18),
              ),
            ),
          ),
        ),
    ];
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: const LatLng(30, 30),
            initialZoom: 2,
            minZoom: 2,
            onMapReady: () {
              _mapReady = true;
              _fitOnce();
            },
            onTap: (_, _) {
              if (_selected != null || _showLayers) {
                setState(() {
                  _selected = null;
                  _showLayers = false;
                });
              }
            },
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            ...baseLayers(_base, _opacity),
            if (_showRoutes)
              PolylineLayer(polylines: [
                for (final a in shown)
                  Polyline(
                    points: [widget.settings.origin, LatLng(a.lat, a.lon)],
                    color: _colorFor(a.transport).withValues(alpha: 0.6),
                    strokeWidth: 2,
                  ),
              ]),
            if (_showAnswers)
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 45,
                  size: const Size(44, 44),
                  markers: markers,
                  builder: (context, cluster) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        '${cluster.length}',
                        style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ),
            ...mapFurniture(_base),
          ],
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                heroTag: 'layers',
                tooltip: s['layers'],
                onPressed: () => setState(() => _showLayers = !_showLayers),
                child: const Icon(Icons.layers),
              ),
              const SizedBox(height: 4),
              FloatingActionButton.small(
                heroTag: 'fit',
                tooltip: s['fit_answers'],
                onPressed: _fitAll,
                child: const Icon(Icons.fit_screen),
              ),
              if (_showLayers) _layerPanel(),
            ],
          ),
        ),
        if (!_present)
          Positioned(
            top: 8,
            left: 8,
            child: SizedBox(
              width: 240,
              child: Card(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _placeCtl,
                      decoration: InputDecoration(
                        hintText: s['search_place'],
                        prefixIcon: const Icon(Icons.search),
                        border: InputBorder.none,
                      ),
                      onChanged: _searchPlace,
                    ),
                    for (final p in _placeResults)
                      ListTile(
                        dense: true,
                        title: Text(p.label(widget.settings.lang)),
                        subtitle: Text(_index?.countryName(p.country, widget.settings.lang) ?? p.country),
                        onTap: () => _goToPlace(p),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (_selected != null)
          Positioned(
            left: 8,
            right: 8,
            bottom: 40,
            child: Center(child: _answerCard(_selected!)),
          ),
        if (_offline)
          Positioned(
            bottom: 40,
            left: 8,
            child: Chip(avatar: const Icon(Icons.wifi_off, size: 18), label: Text(s['offline_results'])),
          ),
      ],
    );
  }

  Widget _layerPanel() => LayerPanel(
        s: s,
        base: _base,
        opacity: _opacity,
        onBase: (b) => setState(() => _base = b),
        onOpacity: (v) => setState(() => _opacity = v),
        children: [
          const Divider(),
          Text(s['layers'], style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _showAnswers,
            title: Text(s['overlay_answers']),
            onChanged: (v) => setState(() => _showAnswers = v),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _showRoutes,
            title: Text(s['overlay_routes']),
            onChanged: (v) => setState(() => _showRoutes = v),
          ),
          TextButton.icon(
            icon: const Icon(Icons.my_location),
            label: Text(s['set_origin']),
            onPressed: () async {
              await widget.settings.setOrigin(_map.camera.center);
              setState(() {});
              _say(s['origin_set']);
            },
          ),
        ],
      );

  Widget _answerCard(TravelAnswer a) {
    final country = a.country.isEmpty ? '' : _index?.countryName(a.country, widget.settings.lang) ?? a.country;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(transportIcon(a.transport), color: _colorFor(a.transport)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      country.isEmpty ? a.place : '${a.place}, $country',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: s['close'],
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _selected = null),
                  ),
                ],
              ),
              if (a.reason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(a.reason, style: Theme.of(context).textTheme.bodyLarge),
              ],
              const SizedBox(height: 8),
              Text('${s['transport_${a.transport}']} · ${s['company_${a.company}']}'),
            ],
          ),
        ),
      ),
    );
  }

  // --- Panel ---

  Widget _panel() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text('${s['answers']} (${_answers.length})')),
                ButtonSegment(value: true, label: Text(s['stats'])),
              ],
              selected: {_showStats},
              onSelectionChanged: (v) => setState(() => _showStats = v.first),
            ),
          ),
          Expanded(child: _showStats ? _statsView() : _answerList()),
        ],
      );

  Widget _answerList() {
    final q = normalize(_query);
    final rows = [
      for (final a in _answers.reversed)
        if (q.isEmpty || normalize('${a.place} ${a.reason} ${a.country}').contains(q)) a,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              labelText: s['search_answers'],
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(_answers.isEmpty ? s['no_answers'] : s['no_match']))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _answerRow(rows[i]),
                ),
        ),
      ],
    );
  }

  Widget _answerRow(TravelAnswer a) {
    final muted = Theme.of(context).disabledColor;
    return ListTile(
      leading: Icon(transportIcon(a.transport), color: a.hidden ? muted : _colorFor(a.transport)),
      title: Text(a.place, style: a.hidden ? TextStyle(color: muted) : null),
      subtitle: Text(
        a.hidden ? s['hidden_label'] : a.reason,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: a.hidden
          ? null
          : () {
              setState(() {
                _selected = a;
                _tab = 0;
              });
              _map.move(LatLng(a.lat, a.lon), _map.camera.zoom < 5 ? 5 : _map.camera.zoom);
            },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: a.hidden ? s['show'] : s['hide'],
            icon: Icon(a.hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => _do(() => _api.setHidden(a.id, !a.hidden)),
          ),
          IconButton(
            tooltip: s['delete'],
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _do(() => _api.deleteResponse(a.id)),
          ),
        ],
      ),
    );
  }

  Widget _statsView() {
    final lang = widget.settings.lang;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _bars(s['top_places'], countBy(_answers, (a) => a.place).take(8).toList(), (k) => k),
        _bars(s['top_countries'], countBy(_answers, (a) => a.country).take(8).toList(), (k) => _index?.countryName(k, lang) ?? k),
        _bars(s['transport_stats'], countBy(_answers, (a) => a.transport), (k) => s['transport_$k']),
        _bars(s['company_stats'], countBy(_answers, (a) => a.company), (k) => s['company_$k']),
      ],
    );
  }

  Widget _bars(String title, List<MapEntry<String, int>> rows, String Function(String) label) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final max = rows.first.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final e in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(label(e.key), overflow: TextOverflow.ellipsis)),
                      Text('${e.value}'),
                    ],
                  ),
                  const SizedBox(height: 2),
                  LinearProgressIndicator(value: e.value / max, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label) => PopupMenuItem(
        value: value,
        child: ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: Icon(icon), title: Text(label)),
      );

  List<PopupMenuEntry<String>> _menuItems() => [
        if (_session.status == 'open') _item('pause', Icons.pause, s['pause']),
        if (_session.status == 'paused') _item('resume', Icons.play_arrow, s['resume']),
        if (_session.status != 'closed') _item('close', Icons.lock, s['close_session']),
        if (_session.status == 'closed') _item('resume', Icons.lock_open, s['reopen']),
        const PopupMenuDivider(),
        _item('csv', Icons.table_chart, s['export_csv']),
        _item('geojson', Icons.map, s['export_geojson']),
        _item('json', Icons.save, s['export_json']),
        const PopupMenuDivider(),
        _item('rename', Icons.edit, s['rename']),
        _item('archive', Icons.inventory_2, _session.archived ? s['unarchive'] : s['archive']),
        _item('reset', Icons.cleaning_services, s['reset']),
        _item('delete', Icons.delete_forever, s['delete_session']),
      ];

  @override
  Widget build(BuildContext context) {
    if (_present) {
      return Scaffold(
        body: Stack(
          children: [
            _liveMap,
            Positioned(
              bottom: 40,
              right: 8,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Text('${_session.name} · ${_shown.length}', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      IconButton(tooltip: s['qr_show'], icon: const Icon(Icons.qr_code), onPressed: _showQr),
                      IconButton(
                        tooltip: s['present_exit'],
                        icon: const Icon(Icons.fullscreen_exit),
                        onPressed: () => setState(() => _present = false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_session.name, overflow: TextOverflow.ellipsis),
            Text(s['status_${_session.status}'], style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(tooltip: s['qr_show'], icon: const Icon(Icons.qr_code), onPressed: _showQr),
          IconButton(
            tooltip: s['present'],
            icon: const Icon(Icons.fullscreen),
            onPressed: () => setState(() => _present = true),
          ),
          PopupMenuButton<String>(onSelected: _menu, itemBuilder: (_) => _menuItems()),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              height: 64,
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                NavigationDestination(icon: const Icon(Icons.map), label: s['map']),
                NavigationDestination(icon: const Icon(Icons.list), label: s['answers']),
              ],
            ),
      body: wide
          ? Row(
              children: [
                Expanded(child: _liveMap),
                const VerticalDivider(width: 1),
                SizedBox(width: 380, child: _panel()),
              ],
            )
          : IndexedStack(index: _tab, children: [_liveMap, _panel()]),
    );
  }
}

class _QrDialog extends StatefulWidget {
  final S s;
  final String name;
  final String? token;
  final String Function(String) urlFor;
  final Future<String> Function() renew;
  const _QrDialog({required this.s, required this.name, required this.token, required this.urlFor, required this.renew});
  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  late String? _token = widget.token;
  String? _error;
  S get s => widget.s;

  Future<void> _renew() async {
    if (_token != null) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s['qr_new']),
          content: Text(s['qr_new_confirm']),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s['qr_new'])),
          ],
        ),
      );
      if (yes != true) return;
    }
    try {
      final token = await widget.renew();
      if (mounted) {
        setState(() {
          _token = token;
          _error = null;
        });
      }
    } on Exception catch (_) {
      if (mounted) setState(() => _error = s.f('failed', [s['no_connection']]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final side = (size.shortestSide - 120).clamp(180.0, 560.0);
    final token = _token;
    return AlertDialog(
      title: Text(token == null ? widget.name : '${widget.name}: ${s['qr_title']}'),
      content: SizedBox(
        width: side,
        child: token == null
            ? Text(s['qr_missing'])
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // White in both themes: phones read dark-on-light best.
                  ColoredBox(
                    color: Colors.white,
                    child: QrImageView(
                      data: widget.urlFor(token),
                      size: side,
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: _renew, child: Text(s['qr_new'])),
        if (token != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.urlFor(token)));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s['qr_copied'])));
              }
            },
            child: Text(s['qr_link']),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(s['close'])),
      ],
    );
  }
}
