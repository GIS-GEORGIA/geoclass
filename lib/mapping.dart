import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

const mapKinds = ['point', 'line', 'polygon'];
const mapCategories = ['food', 'icecream', 'cinema', 'stadium', 'square', 'park', 'attraction', 'school', 'shop', 'museum', 'other'];

/// One thing a student drew in the mapping game.
class MapObject {
  final String id, participantId, kind, category;
  final List<LatLng> points;
  final bool hidden;
  final int createdAt;

  const MapObject({
    required this.id,
    required this.participantId,
    required this.kind,
    required this.category,
    required this.points,
    this.hidden = false,
    this.createdAt = 0,
  });

  factory MapObject.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return MapObject(
      id: j['id'] as String,
      participantId: j['participantId'] as String,
      kind: a['kind'] as String,
      category: a['category'] as String,
      points: pointsFromCoords(a['coords'] as List),
      hidden: j['hidden'] as bool? ?? false,
      createdAt: j['createdAt'] as int,
    );
  }

  /// The middle of the vertices, where the server also places the object.
  LatLng get middle => middleOf(points);

  /// [lon, lat] pairs, as the server and GeoJSON keep them.
  List<List<double>> get coords => coordsOf(points);
}

LatLng middleOf(List<LatLng> points) => LatLng(
      points.map((p) => p.latitude).reduce((x, y) => x + y) / points.length,
      points.map((p) => p.longitude).reduce((x, y) => x + y) / points.length,
    );

List<List<double>> coordsOf(List<LatLng> points) => [
      for (final p in points) [p.longitude, p.latitude],
    ];

List<LatLng> pointsFromCoords(List coords) => [
      for (final c in coords) LatLng(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];

Color categoryColor(String category) => switch (category) {
      'food' => const Color(0xFFC62828),
      'icecream' => const Color(0xFFD81B60),
      'cinema' => const Color(0xFF6A1B9A),
      'stadium' => const Color(0xFF283593),
      'square' => const Color(0xFF558B2F),
      'park' => const Color(0xFF2E7D32),
      'attraction' => const Color(0xFFEF6C00),
      'school' => const Color(0xFF1565C0),
      'shop' => const Color(0xFF00838F),
      'museum' => const Color(0xFF5D4037),
      _ => const Color(0xFF455A64),
    };

IconData categoryIcon(String category) => switch (category) {
      'food' => Icons.restaurant,
      'icecream' => Icons.icecream,
      'cinema' => Icons.movie,
      'stadium' => Icons.stadium,
      'square' => Icons.deck,
      'park' => Icons.park,
      'attraction' => Icons.attractions,
      'school' => Icons.school,
      'shop' => Icons.store,
      'museum' => Icons.museum,
      _ => Icons.place,
    };

IconData kindIcon(String kind) => switch (kind) {
      'line' => Icons.timeline,
      'polygon' => Icons.pentagon_outlined,
      _ => Icons.place,
    };

/// Draws objects on a map. [faded] says which ones to show faintly.
List<Widget> mapObjectLayers(List<MapObject> objects, {bool Function(MapObject)? faded}) {
  double alpha(MapObject o) => faded?.call(o) ?? false ? 0.2 : 1;
  return [
    PolygonLayer(polygons: [
      for (final o in objects)
        if (o.kind == 'polygon')
          Polygon(
            points: o.points,
            color: categoryColor(o.category).withValues(alpha: 0.3 * alpha(o)),
            borderColor: categoryColor(o.category).withValues(alpha: alpha(o)),
            borderStrokeWidth: 2,
          ),
    ]),
    PolylineLayer(polylines: [
      for (final o in objects)
        if (o.kind == 'line')
          Polyline(points: o.points, color: categoryColor(o.category).withValues(alpha: alpha(o)), strokeWidth: 4),
    ]),
    MarkerLayer(markers: [
      for (final o in objects)
        Marker(
          point: o.kind == 'point' ? o.points.first : o.middle,
          width: 26,
          height: 26,
          child: Opacity(
            opacity: alpha(o),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: categoryColor(o.category),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(categoryIcon(o.category), color: Colors.white, size: 14),
            ),
          ),
        ),
    ]),
  ];
}

/// The time left as 2:05.
String formatClock(int seconds) {
  final left = seconds < 0 ? 0 : seconds;
  return '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
}
