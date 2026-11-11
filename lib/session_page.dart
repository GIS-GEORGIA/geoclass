import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import 'cards_session_page.dart';
import 'coordinates_session_page.dart';
import 'evidence_session_page.dart';
import 'export.dart';
import 'geo_map.dart';
import 'mapping_session_page.dart';
import 'models.dart';
import 'places.dart';
import 'plates_session_page.dart';
import 'puzzle_session_page.dart';
import 'session_base.dart';
import 'settings.dart';

/// The page for a session, according to its game.
Widget sessionPageFor(Settings settings, SessionInfo session, {bool showQr = false}) => switch (session.game) {
      'travel' => TravelSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      'cards' => CardsSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      'evidence' => EvidenceSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      'plates' => PlatesSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      'puzzle' => PuzzleSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      'mapping' => MappingSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
      _ => CoordinatesSessionPage(settings: settings, session: session, showQrOnOpen: showQr),
    };

/// The travel game: live answers on the map, moderation and statistics.
class TravelSessionPage extends SessionPageBase {
  const TravelSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<TravelSessionPage> createState() => _TravelSessionPageState();
}

class _TravelSessionPageState extends SessionPageState<TravelSessionPage> {
  List<TravelAnswer> _answers = const [];
  bool _showStats = false;
  String _query = '';
  TravelAnswer? _selected;
  bool _showAnswers = true;
  bool _showRoutes = false;

  List<TravelAnswer> get _shown => _answers.where((a) => !a.hidden).toList();

  @override
  void onRows(List<Map<String, dynamic>> rows) {
    _answers = [for (final r in rows) TravelAnswer.fromJson(r)];
    if (_selected != null) {
      final id = _selected!.id;
      _selected = _answers.where((a) => a.id == id && !a.hidden).firstOrNull;
    }
  }

  @override
  List<LatLng> get fitPoints => [for (final a in _shown) LatLng(a.lat, a.lon)];
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _shown.length;
  @override
  String exportCsv() => answersToCsv(_answers);
  @override
  String exportGeoJson() => answersToGeoJson(_answers);

  @override
  void onMapTap() {
    if (_selected != null) setState(() => _selected = null);
  }

  Color _colorFor(String transport) => switch (transport) {
        'plane' => const Color(0xFF1565C0),
        'train' => const Color(0xFF6A1B9A),
        'car' => const Color(0xFFC62828),
        'bus' => const Color(0xFFEF6C00),
        'ship' => const Color(0xFF00838F),
        'bike' => const Color(0xFF2E7D32),
        _ => const Color(0xFF5D4037),
      };

  @override
  List<Widget> mapLayers() {
    final shown = _shown;
    return [
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
            markers: [
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
            ],
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
    ];
  }

  @override
  List<Widget> mapOverlays() => [
        if (_selected != null)
          Positioned(
            left: 8,
            right: 8,
            bottom: 40,
            child: Center(child: _answerCard(_selected!)),
          ),
      ];

  @override
  List<Widget> layerSwitches() => [
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
            await widget.settings.setOrigin(mapController.camera.center);
            setState(() {});
            say(s['origin_set']);
          },
        ),
      ];

  Widget _answerCard(TravelAnswer a) {
    final country = a.country.isEmpty ? '' : placeIndex?.countryName(a.country, lang) ?? a.country;
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

  @override
  Widget panel() => Column(
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
                showMapTab();
              });
              final zoom = mapController.camera.zoom;
              mapController.move(LatLng(a.lat, a.lon), zoom < 5 ? 5 : zoom);
            },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: a.hidden ? s['show'] : s['hide'],
            icon: Icon(a.hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => run(() => api.setHidden(a.id, !a.hidden)),
          ),
          IconButton(
            tooltip: s['delete'],
            icon: const Icon(Icons.delete_outline),
            onPressed: () => run(() => api.deleteResponse(a.id)),
          ),
        ],
      ),
    );
  }

  Widget _statsView() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _bars(s['top_places'], countBy(_answers, (a) => a.place).take(8).toList(), (k) => k),
          _bars(s['top_countries'], countBy(_answers, (a) => a.country).take(8).toList(), (k) => placeIndex?.countryName(k, lang) ?? k),
          _bars(s['transport_stats'], countBy(_answers, (a) => a.transport), (k) => s['transport_$k']),
          _bars(s['company_stats'], countBy(_answers, (a) => a.company), (k) => s['company_$k']),
        ],
      );

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
}
