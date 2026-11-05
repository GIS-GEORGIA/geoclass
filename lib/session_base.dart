import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'files.dart';
import 'geo_map.dart';
import 'l10n.dart';
import 'models.dart';
import 'places.dart';
import 'settings.dart';

const _pollFast = Duration(seconds: 3);
const _pollSlow = Duration(seconds: 30);
const _idleAfter = Duration(minutes: 10);

abstract class SessionPageBase extends StatefulWidget {
  final Settings settings;
  final SessionInfo session;
  final bool showQrOnOpen;
  const SessionPageBase({super.key, required this.settings, required this.session, this.showQrOnOpen = false});
}

/// What every game's session page shares: polling, QR code, status, data tools and page layout.
abstract class SessionPageState<W extends SessionPageBase> extends State<W> with WidgetsBindingObserver {
  late final api = Api(teacherKey: widget.settings.teacherKey);
  final mapController = MapController();
  // Keeps one live map (position, loaded tiles) when the layout changes around it.
  final _mapKey = GlobalKey();
  late SessionInfo session = widget.session;
  int? _rev;
  bool _offline = false;
  bool mapReady = false;
  bool _fitted = false;

  Timer? _timer;
  bool _visible = true;
  DateTime _lastChange = DateTime.now();

  bool present = false;
  int _tab = 0; // narrow layout: 0 map, 1 panel
  bool _showLayers = false;
  BaseMap _base = BaseMap.osm;
  double _opacity = 1;
  bool showGrid = false;

  PlaceIndex? placeIndex;
  List<Place> _placeResults = const [];
  final _placeCtl = TextEditingController();

  S get s => widget.settings.s;
  String get lang => widget.settings.lang;

  // --- What each game provides ---

  void onRows(List<Map<String, dynamic>> rows);
  List<LatLng> get fitPoints;
  int get answerCount;
  int get shownCount;
  String exportCsv();
  String exportGeoJson();

  /// Where the map opens, and how close fitting the answers goes.
  LatLng get initialCenter => const LatLng(30, 30);
  double get initialZoom => 2;
  double get fitMaxZoom => 10;
  double get singlePointZoom => 6;

  /// False for a game with no map on the teacher's side: the panel is the whole page.
  bool get hasMap => true;

  /// The coordinate grid this game uses.
  Widget gridLayer() => const GraticuleLayer();

  /// Map layers between the base map and the attribution.
  List<Widget> mapLayers();

  /// Widgets floating above the map.
  List<Widget> mapOverlays();

  /// Extra switches for the layer panel.
  List<Widget> layerSwitches() => const [];

  /// Called when the empty part of the map is tapped.
  void onMapTap() {}

  Widget panel();

  // --- Life cycle ---

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll();
    if (widget.showQrOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showQr());
    }
    PlaceIndex.load().then((i) {
      if (mounted) setState(() => placeIndex = i);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    mapController.dispose();
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
    final idle = session.status != 'open' || DateTime.now().difference(_lastChange) > _idleAfter;
    _timer = Timer(idle ? _pollSlow : _pollFast, _poll);
  }

  Future<void> _poll() async {
    _timer?.cancel();
    try {
      final result = await api.poll(session.id, _rev);
      if (!mounted) return;
      setState(() {
        session = result.session;
        _rev = result.session.rev;
        _offline = false;
        if (result.rows != null) {
          onRows(result.rows!);
          _lastChange = DateTime.now();
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
    if (_fitted || !mapReady || _rev == null || fitPoints.isEmpty) return;
    _fitted = true;
    fitAll();
  }

  void fitAll() {
    final points = fitPoints;
    if (points.isEmpty) return;
    if (points.length == 1) {
      mapController.move(points.first, singlePointZoom);
      return;
    }
    mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(48),
      maxZoom: fitMaxZoom,
    ));
  }

  // --- Actions ---

  void say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs a teacher action, then refreshes at once.
  Future<void> run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null) say(done);
    } on ApiError catch (e) {
      say(s.f('failed', [s[e.key]]));
    } on NoConnection {
      say(s.f('failed', [s['no_connection']]));
    }
    if (mounted) _poll();
  }

  /// Shows the panel's result on the map in the narrow layout.
  void showMapTab() => _tab = 0;

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

  String get _fileLabel => session.name.replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');

  Future<void> _backup() => run(() async {
        await saveJsonBackup(await api.backup(sessionId: session.id), _fileLabel);
      }, done: s['saved']);

  Future<void> _menu(String action) async {
    final id = session.id;
    switch (action) {
      case 'pause':
        return run(() => api.updateSession(id, {'status': 'paused'}));
      case 'resume':
        return run(() => api.updateSession(id, {'status': 'open'}));
      case 'close':
        return run(() => api.updateSession(id, {'status': 'closed'}));
      case 'archive':
        return run(() => api.updateSession(id, {'archived': !session.archived}));
      case 'csv':
        return run(() => saveText(exportCsv(), 'geoclass-$_fileLabel', 'csv', 'text/csv'), done: s['saved']);
      case 'geojson':
        return run(() => saveText(exportGeoJson(), 'geoclass-$_fileLabel', 'geojson', 'application/geo+json'), done: s['saved']);
      case 'json':
        return _backup();
      case 'rename':
        return _rename();
      case 'reset':
        final yes = await _confirm(s['reset'], s.f('reset_confirm', [session.name, answerCount]), s['reset'], offerBackup: true);
        if (yes) return run(() => api.resetResponses(id), done: s['reset_done']);
      case 'delete':
        final yes = await _confirm(s['delete_session'], s.f('delete_confirm', [session.name, answerCount]), s['delete'], offerBackup: true);
        if (yes) {
          _timer?.cancel();
          try {
            await api.deleteSession(id);
            if (mounted) Navigator.of(context).pop();
          } on Exception catch (_) {
            say(s.f('failed', [s['no_connection']]));
            _schedule();
          }
        }
    }
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: session.name);
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
      await run(() => api.updateSession(session.id, {'name': name.trim()}));
    }
  }

  String _joinUrl(String token) => '$publicUrl/#/join/$token';

  Future<void> _showQr() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _QrDialog(
        s: s,
        name: session.name,
        token: widget.settings.tokenFor(session.id),
        urlFor: _joinUrl,
        renew: () async {
          final token = await api.newToken(session.id);
          await widget.settings.setToken(session.id, token);
          return token;
        },
      ),
    );
  }

  void _searchPlace(String query) {
    setState(() => _placeResults = placeIndex?.search(query, limit: 6) ?? const []);
  }

  void _goToPlace(Place place) {
    mapController.move(LatLng(place.lat, place.lon), 9);
    _placeCtl.clear();
    setState(() => _placeResults = const []);
    FocusScope.of(context).unfocus();
  }

  // --- Layout ---

  Widget _mapView() => Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: initialZoom,
              minZoom: 2,
              onMapReady: () {
                mapReady = true;
                _fitOnce();
              },
              onTap: (_, _) {
                if (_showLayers) setState(() => _showLayers = false);
                onMapTap();
              },
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              ...baseLayers(_base, _opacity),
              if (showGrid) gridLayer(),
              ...mapLayers(),
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
                  onPressed: fitAll,
                  child: const Icon(Icons.fit_screen),
                ),
                if (_showLayers)
                  LayerPanel(
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
                        value: showGrid,
                        title: Text(s['overlay_grid']),
                        onChanged: (v) => setState(() => showGrid = v),
                      ),
                      ...layerSwitches(),
                    ],
                  ),
              ],
            ),
          ),
          ...mapOverlays(),
          if (!present)
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
                          title: Text(p.label(lang)),
                          subtitle: Text(placeIndex?.countryName(p.country, lang) ?? p.country),
                          onTap: () => _goToPlace(p),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (_offline)
            Positioned(
              bottom: 40,
              left: 8,
              child: Chip(avatar: const Icon(Icons.wifi_off, size: 18), label: Text(s['offline_results'])),
            ),
        ],
      );

  Widget get _liveMap => KeyedSubtree(key: _mapKey, child: _mapView());

  PopupMenuItem<String> _item(String value, IconData icon, String label) => PopupMenuItem(
        value: value,
        child: ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: Icon(icon), title: Text(label)),
      );

  List<PopupMenuEntry<String>> _menuItems() => [
        if (session.status == 'open') _item('pause', Icons.pause, s['pause']),
        if (session.status == 'paused') _item('resume', Icons.play_arrow, s['resume']),
        if (session.status != 'closed') _item('close', Icons.lock, s['close_session']),
        if (session.status == 'closed') _item('resume', Icons.lock_open, s['reopen']),
        const PopupMenuDivider(),
        _item('csv', Icons.table_chart, s['export_csv']),
        if (hasMap) _item('geojson', Icons.map, s['export_geojson']),
        _item('json', Icons.save, s['export_json']),
        const PopupMenuDivider(),
        _item('rename', Icons.edit, s['rename']),
        _item('archive', Icons.inventory_2, session.archived ? s['unarchive'] : s['archive']),
        _item('reset', Icons.cleaning_services, s['reset']),
        _item('delete', Icons.delete_forever, s['delete_session']),
      ];

  @override
  Widget build(BuildContext context) {
    if (present && hasMap) {
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
                      Text('${session.name} · $shownCount', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 8),
                      IconButton(tooltip: s['qr_show'], icon: const Icon(Icons.qr_code), onPressed: _showQr),
                      IconButton(
                        tooltip: s['present_exit'],
                        icon: const Icon(Icons.fullscreen_exit),
                        onPressed: () => setState(() => present = false),
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
            Text(session.name, overflow: TextOverflow.ellipsis),
            Text(s['status_${session.status}'], style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(tooltip: s['qr_show'], icon: const Icon(Icons.qr_code), onPressed: _showQr),
          if (hasMap)
            IconButton(
              tooltip: s['present'],
              icon: const Icon(Icons.fullscreen),
              onPressed: () => setState(() => present = true),
            ),
          PopupMenuButton<String>(onSelected: _menu, itemBuilder: (_) => _menuItems()),
        ],
      ),
      bottomNavigationBar: wide || !hasMap
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
      body: !hasMap
          ? panel()
          : wide
          ? Row(
              children: [
                Expanded(child: _liveMap),
                const VerticalDivider(width: 1),
                SizedBox(width: 380, child: panel()),
              ],
            )
          : IndexedStack(index: _tab, children: [_liveMap, panel()]),
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
