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
    this.lastSpeedKmh = 0,
  });

  final double distanceKm;
  final Duration totalDuration;
  final Duration movingDuration;
  final double maxSpeedKmh;
  final double avgMovingSpeedKmh;
  final double? elevationGainM;

  /// Best current-speed estimate for the live HUD. Not persisted on the ride
  /// row — only meaningful while tracking.
  final double lastSpeedKmh;

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
const movingThresholdKmh = 3.0;

/// Smoothing window for the elevation calculation (samples). GPS altitude is
/// noisy, ±5-15 m is common; without smoothing the "gain" balloons to absurd
/// values from random walk noise.
const _elevationSmoothingWindow = 7;

/// Position fixes worse than this don't produce a positional speed estimate —
/// a 50 m error circle over a 1 s segment is pure noise.
const _maxAccuracyForSpeedM = 30.0;

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
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

/// Per-point "effective" speed in km/h, index-aligned with [points].
///
/// Prefers the GPS chip's Doppler speed ([RidePoint.speedMs]) — it comes from
/// carrier frequency shift and is an order of magnitude more accurate than
/// position-delta math, which inherits the full lat/lon noise (±3–8 m per fix
/// → ±30–60 km/h of phantom speed over a 1 s segment). Falls back to
/// haversine/dt against the previous point when Doppler is missing or
/// zero-stuck (emulators, some devices).
///
/// Entries are null where no estimate exists (first point, gaps > 10 s,
/// fixes with accuracy worse than [_maxAccuracyForSpeedM]).
List<double?> effectiveSpeedsKmh(List<RidePoint> points) {
  final out = List<double?>.filled(points.length, null);
  for (var i = 0; i < points.length; i++) {
    final p = points[i];

    double? computed;
    if (i > 0) {
      final a = points[i - 1];
      final dtSec = p.ts.difference(a.ts).inMilliseconds / 1000.0;
      final badFix = (p.accuracyM ?? 0) > _maxAccuracyForSpeedM ||
          (a.accuracyM ?? 0) > _maxAccuracyForSpeedM;
      if (dtSec > 0 && dtSec <= 10 && !badFix) {
        final kmh =
            haversineMeters(a.lat, a.lon, p.lat, p.lon) / dtSec * 3.6;
        if (kmh <= 250) computed = kmh;
      }
    }

    final dopplerKmh = p.speedMs == null ? null : p.speedMs! * 3.6;
    if (dopplerKmh != null && dopplerKmh >= 2.0) {
      // Doppler reports movement — trust it outright.
      out[i] = dopplerKmh;
    } else if (dopplerKmh != null && (computed == null || computed < 10)) {
      // Doppler says standstill and position agrees within jitter range —
      // trust the standstill instead of letting jitter set a phantom speed.
      out[i] = dopplerKmh;
    } else {
      // Doppler missing or zero-stuck while the position clearly moves.
      out[i] = computed ?? dopplerKmh;
    }
  }
  return out;
}

/// Median filter over a nullable series. Kills single-sample (and with
/// window 5, double-sample) spikes that survive the Doppler preference —
/// e.g. cold-fix jumps where Doppler is missing for a moment.
List<double?> medianFilteredSpeeds(List<double?> xs, {int window = 5}) {
  final half = window ~/ 2;
  final out = List<double?>.filled(xs.length, null);
  for (var i = 0; i < xs.length; i++) {
    if (xs[i] == null) continue;
    final vals = <double>[];
    for (var j = math.max(0, i - half);
        j <= math.min(xs.length - 1, i + half);
        j++) {
      final v = xs[j];
      if (v != null) vals.add(v);
    }
    vals.sort();
    out[i] = vals[vals.length ~/ 2];
  }
  return out;
}

/// Compute aggregate stats for a finished or in-progress ride.
///
/// Algorithm:
///   1. distance / movingDuration accumulate per-segment (haversine, wall
///      clock) only while the segment speed is >= [movingThresholdKmh].
///   2. maxSpeedKmh = max of the median-filtered [effectiveSpeedsKmh] series.
///      Doppler-first + median filter is what keeps a single noisy fix from
///      doubling the recorded top speed.
///   3. elevationGain sums positive altitude deltas in a moving-average
///      smoothed series.
RideStats computeStats(List<RidePoint> points) {
  if (points.length < 2) {
    return RideStats.empty;
  }

  double totalMeters = 0;
  Duration movingDuration = Duration.zero;

  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final dt = b.ts.difference(a.ts);
    final dtSec = dt.inMilliseconds / 1000.0;
    if (dtSec <= 0) continue;

    // Drop segments that span a gap (manual pause / GPS dropout / app
    // backgrounded for too long). At 1 Hz sampling, anything > 10 s is
    // almost certainly a hole we shouldn't bridge with a straight-line
    // distance estimate.
    if (dtSec > 10) continue;

    final meters = haversineMeters(a.lat, a.lon, b.lat, b.lon);
    final kmh = (meters / dtSec) * 3.6;

    // Sanity cap — a single sample with implausible speed (>250 km/h on a
    // motorbike) is a GPS glitch, not signal.
    if (kmh > 250) continue;

    if (kmh >= movingThresholdKmh) {
      totalMeters += meters;
      movingDuration += dt;
    }
  }

  final effective = effectiveSpeedsKmh(points);
  final filtered = medianFilteredSpeeds(effective);
  var maxKmh = 0.0;
  for (final v in filtered) {
    if (v != null && v > maxKmh) maxKmh = v;
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
    lastSpeedKmh: effective.last ?? 0,
  );
}

/// Moving-average smoothed altitude series, index-aligned with [points].
/// Entries are null where the fix carries no altitude.
List<double?> smoothedAltitudes(List<RidePoint> points) {
  final alts = [for (final p in points) p.altitudeM];
  final out = List<double?>.filled(alts.length, null);
  for (var i = 0; i < alts.length; i++) {
    if (alts[i] == null) continue;
    final lo = math.max(0, i - _elevationSmoothingWindow ~/ 2);
    final hi = math.min(alts.length - 1, i + _elevationSmoothingWindow ~/ 2);
    var sum = 0.0;
    var n = 0;
    for (var j = lo; j <= hi; j++) {
      final a = alts[j];
      if (a != null) {
        sum += a;
        n++;
      }
    }
    out[i] = sum / n;
  }
  return out;
}

double? _elevationGain(List<RidePoint> points) {
  final smoothed =
      smoothedAltitudes(points).whereType<double>().toList(growable: false);
  if (smoothed.length < _elevationSmoothingWindow * 2) return null;

  var min = smoothed.first;
  var max = smoothed.first;
  var gain = 0.0;
  for (var i = 1; i < smoothed.length; i++) {
    final dz = smoothed[i] - smoothed[i - 1];
    if (dz > 0) gain += dz;
    if (smoothed[i] < min) min = smoothed[i];
    if (smoothed[i] > max) max = smoothed[i];
  }
  // A trace without ANY altitude variation means the receiver never delivered
  // altitude (constant 0 on emulators / some devices) — report "unknown"
  // rather than a misleading 0 m. Real GPS always varies by metres.
  if (max - min < 1.0) return null;
  return gain;
}
