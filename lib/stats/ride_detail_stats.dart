import 'dart:math' as math;

import '../models/ride_point.dart';
import 'ride_stats.dart';

/// One sample of the speed-over-time chart.
class SpeedSample {
  const SpeedSample({required this.elapsedSec, required this.kmh});
  final double elapsedSec;
  final double kmh;
}

/// One sample of the elevation-over-distance chart.
class ElevationSample {
  const ElevationSample({required this.distanceKm, required this.altitudeM});
  final double distanceKm;
  final double altitudeM;
}

/// Share of moving time spent inside a speed band.
class SpeedBand {
  const SpeedBand({required this.label, required this.fraction});
  final String label;
  final double fraction;
}

/// Extended per-ride stats, computed on demand from the raw points for the
/// detail screen. Nothing here is persisted — the six headline numbers on the
/// ride row stay the single cached source for list views.
class RideDetailStats {
  const RideDetailStats({
    required this.speedSeries,
    required this.elevationSeries,
    required this.minAltitudeM,
    required this.maxAltitudeM,
    required this.stopsCount,
    required this.longestStop,
    required this.fastestKmKmh,
    required this.maxLeanLeftDeg,
    required this.maxLeanRightDeg,
    required this.speedBands,
  });

  /// Median-smoothed speed trace, downsampled for charting.
  final List<SpeedSample> speedSeries;

  /// Smoothed altitude over cumulative distance, downsampled for charting.
  final List<ElevationSample> elevationSeries;

  final double? minAltitudeM;
  final double? maxAltitudeM;

  /// Standstills of >= 20 s (lights, photo stops, manual pauses).
  final int stopsCount;
  final Duration longestStop;

  /// Average speed over the fastest rolling kilometre, null if ride < 1 km.
  final double? fastestKmKmh;

  /// Estimated maximum lean angle (degrees) the bike had to hold turning left
  /// / right, from the steady-state identity θ = atan(v·ω / g) over GPS speed
  /// and heading-rate. Independent of where the phone sits; it's the lean the
  /// physics required, not a gyro reading. Null when there's too little data.
  final double? maxLeanLeftDeg;
  final double? maxLeanRightDeg;

  /// Moving-time distribution across speed bands. Fractions sum to ~1.
  final List<SpeedBand> speedBands;
}

/// Minimum standstill length that counts as a "stop".
const _stopMinDuration = Duration(seconds: 20);

/// Below this speed (km/h) GPS heading is jitter spin, not steering, so it is
/// excluded from the lean estimate.
const _leanMinKmh = 15.0;

/// Chart series are capped at this many samples to keep fl_chart snappy on
/// multi-hour rides (7000+ raw points).
const _maxChartSamples = 300;

const _bandEdges = [50.0, 80.0, 100.0];
const _bandLabels = ['< 50', '50–80', '80–100', '> 100'];

RideDetailStats computeDetailStats(List<RidePoint> rawPoints) {
  final points = cleanRideTrack(rawPoints);
  if (points.length < 2) {
    return const RideDetailStats(
      speedSeries: [],
      elevationSeries: [],
      minAltitudeM: null,
      maxAltitudeM: null,
      stopsCount: 0,
      longestStop: Duration.zero,
      fastestKmKmh: null,
      maxLeanLeftDeg: null,
      maxLeanRightDeg: null,
      speedBands: [],
    );
  }

  final speeds = medianFilteredSpeeds(effectiveSpeedsKmh(points), window: 3);
  final t0 = points.first.ts;

  // Cumulative distance per point (gap/glitch segments contribute 0, matching
  // computeStats' distance rules).
  final cumKm = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final dtSec = b.ts.difference(a.ts).inMilliseconds / 1000.0;
    var meters = 0.0;
    if (dtSec > 0 && dtSec <= 10) {
      final m = haversineMeters(a.lat, a.lon, b.lat, b.lon);
      final kmh = m / dtSec * 3.6;
      if (kmh >= movingThresholdKmh && kmh <= 250) meters = m;
    }
    cumKm[i] = cumKm[i - 1] + meters / 1000.0;
  }

  // ── Speed chart series ──
  final speedSeries = <SpeedSample>[];
  final stride = math.max(1, points.length ~/ _maxChartSamples);
  for (var i = 0; i < points.length; i += stride) {
    final v = speeds[i];
    if (v == null) continue;
    speedSeries.add(SpeedSample(
      elapsedSec: points[i].ts.difference(t0).inMilliseconds / 1000.0,
      kmh: v,
    ));
  }

  // ── Elevation profile ──
  final alts = smoothedAltitudes(points);
  var elevationSeries = <ElevationSample>[];
  double? minAlt;
  double? maxAlt;
  for (var i = 0; i < points.length; i++) {
    final a = alts[i];
    if (a == null) continue;
    if (minAlt == null || a < minAlt) minAlt = a;
    if (maxAlt == null || a > maxAlt) maxAlt = a;
    if (i % stride == 0) {
      elevationSeries.add(ElevationSample(distanceKm: cumKm[i], altitudeM: a));
    }
  }
  // No altitude variation = receiver never delivered altitude (constant 0 on
  // emulators / some devices). Suppress the profile instead of charting a
  // flat, meaningless line.
  if (minAlt != null && maxAlt != null && maxAlt - minAlt < 1.0) {
    elevationSeries = const [];
    minAlt = null;
    maxAlt = null;
  }

  // ── Stops ──
  var stopsCount = 0;
  var longestStop = Duration.zero;
  DateTime? stopStart;
  for (var i = 0; i < points.length; i++) {
    final moving = (speeds[i] ?? 0) >= movingThresholdKmh;
    if (!moving) {
      stopStart ??= points[i].ts;
    }
    final isLast = i == points.length - 1;
    if ((moving || isLast) && stopStart != null) {
      final end = moving ? points[i].ts : points.last.ts;
      final d = end.difference(stopStart);
      if (d >= _stopMinDuration) {
        stopsCount++;
        if (d > longestStop) longestStop = d;
      }
      stopStart = null;
    }
  }

  // ── Fastest rolling kilometre (two-pointer over cumulative distance) ──
  double? fastestKmKmh;
  var lo = 0;
  for (var hi = 1; hi < points.length; hi++) {
    // Shrink the window from the left while it still covers >= 1 km, so each
    // `hi` is paired with the tightest qualifying start point.
    while (lo + 1 < hi && cumKm[hi] - cumKm[lo + 1] >= 1.0) {
      lo++;
    }
    final dist = cumKm[hi] - cumKm[lo];
    if (dist >= 1.0) {
      final sec = points[hi].ts.difference(points[lo].ts).inMilliseconds / 1000.0;
      if (sec > 0) {
        final kmh = dist / (sec / 3600.0);
        if (kmh <= 250 && (fastestKmKmh == null || kmh > fastestKmKmh)) {
          fastestKmKmh = kmh;
        }
      }
    }
  }

  // ── Max lean angle (estimated from GPS) ──
  // A bike must lean θ = atan(v·ω / g) to balance a corner taken at speed v
  // with yaw rate ω. We read ω from the change in GPS heading between
  // consecutive segments, gate out low speed (heading is jitter there),
  // median-smooth to drop single-fix spikes, and keep the largest lean seen
  // turning each way. It's the lean the bike *had* to do, not a gyro reading.
  const g = 9.80665;
  const maxPlausibleLeanDeg = 60.0;

  // Signed yaw rate per boundary (deg/s, + = right / clockwise) with its speed.
  final yawRate = List<double?>.filled(points.length, null);
  final yawSpeedMs = List<double?>.filled(points.length, null);
  double? prevBearing;
  DateTime? prevBearingTs;
  for (var i = 1; i < points.length; i++) {
    final v = speeds[i];
    if (v == null || v < _leanMinKmh) {
      prevBearing = null;
      prevBearingTs = null;
      continue;
    }
    final a = points[i - 1];
    final b = points[i];
    final dtSec = b.ts.difference(a.ts).inMilliseconds / 1000.0;
    if (dtSec <= 0 || dtSec > 10) {
      prevBearing = null;
      prevBearingTs = null;
      continue;
    }
    final bearing = _bearingDeg(a.lat, a.lon, b.lat, b.lon);
    if (prevBearing != null && prevBearingTs != null) {
      final rateDt = b.ts.difference(prevBearingTs).inMilliseconds / 1000.0;
      if (rateDt >= 0.5 && rateDt <= 10) {
        var delta = bearing - prevBearing;
        delta = (delta + 540) % 360 - 180; // normalize to (-180, 180]
        yawRate[i] = delta / rateDt; // deg/s, signed (+right / -left)
        yawSpeedMs[i] = v / 3.6;
      }
    }
    prevBearing = bearing;
    prevBearingTs = b.ts;
  }

  double? leftMax;
  double? rightMax;
  var leanSamples = 0;
  for (var i = 0; i < points.length; i++) {
    final r = yawRate[i];
    final vMs = yawSpeedMs[i];
    if (r == null || vMs == null) continue;
    // 3-wide median of the signed yaw rate: kills isolated GPS spikes while
    // preserving a sustained corner.
    final window = <double>[
      if (i - 1 >= 0 && yawRate[i - 1] != null) yawRate[i - 1]!,
      r,
      if (i + 1 < points.length && yawRate[i + 1] != null) yawRate[i + 1]!,
    ]..sort();
    final smoothed = window[window.length ~/ 2];
    final omegaRad = smoothed.abs() * math.pi / 180.0;
    final leanDeg =
        math.min(math.atan(vMs * omegaRad / g) * 180.0 / math.pi, maxPlausibleLeanDeg);
    leanSamples++;
    if (smoothed > 0) {
      if (rightMax == null || leanDeg > rightMax) rightMax = leanDeg;
    } else if (smoothed < 0) {
      if (leftMax == null || leanDeg > leftMax) leftMax = leanDeg;
    }
  }
  final totalKm = cumKm.last;
  final enoughLeanData = leanSamples >= 30 && totalKm >= 1.0;
  final maxLeanLeftDeg = enoughLeanData ? (leftMax ?? 0.0) : null;
  final maxLeanRightDeg = enoughLeanData ? (rightMax ?? 0.0) : null;

  // ── Speed bands (share of moving time) ──
  final bandMs = List<double>.filled(_bandEdges.length + 1, 0);
  double movingMs = 0;
  for (var i = 1; i < points.length; i++) {
    final v = speeds[i];
    if (v == null || v < movingThresholdKmh) continue;
    final dtMs =
        points[i].ts.difference(points[i - 1].ts).inMilliseconds.toDouble();
    if (dtMs <= 0 || dtMs > 10000) continue;
    var band = _bandEdges.length;
    for (var e = 0; e < _bandEdges.length; e++) {
      if (v < _bandEdges[e]) {
        band = e;
        break;
      }
    }
    bandMs[band] += dtMs;
    movingMs += dtMs;
  }
  final speedBands = movingMs <= 0
      ? const <SpeedBand>[]
      : [
          for (var i = 0; i < bandMs.length; i++)
            SpeedBand(label: _bandLabels[i], fraction: bandMs[i] / movingMs),
        ];

  return RideDetailStats(
    speedSeries: speedSeries,
    elevationSeries: elevationSeries,
    minAltitudeM: minAlt,
    maxAltitudeM: maxAlt,
    stopsCount: stopsCount,
    longestStop: longestStop,
    fastestKmKmh: fastestKmKmh,
    maxLeanLeftDeg: maxLeanLeftDeg,
    maxLeanRightDeg: maxLeanRightDeg,
    speedBands: speedBands,
  );
}

double _bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = lat1 * math.pi / 180;
  final phi2 = lat2 * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final y = math.sin(dLon) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
  final deg = math.atan2(y, x) * 180 / math.pi;
  return (deg + 360) % 360;
}
