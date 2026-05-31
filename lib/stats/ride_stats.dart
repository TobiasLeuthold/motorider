import 'dart:math' as math;

import '../models/ride_point.dart';

/// Aggregated stats computed from a ride's GPS trace.
class RideStats {
  const RideStats({
    required this.distanceKm,
    required this.totalDuration,
    required this.movingDuration,
    required this.maxSpeedKmh,
    required this.avgMovingSpeedKmh,
    required this.elevationGainM,
  });

  final double distanceKm;
  final Duration totalDuration;
  final Duration movingDuration;
  final double maxSpeedKmh;
  final double avgMovingSpeedKmh;
  final double? elevationGainM;

  static const empty = RideStats(
    distanceKm: 0,
    totalDuration: Duration.zero,
    movingDuration: Duration.zero,
    maxSpeedKmh: 0,
    avgMovingSpeedKmh: 0,
    elevationGainM: null,
  );
}

/// Speeds below this threshold (km/h) don't count toward moving duration or
/// distance — handles GPS jitter when stationary at a Tankstelle / red light.
const _movingThresholdKmh = 3.0;

/// Smoothing window for the elevation calculation (samples). GPS altitude is
/// noisy, ±5-15 m is common; without smoothing the "gain" balloons to absurd
/// values from random walk noise.
const _elevationSmoothingWindow = 7;

double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthR = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthR * c;
}

/// Compute aggregate stats for a finished or in-progress ride.
///
/// Algorithm (per-segment between consecutive points):
///   1. distance = haversine(p1, p2) when speed >= threshold; otherwise skip
///      (counts as stationary).
///   2. movingDuration accumulates the segment's wall-clock delta only when
///      speed >= threshold.
///   3. maxSpeedKmh = max of (haversine/dt) across segments — using the
///      computed speed rather than the GPS-reported speed because the latter
///      can spike on cold-fixes.
///   4. elevationGain sums positive altitude deltas in a moving-average
///      smoothed series.
RideStats computeStats(List<RidePoint> points) {
  if (points.length < 2) {
    return RideStats(
      distanceKm: 0,
      totalDuration: points.length < 2
          ? Duration.zero
          : points.last.ts.difference(points.first.ts),
      movingDuration: Duration.zero,
      maxSpeedKmh: 0,
      avgMovingSpeedKmh: 0,
      elevationGainM: null,
    );
  }

  double totalMeters = 0;
  Duration movingDuration = Duration.zero;
  double maxKmh = 0;

  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final dt = b.ts.difference(a.ts);
    final dtSec = dt.inMilliseconds / 1000.0;
    if (dtSec <= 0) continue;

    final meters = _haversineMeters(a.lat, a.lon, b.lat, b.lon);
    final kmh = (meters / dtSec) * 3.6;

    if (kmh >= _movingThresholdKmh) {
      totalMeters += meters;
      movingDuration += dt;
      if (kmh > maxKmh) maxKmh = kmh;
    }
  }

  final total = points.last.ts.difference(points.first.ts);
  final movingHours = movingDuration.inMilliseconds / 3_600_000.0;
  final avgKmh = movingHours > 0 ? (totalMeters / 1000.0) / movingHours : 0.0;

  return RideStats(
    distanceKm: totalMeters / 1000.0,
    totalDuration: total,
    movingDuration: movingDuration,
    maxSpeedKmh: maxKmh,
    avgMovingSpeedKmh: avgKmh,
    elevationGainM: _elevationGain(points),
  );
}

double? _elevationGain(List<RidePoint> points) {
  final alts = [
    for (final p in points)
      if (p.altitudeM != null) p.altitudeM!,
  ];
  if (alts.length < _elevationSmoothingWindow * 2) return null;

  // Moving-average smoothing.
  final smoothed = <double>[];
  for (var i = 0; i < alts.length; i++) {
    final lo = math.max(0, i - _elevationSmoothingWindow ~/ 2);
    final hi = math.min(alts.length - 1, i + _elevationSmoothingWindow ~/ 2);
    var sum = 0.0;
    for (var j = lo; j <= hi; j++) {
      sum += alts[j];
    }
    smoothed.add(sum / (hi - lo + 1));
  }

  var gain = 0.0;
  for (var i = 1; i < smoothed.length; i++) {
    final dz = smoothed[i] - smoothed[i - 1];
    if (dz > 0) gain += dz;
  }
  return gain;
}
