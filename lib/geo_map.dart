import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

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
