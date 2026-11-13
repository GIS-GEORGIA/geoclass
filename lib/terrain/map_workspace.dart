import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../geo_map.dart';
import '../l10n.dart';
import 'dem_loader.dart';
import 'elevation.dart';
import 'hillshade.dart';

/// The map every terrain game works on: the base map, the area's shaded relief, its outline, the height
/// where the map is touched, and the Copernicus notice. Games add their own layers on top ([layers]) and
/// get each touch with its height ([onTap]).
class MapWorkspace extends StatefulWidget {
  final ElevationGrid grid;
  final S s;

  /// Game layers, drawn above the relief and the outline.
  final List<Widget> layers;

  /// Called for every touch inside the area, with the height there (null where the grid has none).
  final void Function(LatLng point, double? height)? onTap;

  /// Show the touched point and its height in a box. Games that judge heights themselves turn this off.
  final bool showHeight;

  /// Extra switches for the layer panel.
  final List<Widget> panelChildren;

  final MapController? controller;

  const MapWorkspace({
    super.key,
    required this.grid,
    required this.s,
    this.layers = const [],
    this.onTap,
    this.showHeight = true,
    this.panelChildren = const [],
    this.controller,
  });

  @override
  State<MapWorkspace> createState() => _MapWorkspaceState();
}

class _MapWorkspaceState extends State<MapWorkspace> {
  late final MapController _map = widget.controller ?? MapController();
  BaseMap _base = BaseMap.osm;
  double _baseOpacity = 1;
  bool _relief = true;
  double _reliefOpacity = 0.55;
  bool _showLayers = false;
  LatLng? _picked;
  bool _ready = false, _moved = false;
  Size? _size;
  ReliefImage? _shade;
  late List<LatLng> _outline;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(MapWorkspace old) {
    super.didUpdateWidget(old);
    if (!identical(old.grid, widget.grid)) _prepare();
  }

  void _prepare() {
    _outline = widget.grid.outline;
    _picked = null;
    _moved = false;
    if (_ready) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fit() : null);
    _shade = ReliefImage(widget.grid);
  }

  LatLngBounds get _bounds => LatLngBounds.fromPoints(_outline);

  void _fit() => _map.fitCamera(CameraFit.bounds(bounds: _bounds, padding: const EdgeInsets.all(24)));

  /// Until the user moves the map, the whole area stays in view when the map's size changes
  /// (a phone turned, a window resized, or a map first laid out at zero size).
  void _sized(Size size) {
    if (size == _size) return;
    _size = size;
    if (!_ready || _moved || size.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_moved) _fit();
    });
  }

  void _tap(LatLng p) {
    if (_showLayers) {
      setState(() => _showLayers = false);
      return;
    }
    final h = widget.grid.heightAt(p);
    if (h == null && !_bounds.contains(p)) return; // outside the area: nothing to say
    if (widget.showHeight) setState(() => _picked = p);
    widget.onTap?.call(p, h);
  }

  void _showSource() {
    final meta = widget.grid.meta;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s['terrain_source']),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (baseSources[_base] case final b?) ...[
                Text('${s['base_map']}: ${b.attribution}'),
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => launchUrl(Uri.parse(b.attributionUrl)),
                  child: Text(b.attributionUrl),
                ),
                const SizedBox(height: 8),
              ],
              Text(meta.source),
              const SizedBox(height: 8),
              Text(s['terrain_surface_note']),
              const SizedBox(height: 8),
              SelectableText(meta.attribution, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s['close']))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.grid;
    final m = grid.meta;
    final picked = _picked;
    final pickedHeight = picked == null ? null : grid.heightAt(picked);
    final shade = _shade;
    final colour = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        _sized(constraints.biggest);
        return _stack(context, grid, m, picked, pickedHeight, shade, colour);
      },
    );
  }

  Widget _stack(
    BuildContext context,
    ElevationGrid grid,
    AreaMeta m,
    LatLng? picked,
    double? pickedHeight,
    ReliefImage? shade,
    Color colour,
  ) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _bounds.center,
            initialZoom: 12,
            minZoom: 9,
            maxZoom: 17,
            // The area is all there is to see, so the map stays over it.
            cameraConstraint: CameraConstraint.containCenter(bounds: _bounds),
            onMapReady: () {
              _ready = true;
              _fit();
            },
            onPositionChanged: (_, hasGesture) {
              if (hasGesture) _moved = true;
            },
            onTap: (_, p) => _tap(p),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            ...baseLayers(_base, _baseOpacity),
            if (_relief && shade != null)
              OverlayImageLayer(
                overlayImages: [
                  // Cell edges of the UTM grid; three corners also carry its slight turn against north.
                  RotatedOverlayImage(
                    topLeftCorner: _outline[3],
                    bottomLeftCorner: _outline[0],
                    bottomRightCorner: _outline[1],
                    imageProvider: shade,
                    opacity: _reliefOpacity,
                    gaplessPlayback: true,
                  ),
                ],
              ),
            PolylineLayer(
              polylines: [
                Polyline(points: [..._outline, _outline.first], color: colour, strokeWidth: 2),
              ],
            ),
            ...widget.layers,
            if (picked != null)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: picked,
                    radius: 6,
                    color: colour,
                    borderColor: Colors.white,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            // High enough to clear the credits, which take two lines on a phone.
            const Scalebar(alignment: Alignment.bottomLeft, padding: EdgeInsets.fromLTRB(8, 8, 8, 48)),
            // Not flutter_map's attribution row: two credits don't fit a phone's width on one line.
            Align(
              alignment: Alignment.bottomRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Material(
                  color: Colors.white.withValues(alpha: 0.85),
                  child: InkWell(
                    onTap: _showSource,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              [if (baseSources[_base] case final b?) b.attribution, s['terrain_credit']].join(' · '),
                              style: const TextStyle(fontSize: 12, color: Colors.black87),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.info_outline, size: 14, color: Colors.black87),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                heroTag: 'terrain_layers',
                tooltip: s['layers'],
                onPressed: () => setState(() => _showLayers = !_showLayers),
                child: const Icon(Icons.layers),
              ),
              const SizedBox(height: 4),
              FloatingActionButton.small(
                heroTag: 'terrain_fit',
                tooltip: s['terrain_whole_area'],
                onPressed: () {
                  _moved = false;
                  _fit();
                },
                child: const Icon(Icons.fit_screen),
              ),
              if (_showLayers)
                LayerPanel(
                  s: s,
                  base: _base,
                  opacity: _baseOpacity,
                  onBase: (b) => setState(() => _base = b),
                  onOpacity: (v) => setState(() => _baseOpacity = v),
                  children: [
                    const Divider(),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _relief,
                      title: Text(s['terrain_relief']),
                      onChanged: (v) => setState(() => _relief = v),
                    ),
                    if (_relief) ...[
                      Text(s['opacity'], style: Theme.of(context).textTheme.bodySmall),
                      Slider(value: _reliefOpacity, min: 0.1, onChanged: (v) => setState(() => _reliefOpacity = v)),
                    ],
                    ...widget.panelChildren,
                  ],
                ),
            ],
          ),
        ),
        if (widget.showHeight)
          Positioned(
            top: 8,
            left: 8,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.name(s.lang), style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      picked == null
                          ? s['terrain_tap_hint']
                          : pickedHeight == null
                          ? s['terrain_no_height']
                          : s.f('terrain_height', [pickedHeight.round()]),
                      key: const Key('terrain_height'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The shaded relief as RGBA pixels, one per cell: grey, opaque where there is shade, see-through at the
/// edge and where the grid is empty.
Uint8List reliefPixels(ElevationGrid grid) {
  final shade = hillshade(grid);
  final rgba = Uint8List(shade.length * 4);
  // One write per pixel: bytes R, G, B, A in memory are one little-endian word.
  final words = rgba.buffer.asUint32List();
  for (var i = 0; i < shade.length; i++) {
    final v = shade[i];
    if (v != 0) words[i] = 0xff000000 | v << 16 | v << 8 | v;
  }
  return rgba;
}

/// The relief handed to the map as an image straight from its pixels. Encoding a PNG first took
/// seconds in the browser for the larger areas; this takes a fraction of that.
class ReliefImage extends ImageProvider<ReliefImage> {
  final ElevationGrid grid;
  const ReliefImage(this.grid);

  @override
  Future<ReliefImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ReliefImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_decode().then((image) => ImageInfo(image: image)));

  Future<ui.Image> _decode() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(reliefPixels(grid), grid.width, grid.height, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  @override
  bool operator ==(Object other) => other is ReliefImage && identical(other.grid, grid);

  @override
  int get hashCode => identityHashCode(grid);
}

/// Loads an area and shows it in a [MapWorkspace], with a spinner meanwhile and a retry on failure.
class AreaMap extends StatefulWidget {
  final DemLoader loader;
  final String id;
  final int version;
  final S s;
  final Widget Function(BuildContext context, ElevationGrid grid) builder;

  const AreaMap({
    super.key,
    required this.loader,
    required this.id,
    required this.version,
    required this.s,
    required this.builder,
  });

  @override
  State<AreaMap> createState() => _AreaMapState();
}

class _AreaMapState extends State<AreaMap> {
  late Future<ElevationGrid> _grid = widget.loader.load(widget.id, widget.version);

  @override
  void didUpdateWidget(AreaMap old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.version != widget.version) {
      _grid = widget.loader.load(widget.id, widget.version);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ElevationGrid>(
    future: _grid,
    builder: (context, snap) {
      if (snap.hasData) return widget.builder(context, snap.data!);
      if (snap.hasError) {
        final e = snap.error;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terrain, size: 48),
                const SizedBox(height: 12),
                Text(widget.s[e is DemError ? e.key : 'dem_bad_data'], textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => setState(() {
                    _grid = widget.loader.load(widget.id, widget.version);
                  }),
                  child: Text(widget.s['retry']),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    },
  );
}
