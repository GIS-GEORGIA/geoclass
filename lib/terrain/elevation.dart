import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../coords.dart';

/// One area in /areas/catalog.json: enough to list it and to ask for its files.
class AreaSummary {
  final String id;
  final int version;
  final String ka, en;

  /// WGS84 [west, south, east, north].
  final List<double> bbox;
  final double min, max;

  const AreaSummary(this.id, this.version, this.ka, this.en, this.bbox, this.min, this.max);

  factory AreaSummary.fromJson(Map<String, dynamic> j) => AreaSummary(
    _id(j['id']),
    _version(j['version']),
    j['ka'] as String,
    j['en'] as String,
    _bbox(j['bbox']),
    (j['min'] as num).toDouble(),
    (j['max'] as num).toDouble(),
  );

  String name(String lang) => lang == 'ka' ? ka : en;
}

/// The area.json written by tool/areas/build_area.py.
class AreaMeta {
  final String id;
  final int version;
  final String ka, en;
  final List<double> bbox;

  /// UTM zone of the grid (the packages use EPSG:326xx, WGS84 UTM north).
  final int zone;

  /// UTM [left, bottom, right, top] of the whole grid, in metres.
  final List<double> bounds;
  final double cell;
  final int width, height;
  final double scale;
  final int nodata;
  final String sha256;
  final double min, max;
  final String attribution, source, surface;

  const AreaMeta({
    required this.id,
    required this.version,
    required this.ka,
    required this.en,
    required this.bbox,
    required this.zone,
    required this.bounds,
    required this.cell,
    required this.width,
    required this.height,
    required this.scale,
    required this.nodata,
    required this.sha256,
    required this.min,
    required this.max,
    required this.attribution,
    required this.source,
    required this.surface,
  });

  /// Reads and checks area.json. Throws [FormatException] for anything this app can't use.
  factory AreaMeta.fromJson(Map<String, dynamic> j) {
    final crs = RegExp(r'^EPSG:326(\d\d)$').firstMatch(j['crs'] as String? ?? '');
    final zone = crs == null ? 0 : int.parse(crs.group(1)!);
    if (zone < 1 || zone > 60) throw FormatException('unsupported grid: ${j['crs']}');
    final grid = j['grid'] as Map<String, dynamic>;
    if (grid['type'] != 'uint16le') throw FormatException('unsupported cell type: ${grid['type']}');
    final width = j['width'] as int, height = j['height'] as int;
    // A phone holds a few million cells easily; anything bigger is a mistake in the build.
    if (width < 2 || height < 2 || width > 4000 || height > 4000) throw FormatException('bad size: $width×$height');
    final cell = (j['cell'] as num).toDouble();
    final bounds = [for (final v in j['bounds'] as List) (v as num).toDouble()];
    if (bounds.length != 4 ||
        cell <= 0 ||
        (bounds[2] - bounds[0] - width * cell).abs() > 1e-6 ||
        (bounds[3] - bounds[1] - height * cell).abs() > 1e-6) {
      throw const FormatException('bounds do not match the size');
    }
    final sha = grid['sha256'] as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) throw const FormatException('bad sha256');
    return AreaMeta(
      id: _id(j['id']),
      version: _version(j['version']),
      ka: j['ka'] as String,
      en: j['en'] as String,
      bbox: _bbox(j['bbox']),
      zone: zone,
      bounds: bounds,
      cell: cell,
      width: width,
      height: height,
      scale: (grid['scale'] as num).toDouble(),
      nodata: grid['nodata'] as int,
      sha256: sha,
      min: (j['min'] as num).toDouble(),
      max: (j['max'] as num).toDouble(),
      attribution: j['attribution'] as String,
      source: j['source'] as String,
      surface: j['surface'] as String? ?? '',
    );
  }

  String name(String lang) => lang == 'ka' ? ka : en;
}

/// Heights on a square UTM grid. Rows run north to south; each value is the height at the cell's centre.
class ElevationGrid {
  final AreaMeta meta;
  final Uint16List _steps;

  ElevationGrid._(this.meta, this._steps);

  /// [bytes]: the decoded dem.u16 grid. Throws [FormatException] when the size is wrong.
  factory ElevationGrid.fromBytes(AreaMeta meta, Uint8List bytes) {
    final cells = meta.width * meta.height;
    if (bytes.length != cells * 2) {
      throw FormatException('grid has ${bytes.length} bytes, expected ${cells * 2}');
    }
    final data = ByteData.sublistView(bytes);
    final steps = Uint16List(cells);
    for (var i = 0; i < cells; i++) {
      steps[i] = data.getUint16(i * 2, Endian.little);
    }
    return ElevationGrid._(meta, steps);
  }

  int get width => meta.width;
  int get height => meta.height;
  double get cell => meta.cell;

  /// The stored height of one cell in metres, or null where there is no data.
  double? cellHeight(int row, int col) {
    if (row < 0 || col < 0 || row >= height || col >= width) return null;
    final v = _steps[row * width + col];
    return v == meta.nodata ? null : v * meta.scale;
  }

  /// UTM position of a cell's centre.
  ({double x, double y}) cellCentre(int row, int col) =>
      (x: meta.bounds[0] + (col + 0.5) * cell, y: meta.bounds[3] - (row + 0.5) * cell);

  bool containsUtm(double x, double y) =>
      x >= meta.bounds[0] && x <= meta.bounds[2] && y >= meta.bounds[1] && y <= meta.bounds[3];

  /// The height at a UTM point, bilinear between the four nearest cell centres, as GDAL does it:
  /// null outside the grid or when the cell under the point has no data; empty neighbours are left out
  /// and the others weighted up. Within half a cell of the edge, the edge cells are used.
  double? heightAtUtm(double x, double y) {
    if (!containsUtm(x, y)) return null;
    final fx = (x - meta.bounds[0]) / cell;
    final fy = (meta.bounds[3] - y) / cell;
    final under = cellHeight(fy.floor().clamp(0, height - 1), fx.floor().clamp(0, width - 1));
    if (under == null) return null;
    final gx = (fx - 0.5).clamp(0.0, width - 1.0);
    final gy = (fy - 0.5).clamp(0.0, height - 1.0);
    final c0 = gx.floor(), r0 = gy.floor();
    final tx = gx - c0, ty = gy - r0;
    var sum = 0.0, weight = 0.0;
    void add(int r, int c, double w) {
      if (w == 0) return;
      final h = cellHeight(r, c);
      if (h == null) return;
      sum += h * w;
      weight += w;
    }

    add(r0, c0, (1 - tx) * (1 - ty));
    add(r0, c0 + 1, tx * (1 - ty));
    add(r0 + 1, c0, (1 - tx) * ty);
    add(r0 + 1, c0 + 1, tx * ty);
    return weight == 0 ? under : sum / weight;
  }

  /// The height at a map position, or null outside the grid.
  double? heightAt(LatLng p) {
    final u = toUtm(p.latitude, p.longitude, zone: meta.zone);
    return heightAtUtm(u.easting, u.northing);
  }

  /// Corners of the grid on the map, south-west first, anticlockwise.
  List<LatLng> get outline => [
    fromUtm(meta.zone, meta.bounds[0], meta.bounds[1]),
    fromUtm(meta.zone, meta.bounds[2], meta.bounds[1]),
    fromUtm(meta.zone, meta.bounds[2], meta.bounds[3]),
    fromUtm(meta.zone, meta.bounds[0], meta.bounds[3]),
  ];
}

String _id(Object? v) {
  final id = v as String;
  if (!RegExp(r'^[a-z0-9-]{1,40}$').hasMatch(id)) throw FormatException('bad area id: $id');
  return id;
}

int _version(Object? v) {
  final n = v as int;
  if (n < 1 || n > 9999) throw FormatException('bad version: $n');
  return n;
}

List<double> _bbox(Object? v) {
  final b = [for (final x in v as List) (x as num).toDouble()];
  if (b.length != 4 || b[0] >= b[2] || b[1] >= b[3]) throw const FormatException('bad bbox');
  return b;
}
