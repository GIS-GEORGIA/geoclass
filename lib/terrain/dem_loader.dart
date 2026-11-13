import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import 'elevation.dart';
import 'watershed.dart';

/// Why an area could not be loaded. [key] is a translation key.
class DemError implements Exception {
  final String key;
  final String detail;
  DemError(this.key, [this.detail = '']);
  @override
  String toString() => detail.isEmpty ? key : '$key: $detail';
}

/// Loads the terrain areas served at /areas/* (worker/src/areas.ts).
///
/// The grid is sent gzip-compressed with Content-Encoding: gzip; the browser, and dart:io on Android,
/// undo that, so the bytes received are the raw grid. Its size and sha256 are checked against area.json
/// before use. Loaded grids are kept for the life of the loader; on the web the service worker also keeps
/// the files for offline use.
class DemLoader {
  final http.Client _client;
  final String _base;
  final Duration timeout;
  final _grids = <String, Future<ElevationGrid>>{};
  final _flows = <String, Future<FlowGrid>>{};

  DemLoader({http.Client? client, String? base, this.timeout = const Duration(seconds: 30)})
    : _client = client ?? http.Client(),
      _base = base ?? publicUrl;

  Future<List<AreaSummary>> catalog() async {
    final body = await _get('areas/catalog.json');
    try {
      final j = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      return [for (final a in j['areas'] as List) AreaSummary.fromJson(a as Map<String, dynamic>)];
    } on Object catch (e) {
      throw DemError('dem_bad_data', '$e');
    }
  }

  /// One area's grid. Asking again for the same area and version gives the same grid, fetched once;
  /// a failed load is forgotten, so the next call tries again.
  Future<ElevationGrid> load(String id, int version) => _once(_grids, '$id/$version', () => _load(id, version));

  /// One area's flow directions (tool/areas/build_watershed.py), checked against watershed.json's sha256 and
  /// the grid's size; kept like the grids.
  Future<FlowGrid> loadFlow(String id, int version) => _once(_flows, '$id/$version', () => _loadFlow(id, version));

  static Future<T> _once<T>(Map<String, Future<T>> cache, String key, Future<T> Function() start) {
    final cached = cache[key];
    if (cached != null) return cached;
    final loading = start();
    cache[key] = loading;
    loading.then(
      (_) {},
      onError: (Object _) {
        if (identical(cache[key], loading)) cache.remove(key);
      },
    );
    return loading;
  }

  Future<FlowGrid> _loadFlow(String id, int version) async {
    final grid = await load(id, version);
    final String sha;
    final int streamCells;
    try {
      final j = jsonDecode(utf8.decode(await _get('areas/$id/$version/watershed.json'))) as Map<String, dynamic>;
      sha = j['sha256'] as String;
      streamCells = (j['stream_cells'] as num).toInt();
    } on DemError {
      rethrow;
    } on Object catch (e) {
      throw DemError('dem_bad_data', '$e');
    }
    final bytes = await _get('areas/$id/$version/flow.u8.gz');
    if (bytes.length != grid.width * grid.height) {
      throw DemError('dem_bad_data', 'flow has ${bytes.length} bytes, expected ${grid.width * grid.height}');
    }
    if (sha256.convert(bytes).toString() != sha) throw DemError('dem_bad_data', 'flow sha256 differs');
    return FlowGrid(grid.width, grid.height, bytes, streamCells: streamCells);
  }

  Future<ElevationGrid> _load(String id, int version) async {
    if (!RegExp(r'^[a-z0-9-]{1,40}$').hasMatch(id) || version < 1) throw DemError('dem_bad_data', 'bad area');
    final AreaMeta meta;
    try {
      final j = jsonDecode(utf8.decode(await _get('areas/$id/$version/area.json'))) as Map<String, dynamic>;
      meta = AreaMeta.fromJson(j);
    } on DemError {
      rethrow;
    } on Object catch (e) {
      throw DemError('dem_bad_data', '$e');
    }
    if (meta.id != id || meta.version != version) throw DemError('dem_bad_data', 'area.json is for another area');
    final bytes = await _get('areas/$id/$version/dem.u16.gz');
    if (bytes.length != meta.width * meta.height * 2) {
      throw DemError('dem_bad_data', 'grid has ${bytes.length} bytes, expected ${meta.width * meta.height * 2}');
    }
    if (sha256.convert(bytes).toString() != meta.sha256) throw DemError('dem_bad_data', 'grid sha256 differs');
    return ElevationGrid.fromBytes(meta, bytes);
  }

  Future<Uint8List> _get(String path) async {
    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$_base/$path')).timeout(timeout);
    } on TimeoutException {
      throw DemError('dem_offline', 'timeout');
    } on Exception catch (e) {
      throw DemError('dem_offline', '$e');
    }
    if (res.statusCode == 404) throw DemError('dem_not_found', path);
    if (res.statusCode != 200) throw DemError('dem_offline', 'HTTP ${res.statusCode}');
    return res.bodyBytes;
  }
}
