import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../coords.dart';
import 'elevation.dart';

/// One point of a profile: how far along the line it is, and the height there (null where the grid has none).
class ProfileSample {
  /// Metres from the line's start, along the ground (the geodesic on the WGS84 ellipsoid).
  final double distance;
  final double? height;

  /// UTM position on the grid.
  final double x, y;

  /// Which section (segment between two vertices) the sample is on.
  final int section;

  const ProfileSample(this.distance, this.height, this.x, this.y, this.section);
}

/// The part of the line between two of its vertices.
class ProfileSection {
  final int index;

  /// Metres from the line's start to where the section begins, and its length.
  final double start, length;

  /// Heights at its two ends.
  final double? from, to;

  const ProfileSection(this.index, this.start, this.length, this.from, this.to);

  /// Mean grade from end to end: height change over horizontal distance (0.1 is 10 %), up positive.
  double? get grade => from == null || to == null || length == 0 ? null : (to! - from!) / length;

  /// The same as an angle, in degrees.
  double? get slopeDegrees => grade == null ? null : math.atan(grade!) * 180 / math.pi;
}

/// Heights along a line drawn on an area.
///
/// Samples go every half cell or less along each segment, straight in the grid's UTM coordinates (over a few
/// tens of kilometres this is the geodesic to well under a metre), with GDAL's bilinear height
/// ([ElevationGrid.heightAtUtm]). Distance along the line is each segment's geodesic length, shared out
/// evenly between its samples. test/terrain_test.dart checks all of it against GDAL and PROJ.
class TerrainProfile {
  final ElevationGrid grid;
  final List<LatLng> vertices;
  final List<ProfileSample> samples;
  final List<ProfileSection> sections;

  /// Total climb and drop: the sums of the rises and of the falls between neighbouring samples. Steps into or
  /// out of a gap in the data are left out. On a surface model, trees and buildings add a little to both.
  final double ascent, descent;

  /// The lowest and highest samples, or null when the line has no heights at all.
  final ProfileSample? lowest, highest;

  TerrainProfile._(
    this.grid,
    this.vertices,
    this.samples,
    this.sections,
    this.ascent,
    this.descent,
    this.lowest,
    this.highest,
  );

  /// The most samples one profile may have: a line across the largest area and back a few times.
  static const maxSamples = 50000;

  /// Throws [ArgumentError] for fewer than two vertices, or a line far too long for the area.
  factory TerrainProfile.along(ElevationGrid grid, List<LatLng> line) {
    if (line.length < 2) throw ArgumentError.value(line.length, 'line', 'needs two vertices or more');
    final zone = grid.meta.zone;
    final utm = [for (final p in line) toUtm(p.latitude, p.longitude, zone: zone)];
    final half = grid.cell / 2;
    final steps = [
      for (var k = 0; k + 1 < utm.length; k++)
        math.max(
          1,
          (math.sqrt(
                    math.pow(utm[k + 1].easting - utm[k].easting, 2) +
                        math.pow(utm[k + 1].northing - utm[k].northing, 2),
                  ) /
                  half)
              .ceil(),
        ),
    ];
    if (steps.fold(1, (a, b) => a + b) > maxSamples) {
      throw ArgumentError.value(line.length, 'line', 'too long for one profile');
    }

    const geodesic = Vincenty();
    final samples = <ProfileSample>[];
    final sections = <ProfileSection>[];
    var start = 0.0;
    for (var k = 0; k + 1 < utm.length; k++) {
      final a = utm[k], b = utm[k + 1];
      final length = geodesic.distance(line[k], line[k + 1]);
      final n = steps[k];
      for (var i = k == 0 ? 0 : 1; i <= n; i++) {
        final t = i / n;
        final x = a.easting + t * (b.easting - a.easting);
        final y = a.northing + t * (b.northing - a.northing);
        samples.add(ProfileSample(start + t * length, grid.heightAtUtm(x, y), x, y, k));
      }
      sections.add(
        ProfileSection(
          k,
          start,
          length,
          grid.heightAtUtm(a.easting, a.northing),
          grid.heightAtUtm(b.easting, b.northing),
        ),
      );
      start += length;
    }

    var ascent = 0.0, descent = 0.0;
    ProfileSample? lowest, highest;
    for (var i = 0; i < samples.length; i++) {
      final h = samples[i].height;
      if (h == null) continue;
      if (lowest == null || h < lowest.height!) lowest = samples[i];
      if (highest == null || h > highest.height!) highest = samples[i];
      final before = i == 0 ? null : samples[i - 1].height;
      if (before == null) continue;
      if (h > before) {
        ascent += h - before;
      } else {
        descent += before - h;
      }
    }
    return TerrainProfile._(grid, List.unmodifiable(line), samples, sections, ascent, descent, lowest, highest);
  }

  /// Metres along the ground from the first vertex to the last.
  double get length => sections.last.start + sections.last.length;

  /// The section with the steepest mean grade, up or down; null when no section has heights at both ends.
  ProfileSection? get steepest {
    ProfileSection? best;
    for (final s in sections) {
      if (s.grade == null) continue;
      if (best == null || s.grade!.abs() > best.grade!.abs()) best = s;
    }
    return best;
  }

  /// The sample nearest to [distance] metres along the line.
  ProfileSample nearest(double distance) {
    var lo = 0, hi = samples.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].distance <= distance) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (distance - samples[lo].distance).abs() <= (samples[hi].distance - distance).abs()
        ? samples[lo]
        : samples[hi];
  }

  /// The sample nearest to a point on the map, measured on the grid: for picking a place on the line by
  /// touching the map. Null when the point is further than [within] metres from every sample.
  ProfileSample? closestTo(LatLng p, {double within = double.infinity}) {
    final u = toUtm(p.latitude, p.longitude, zone: grid.meta.zone);
    ProfileSample? best;
    var bestD = within * within;
    for (final s in samples) {
      final d = (s.x - u.easting) * (s.x - u.easting) + (s.y - u.northing) * (s.y - u.northing);
      if (d <= bestD) {
        bestD = d;
        best = s;
      }
    }
    return best;
  }

  /// Where a sample is on the map.
  LatLng positionOf(ProfileSample sample) => fromUtm(grid.meta.zone, sample.x, sample.y);
}
