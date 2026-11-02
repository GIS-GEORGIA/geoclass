import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'coords.dart';
import 'l10n.dart';

enum BaseMap { osm, topo, none }

/// Base maps live here only, so a provider can be changed in one place.
class BaseSource {
  final String url, attribution, attributionUrl;
  final int maxNativeZoom;
  const BaseSource(this.url, this.attribution, this.attributionUrl, this.maxNativeZoom);
}

const baseSources = {
  BaseMap.osm: BaseSource(
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'OpenStreetMap contributors',
    'https://www.openstreetmap.org/copyright',
    19,
  ),
  BaseMap.topo: BaseSource(
    'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    'OpenStreetMap contributors, OpenTopoMap (CC BY-SA)',
    'https://opentopomap.org/about',
    17,
  ),
};

/// Base map tiles plus the always-visible attribution and scale bar.
List<Widget> baseLayers(BaseMap base, double opacity) {
  final source = baseSources[base];
  if (source == null) return const [];
  return [
    Opacity(
      opacity: opacity,
      child: TileLayer(
        urlTemplate: source.url,
        userAgentPackageName: 'ge.qgis.geoclass',
        maxNativeZoom: source.maxNativeZoom,
        maxZoom: 20,
      ),
    ),
  ];
}

List<Widget> mapFurniture(BaseMap base) {
  final source = baseSources[base];
  return [
    const Scalebar(alignment: Alignment.bottomLeft, padding: EdgeInsets.fromLTRB(8, 8, 8, 28)),
    if (source != null)
      SimpleAttributionWidget(
        source: Text(source.attribution),
        onTap: () => launchUrl(Uri.parse(source.attributionUrl)),
      ),
  ];
}

IconData transportIcon(String t) => switch (t) {
      'plane' => Icons.flight,
      'train' => Icons.train,
      'car' => Icons.directions_car,
      'bus' => Icons.directions_bus,
      'ship' => Icons.directions_boat,
      'bike' => Icons.directions_bike,
      _ => Icons.directions_walk,
    };

/// Base map choice, opacity and caller-provided overlays.
class LayerPanel extends StatelessWidget {
  final S s;
  final BaseMap base;
  final double opacity;
  final ValueChanged<BaseMap> onBase;
  final ValueChanged<double> onOpacity;
  final List<Widget> children;

  const LayerPanel({
    super.key,
    required this.s,
    required this.base,
    required this.opacity,
    required this.onBase,
    required this.onOpacity,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) => Card(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s['base_map'], style: Theme.of(context).textTheme.titleSmall),
                RadioGroup<BaseMap>(
                  groupValue: base,
                  onChanged: (v) => onBase(v!),
                  child: Column(
                    children: [
                      for (final b in BaseMap.values)
                        RadioListTile<BaseMap>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: b,
                          title: Text(s['base_${b.name}']),
                        ),
                    ],
                  ),
                ),
                if (base != BaseMap.none) ...[
                  Text(s['opacity'], style: Theme.of(context).textTheme.bodySmall),
                  Slider(value: opacity, min: 0.2, onChanged: onOpacity),
                ],
                ...children,
              ],
            ),
          ),
        ),
      );
}

const _niceDegrees = [20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001];
const _niceMetres = [100000.0, 50000.0, 20000.0, 10000.0, 5000.0, 2000.0, 1000.0, 500.0, 200.0, 100.0];

// Whole degrees, then minutes, then seconds, so DMS labels stay round numbers.
const _niceDms = [
  20.0, 10.0, 5.0, 2.0, 1.0,
  30 / 60, 20 / 60, 10 / 60, 5 / 60, 2 / 60, 1 / 60,
  30 / 3600, 20 / 3600, 10 / 3600, 5 / 3600, 2 / 3600, 1 / 3600,
];

// Whole degrees, then minutes, then decimal minutes.
const _niceDm = [
  20.0, 10.0, 5.0, 2.0, 1.0,
  30 / 60, 20 / 60, 10 / 60, 5 / 60, 2 / 60, 1 / 60,
  0.5 / 60, 0.2 / 60, 0.1 / 60, 0.05 / 60, 0.02 / 60, 0.01 / 60,
];

double _niceStep(double span, List<double> steps) => steps.firstWhere((s) => span / s >= 4, orElse: () => steps.last);

/// As [_niceStep], but coarser when the labels along the line wouldn't fit side by side.
double _fittingStep(double span, List<double> steps, double pixels, double labelWidth) {
  final fine = _niceStep(span, steps);
  return steps.lastWhere((s) => s >= fine && span / s * labelWidth <= pixels, orElse: () => steps.first);
}

// Label positions keep clear of the corners: the scale bar and attribution sit along the bottom.
const _labelHeight = 18.0;
const _bottomClear = 60.0;

Widget _gridLabel(BuildContext context, String text) => Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        color: Colors.white.withValues(alpha: 0.8),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.black87), maxLines: 1, overflow: TextOverflow.clip),
      ),
    );

const _gridColor = Color(0x99003D33);

/// Latitude and longitude lines, finer as the map zooms in, so coordinates can be read off the map.
class GraticuleLayer extends StatelessWidget {
  /// How the labels are written and where the lines fall: dd, dm or dms.
  final String format;
  const GraticuleLayer({super.key, this.format = 'dd'});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final size = camera.nonRotatedSize;
    final b = camera.visibleBounds;
    final south = b.south.clamp(-85.0, 85.0);
    final north = b.north.clamp(-85.0, 85.0);
    final west = b.west.clamp(-180.0, 180.0);
    final east = b.east.clamp(-180.0, 180.0);
    final labelWidth = switch (format) { 'dms' => 78.0, 'dm' => 72.0, _ => 56.0 };
    final steps = switch (format) { 'dms' => _niceDms, 'dm' => _niceDm, _ => _niceDegrees };
    final step = _niceStep(north - south, steps);
    final decimals = step >= 1 ? 0 : (step >= 0.1 ? 1 : (step >= 0.01 ? 2 : 3));

    final lines = <Polyline>[];
    final labels = <Marker>[];
    for (var i = (south / step).ceil(); i * step <= north; i++) {
      final lat = i * step;
      lines.add(Polyline(points: [LatLng(lat, west), LatLng(lat, east)], color: _gridColor, strokeWidth: 1));
      if (lat < south + (north - south) * _bottomClear / size.height) continue;
      labels.add(Marker(
        point: LatLng(lat, west),
        width: labelWidth,
        height: _labelHeight,
        alignment: Alignment.centerRight,
        child: _gridLabel(context, switch (format) { 'dms' => dmsTick(lat), 'dm' => dmTick(lat), _ => '${lat.toStringAsFixed(decimals)}°' }),
      ));
    }
    final lonStep = _fittingStep(east - west, steps, size.width, labelWidth);
    final lonDecimals = lonStep >= 1 ? 0 : (lonStep >= 0.1 ? 1 : (lonStep >= 0.01 ? 2 : 3));
    final labelLat = north - (north - south) * (_labelHeight / 2 + 2) / size.height;
    for (var i = (west / lonStep).ceil(); i * lonStep <= east; i++) {
      final lon = i * lonStep;
      lines.add(Polyline(points: [LatLng(south, lon), LatLng(north, lon)], color: _gridColor, strokeWidth: 1));
      if (lon < west + (east - west) * labelWidth / size.width) continue; // the latitude labels are here
      labels.add(Marker(
        point: LatLng(labelLat, lon),
        width: labelWidth,
        height: _labelHeight,
        alignment: Alignment.centerRight,
        child: _gridLabel(context, switch (format) { 'dms' => dmsTick(lon), 'dm' => dmTick(lon), _ => '${lon.toStringAsFixed(lonDecimals)}°' }),
      ));
    }
    return Stack(children: [PolylineLayer(polylines: lines), MarkerLayer(markers: labels)]);
  }
}

/// UTM easting and northing lines in one zone. Hidden when zoomed too far out to be useful.
class UtmGridLayer extends StatelessWidget {
  final int zone;
  const UtmGridLayer({super.key, required this.zone});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final size = camera.nonRotatedSize;
    final b = camera.visibleBounds;
    if (b.north - b.south > 12 || b.east - b.west > 16) return const SizedBox.shrink();

    final corners = [
      toUtm(b.south, b.west, zone: zone),
      toUtm(b.south, b.east, zone: zone),
      toUtm(b.north, b.west, zone: zone),
      toUtm(b.north, b.east, zone: zone),
    ];
    final minE = corners.map((u) => u.easting).reduce((a, c) => a < c ? a : c);
    final maxE = corners.map((u) => u.easting).reduce((a, c) => a > c ? a : c);
    final minN = corners.map((u) => u.northing).reduce((a, c) => a < c ? a : c);
    final maxN = corners.map((u) => u.northing).reduce((a, c) => a > c ? a : c);
    const labelWidth = 100.0;
    // One step for both directions keeps the squares square, and the easting labels (about 78 px) must fit.
    final step = _fittingStep(maxN - minN, _niceMetres, size.width * (maxN - minN) / (maxE - minE), 78);

    final lines = <Polyline>[];
    final labels = <Marker>[];
    for (var i = (minE / step).ceil(); i * step <= maxE; i++) {
      final e = i * step;
      lines.add(Polyline(points: [fromUtm(zone, e, minN), fromUtm(zone, e, maxN)], color: _gridColor, strokeWidth: 1));
      final lon = fromUtm(zone, e, (minN + maxN) / 2).longitude;
      if (lon < b.west + (b.east - b.west) * labelWidth / size.width) continue; // the northing labels are here
      labels.add(Marker(
        point: LatLng(b.north - (b.north - b.south) * (_labelHeight / 2 + 2) / size.height, lon),
        width: labelWidth,
        height: _labelHeight,
        alignment: Alignment.centerRight,
        child: _gridLabel(context, 'E ${e.round()}'),
      ));
    }
    for (var i = (minN / step).ceil(); i * step <= maxN; i++) {
      final n = i * step;
      lines.add(Polyline(points: [fromUtm(zone, minE, n), fromUtm(zone, maxE, n)], color: _gridColor, strokeWidth: 1));
      final lat = fromUtm(zone, minE, n).latitude;
      if (lat < b.south + (b.north - b.south) * _bottomClear / size.height) continue;
      labels.add(Marker(
        point: LatLng(lat, b.west),
        width: labelWidth,
        height: _labelHeight,
        alignment: Alignment.centerRight,
        child: _gridLabel(context, 'N ${n.round()}'),
      ));
    }
    return Stack(children: [PolylineLayer(polylines: lines), MarkerLayer(markers: labels)]);
  }
}
