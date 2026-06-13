import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Pure geodesic + geometry helpers used by route planning and navigation.
///
/// Everything here is side-effect free and unit-tested in
/// `test/route_geo_test.dart`. Distances are in meters, bearings in degrees
/// (0 = north, clockwise). For the short legs we deal with (a Swiss tour is
/// at most a few hundred km) a spherical earth is plenty accurate.

const double earthRadiusM = 6371000.0;

double _deg2rad(double d) => d * math.pi / 180.0;

/// Great-circle distance between two points, in meters.
double haversineMeters(LatLng a, LatLng b) {
  final dLat = _deg2rad(b.latitude - a.latitude);
  final dLon = _deg2rad(b.longitude - a.longitude);
  final la1 = _deg2rad(a.latitude);
  final la2 = _deg2rad(b.latitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Initial bearing from [a] to [b] in degrees (0 = north, clockwise).
double bearingDeg(LatLng a, LatLng b) {
  final la1 = _deg2rad(a.latitude);
  final la2 = _deg2rad(b.latitude);
  final dLon = _deg2rad(b.longitude - a.longitude);
  final y = math.sin(dLon) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLon);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}

/// Total length of a polyline, in meters.
double pathLengthMeters(List<LatLng> pts) {
  var sum = 0.0;
  for (var i = 1; i < pts.length; i++) {
    sum += haversineMeters(pts[i - 1], pts[i]);
  }
  return sum;
}

/// Cumulative distance from the start of the polyline to each vertex.
/// `result[0] == 0`, `result.last == pathLengthMeters`.
List<double> cumulativeMeters(List<LatLng> path) {
  final cum = List<double>.filled(path.length, 0.0);
  for (var i = 1; i < path.length; i++) {
    cum[i] = cum[i - 1] + haversineMeters(path[i - 1], path[i]);
  }
  return cum;
}

/// "Curviness" of a polyline: total absolute heading change (degrees) per
/// kilometre. ~0 for a dead-straight road, rising into the hundreds for tight
/// switchbacks. This is the metric behind the curviness slider's preview and
/// the alternative-route selection.
double curvinessScore(List<LatLng> pts) {
  if (pts.length < 3) return 0;
  var turn = 0.0;
  for (var i = 1; i < pts.length - 1; i++) {
    final b1 = bearingDeg(pts[i - 1], pts[i]);
    final b2 = bearingDeg(pts[i], pts[i + 1]);
    var d = (b2 - b1).abs() % 360.0;
    if (d > 180.0) d = 360.0 - d;
    turn += d;
  }
  final km = pathLengthMeters(pts) / 1000.0;
  if (km < 0.05) return 0;
  return turn / km;
}

/// Result of projecting a point onto a polyline.
class SnapResult {
  const SnapResult({
    required this.segmentIndex,
    required this.point,
    required this.crossTrackMeters,
    required this.alongMeters,
  });

  /// Index of the polyline segment the point snapped onto (segment `i` spans
  /// vertices `i` → `i + 1`).
  final int segmentIndex;

  /// The closest point ON the polyline.
  final LatLng point;

  /// Perpendicular distance from the input point to the polyline, in meters.
  final double crossTrackMeters;

  /// Distance from the start of the polyline to [point], measured along the
  /// line, in meters.
  final double alongMeters;
}

/// Projects [p] onto [path] and returns the nearest point on the line, how far
/// off the line [p] is, and how far along the line that nearest point sits.
///
/// Uses a local equirectangular projection centred on [p] — exact enough at
/// the scale of a single GPS fix vs. a nearby road.
SnapResult? snapToPath(LatLng p, List<LatLng> path, {List<double>? cumulative}) {
  if (path.isEmpty) return null;
  if (path.length == 1) {
    return SnapResult(
      segmentIndex: 0,
      point: path.first,
      crossTrackMeters: haversineMeters(p, path.first),
      alongMeters: 0,
    );
  }
  final cum = cumulative ?? cumulativeMeters(path);
  final mPerLat = 111320.0;
  final mPerLon = 111320.0 * math.cos(_deg2rad(p.latitude));
  double px(LatLng q) => (q.longitude - p.longitude) * mPerLon;
  double py(LatLng q) => (q.latitude - p.latitude) * mPerLat;

  var bestD = double.infinity;
  var bestSeg = 0;
  var bestT = 0.0;
  var bestAlong = 0.0;
  for (var i = 0; i < path.length - 1; i++) {
    final ax = px(path[i]), ay = py(path[i]);
    final bx = px(path[i + 1]), by = py(path[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final segLen2 = dx * dx + dy * dy;
    // Projection parameter of the origin (p) onto segment a→b, clamped to it.
    var t = segLen2 == 0 ? 0.0 : -(ax * dx + ay * dy) / segLen2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    final d = math.sqrt(cx * cx + cy * cy);
    if (d < bestD) {
      bestD = d;
      bestSeg = i;
      bestT = t;
      bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
    }
  }
  final a = path[bestSeg], b = path[bestSeg + 1];
  final snap = LatLng(
    a.latitude + (b.latitude - a.latitude) * bestT,
    a.longitude + (b.longitude - a.longitude) * bestT,
  );
  return SnapResult(
    segmentIndex: bestSeg,
    point: snap,
    crossTrackMeters: bestD,
    alongMeters: bestAlong,
  );
}

/// Geometric midpoint (by distance) of a polyline — the point half-way along
/// its length. Used to place the "drag me to bend the route" handles.
LatLng midpointAlong(List<LatLng> path) {
  if (path.isEmpty) return const LatLng(0, 0);
  if (path.length == 1) return path.first;
  final cum = cumulativeMeters(path);
  final half = cum.last / 2.0;
  for (var i = 1; i < path.length; i++) {
    if (cum[i] >= half) {
      final segLen = cum[i] - cum[i - 1];
      final t = segLen == 0 ? 0.0 : (half - cum[i - 1]) / segLen;
      final a = path[i - 1], b = path[i];
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    }
  }
  return path.last;
}

// ─────────────────────────── Slippy-tile math ────────────────────────────
// Standard Web-Mercator tile indexing, used by the offline corridor downloader
// to enumerate which {z}/{x}/{y} tiles to fetch.

int lonToTileX(double lon, int z) {
  final n = 1 << z;
  final x = ((lon + 180.0) / 360.0 * n).floor();
  return x.clamp(0, n - 1);
}

int latToTileY(double lat, int z) {
  final n = 1 << z;
  final r = _deg2rad(lat.clamp(-85.05112878, 85.05112878));
  final y = ((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) /
          2.0 *
          n)
      .floor();
  return y.clamp(0, n - 1);
}

/// Approximate metres-per-pixel at the given latitude and zoom (256px tiles).
double metersPerPixel(double lat, int z) {
  return 156543.03392 * math.cos(_deg2rad(lat)) / (1 << z);
}
