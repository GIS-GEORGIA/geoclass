import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../geo_map.dart';
import '../l10n.dart';
import 'timelapse.dart';

/// One year's frame laid on the map over its site, as RotatedOverlayImage needs it: the grid is a UTM grid,
/// so its edges are not quite along the parallels. The last frame stays shown until the next has loaded.
Widget frameLayer(SiteFrames site, Frame frame) => OverlayImageLayer(
  overlayImages: [
    RotatedOverlayImage(
      topLeftCorner: site.corners[0],
      bottomLeftCorner: site.corners[3],
      bottomRightCorner: site.corners[2],
      imageProvider: NetworkImage(site.urlOf(frame)),
      gaplessPlayback: true,
    ),
  ],
);

/// An outline on the map: filled lightly, its edge in [colour]; dashed for the teacher's (the right answer).
Widget outlineLayer(Outline o, Color colour, {bool dashed = false, double width = 2.5}) => PolygonLayer(
  polygons: [
    for (final ring in o)
      Polygon(
        points: ring,
        color: colour.withValues(alpha: 0.18),
        borderColor: colour,
        borderStrokeWidth: width,
        pattern: dashed ? StrokePattern.dashed(segments: const [10, 6]) : const StrokePattern.solid(),
      ),
  ],
);

/// The ring being drawn: its line and its points, the first one bigger (touch near it to close the ring).
List<Widget> draftLayers(List<LatLng> draft, Color colour) => [
  if (draft.length > 1)
    PolylineLayer(
      polylines: [Polyline(points: draft, color: colour, strokeWidth: 2.5)],
    ),
  CircleLayer(
    circles: [
      for (final (i, p) in draft.indexed)
        CircleMarker(
          point: p,
          radius: i == 0 ? 7 : 4,
          color: colour,
          borderColor: Colors.white,
          borderStrokeWidth: 1.5,
        ),
    ],
  ),
];

/// The site's frame on a map fitted to it, with whatever the page lays over it.
class FrameMap extends StatelessWidget {
  final SiteFrames site;
  final Frame? frame;
  final List<Widget> layers;
  final void Function(LatLng)? onTap;
  final MapController? controller;
  const FrameMap({super.key, required this.site, this.frame, this.layers = const [], this.onTap, this.controller});

  @override
  Widget build(BuildContext context) {
    final bounds = LatLngBounds.fromPoints(site.corners);
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(8)),
        minZoom: 9,
        maxZoom: 17,
        onTap: onTap == null ? null : (_, p) => onTap!(p),
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
      ),
      children: [
        ...baseLayers(BaseMap.osm, 1),
        if (frame != null) frameLayer(site, frame!),
        ...layers,
        ...mapFurniture(BaseMap.osm),
      ],
    );
  }
}

/// What a frame is: "1990 · Landsat 5 TM · 30 m · 27.09.1990".
String frameLabel(Frame f) {
  final d = f.date.split('-');
  final date = d.length == 3 ? '${d[2]}.${d[1]}.${d[0]}' : f.date;
  return '${f.year} · ${f.sensor} · ${f.resolution} m · $date';
}

/// The years as a slider with a play button: one frame a second, round and round.
class YearPlayer extends StatefulWidget {
  final S s;
  final List<Frame> frames;
  final int year;
  final ValueChanged<int> onYear;
  const YearPlayer({super.key, required this.s, required this.frames, required this.year, required this.onYear});
  @override
  State<YearPlayer> createState() => _YearPlayerState();
}

class _YearPlayerState extends State<YearPlayer> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  int get _index => widget.frames.indexWhere((f) => f.year == widget.year).clamp(0, widget.frames.length - 1);

  void _toggle() => setState(() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      if (!mounted) return;
      widget.onYear(widget.frames[(_index + 1) % widget.frames.length].year);
    });
  });

  @override
  Widget build(BuildContext context) {
    final frames = widget.frames;
    if (frames.isEmpty) return const SizedBox.shrink();
    final i = _index;
    return Row(
      children: [
        IconButton(
          key: const Key('timelapse_play'),
          tooltip: widget.s[_timer == null ? 'timelapse_play' : 'timelapse_pause'],
          icon: Icon(_timer == null ? Icons.play_arrow : Icons.pause),
          onPressed: frames.length < 2 ? null : _toggle,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Slider(
                key: const Key('timelapse_year'),
                value: i.toDouble(),
                max: (frames.length - 1).toDouble(),
                divisions: frames.length > 1 ? frames.length - 1 : null,
                label: '${frames[i].year}',
                onChanged: frames.length < 2 ? null : (v) => widget.onYear(frames[v.round()].year),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(frameLabel(frames[i]), style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Drawing an outline ring by ring: each touch adds a point to the ring being drawn; a touch near its first
/// point (or the close button) closes it. Limits as the server's.
class OutlineDraft {
  final Outline rings;
  final List<LatLng> draft;
  final int maxRings, maxVertices;
  const OutlineDraft(this.rings, this.draft, {required this.maxRings, required this.maxVertices});

  int get vertices => vertexCount(rings) + draft.length;
  bool get full => rings.length >= maxRings || vertices >= maxVertices;
  bool get canClose => draft.length >= 3;
  bool get isEmpty => rings.isEmpty && draft.isEmpty;

  OutlineDraft _with(Outline r, List<LatLng> d) => OutlineDraft(r, d, maxRings: maxRings, maxVertices: maxVertices);

  /// A touch at [p]; [near] says whether it is close enough on screen to the ring's first point to close it.
  OutlineDraft tap(LatLng p, {bool near = false}) {
    if (near && canClose) return close();
    if (full) return this;
    return _with(rings, [...draft, p]);
  }

  OutlineDraft close() => canClose ? _with([...rings, draft], const []) : this;

  /// Takes back the last point, or opens the last ring again.
  OutlineDraft undo() {
    if (draft.isNotEmpty) return _with(rings, draft.sublist(0, draft.length - 1));
    if (rings.isEmpty) return this;
    return _with(rings.sublist(0, rings.length - 1), rings.last);
  }

  OutlineDraft clear() => _with(const [], const []);

  /// The finished rings; a ring still being drawn counts if it has three points.
  Outline get outline => [...rings, if (draft.length >= 3) draft];
}

/// Whether two places are within [px] screen pixels of each other on [camera].
bool nearOnScreen(MapCamera camera, LatLng a, LatLng b, {double px = 18}) =>
    (camera.latLngToScreenOffset(a) - camera.latLngToScreenOffset(b)).distance <= px;

/// Undo, close the ring and clear, for an [OutlineDraft].
Widget drawTools(S s, OutlineDraft d, ValueChanged<OutlineDraft> onChanged, {String keyPrefix = 'timelapse'}) => Wrap(
  spacing: 4,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [
    IconButton(
      key: Key('${keyPrefix}_undo'),
      tooltip: s['timelapse_undo'],
      icon: const Icon(Icons.undo),
      onPressed: d.isEmpty ? null : () => onChanged(d.undo()),
    ),
    TextButton.icon(
      key: Key('${keyPrefix}_close'),
      onPressed: d.canClose ? () => onChanged(d.close()) : null,
      icon: const Icon(Icons.check_circle_outline),
      label: Text(s['timelapse_close_ring']),
    ),
    IconButton(
      key: Key('${keyPrefix}_clear'),
      tooltip: s['timelapse_clear'],
      icon: const Icon(Icons.delete_outline),
      onPressed: d.isEmpty ? null : () => onChanged(d.clear()),
    ),
    Text(s.f('timelapse_vertices', [d.vertices, d.maxVertices]), style: const TextStyle(fontSize: 12)),
  ],
);
