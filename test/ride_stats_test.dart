import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/models/ride_point.dart';
import 'package:motorider/stats/ride_detail_stats.dart';
import 'package:motorider/stats/ride_stats.dart';

/// ~1 degree of latitude in meters.
const _mPerDegLat = 111320.0;

/// Build a 1 Hz trace heading due north at [kmhProfile]\[i\] km/h for second i.
/// [dopplerSpeeds] toggles whether points carry the (accurate) Doppler speed.
/// [noiseAt] displaces single points sideways by [noiseM] meters — simulating
/// GPS position noise that does NOT reflect real movement.
List<RidePoint> trace(
  List<double> kmhProfile, {
  bool dopplerSpeeds = true,
  Map<int, double> noiseAt = const {},
  double? altitudeBase,
}) {
  final start = DateTime.utc(2026, 6, 1, 10);
  final points = <RidePoint>[];
  var lat = 47.0;
  for (var i = 0; i < kmhProfile.length; i++) {
    final ms = kmhProfile[i] / 3.6;
    if (i > 0) lat += ms / _mPerDegLat;
    final noise = noiseAt[i] ?? 0;
    points.add(RidePoint(
      rideId: 'r',
      sequence: i,
      ts: start.add(Duration(seconds: i)),
      lat: lat,
      // Sideways (longitude) displacement ≈ noise meters at lat 47.
      lon: 8.0 + noise / (_mPerDegLat * math.cos(47 * math.pi / 180)),
      speedMs: dopplerSpeeds ? ms : null,
      accuracyM: 5,
      altitudeM: altitudeBase == null ? null : altitudeBase + i * 0.5,
    ));
  }
  return points;
}

/// Build a constant-speed trace along a circular arc of [radiusM] at
/// [speedKmh], turning right (clockwise) when [rightTurn], else left. Steady
/// state means the lean estimate should converge to atan(v^2 / (r·g)).
List<RidePoint> arcTrace({
  required double speedKmh,
  required double radiusM,
  required int seconds,
  required bool rightTurn,
}) {
  final v = speedKmh / 3.6;
  final dPsi = (v / radiusM) * (rightTurn ? 1.0 : -1.0); // rad/s, + = clockwise
  final start = DateTime.utc(2026, 6, 1, 10);
  const lat0 = 47.0, lon0 = 8.0;
  final mPerDegLon = _mPerDegLat * math.cos(lat0 * math.pi / 180);
  final points = <RidePoint>[];
  var x = 0.0, y = 0.0, psi = 0.0; // psi: compass heading (rad), 0 = north
  for (var i = 0; i < seconds; i++) {
    points.add(RidePoint(
      rideId: 'r',
      sequence: i,
      ts: start.add(Duration(seconds: i)),
      lat: lat0 + y / _mPerDegLat,
      lon: lon0 + x / mPerDegLon,
      speedMs: v,
      accuracyM: 5,
    ));
    x += v * math.sin(psi); // east
    y += v * math.cos(psi); // north
    psi += dPsi;
  }
  return points;
}

void main() {
  group('computeStats max speed', () {
    test('clean constant 100 km/h ride reports ~100', () {
      final stats = computeStats(trace(List.filled(120, 100.0)));
      expect(stats.maxSpeedKmh, closeTo(100, 2));
    });

    test('position-noise spike does not double max speed (Doppler present)',
        () {
      // 8 m sideways displacement on one fix => haversine speed jumps to
      // ~129 km/h for that segment while the bike really does 100.
      final stats = computeStats(
        trace(List.filled(120, 100.0), noiseAt: {60: 8.0}),
      );
      expect(stats.maxSpeedKmh, closeTo(100, 3));
    });

    test('position-noise spike is median-filtered out without Doppler', () {
      final stats = computeStats(
        trace(
          List.filled(120, 100.0),
          dopplerSpeeds: false,
          noiseAt: {60: 10.0},
        ),
      );
      // Without Doppler the computed series carries the spike, but the
      // median filter must keep it from becoming the ride max.
      expect(stats.maxSpeedKmh, lessThan(112));
      expect(stats.maxSpeedKmh, closeTo(100, 12));
    });

    test('zero-stuck Doppler falls back to positional speed', () {
      final pts = [
        for (final p in trace(List.filled(60, 80.0), dopplerSpeeds: false))
          RidePoint(
            rideId: p.rideId,
            sequence: p.sequence,
            ts: p.ts,
            lat: p.lat,
            lon: p.lon,
            speedMs: 0, // chip reports standstill although we move
            accuracyM: p.accuracyM,
          ),
      ];
      final stats = computeStats(pts);
      expect(stats.maxSpeedKmh, closeTo(80, 3));
    });

    test('stationary jitter yields ~zero distance and max', () {
      final stats = computeStats(
        trace(List.filled(60, 0.0), noiseAt: {10: 2.0, 30: 3.0, 45: 2.5}),
      );
      expect(stats.distanceKm, lessThan(0.05));
      expect(stats.maxSpeedKmh, lessThan(movingThresholdKmh + 9));
      expect(stats.movingDuration.inSeconds, lessThan(10));
    });

    test('avg speed and distance stay plausible', () {
      final stats = computeStats(trace(List.filled(361, 90.0)));
      expect(stats.distanceKm, closeTo(9.0, 0.2));
      expect(stats.avgMovingSpeedKmh, closeTo(90, 2));
      expect(stats.totalDuration.inSeconds, 360);
    });
  });

  group('cleanRideTrack', () {
    test('a clean trace is returned unchanged', () {
      final pts = trace(List.filled(60, 90.0));
      expect(cleanRideTrack(pts).length, pts.length);
    });

    test('drops a teleport-out-and-back spike', () {
      // One fix flung 120 m sideways and back: a classic multipath jump.
      final pts = trace(List.filled(60, 100.0), noiseAt: {30: 120.0});
      final cleaned = cleanRideTrack(pts);
      expect(cleaned.length, pts.length - 1);
      // The offending sequence (30) is the one removed.
      expect(cleaned.any((p) => p.sequence == 30), isFalse);
    });

    test('drops fixes the receiver itself flags as inaccurate', () {
      final base = trace(List.filled(40, 80.0));
      final pts = [
        for (final p in base)
          if (p.sequence == 20)
            RidePoint(
              rideId: p.rideId,
              sequence: p.sequence,
              ts: p.ts,
              lat: p.lat,
              lon: p.lon,
              speedMs: p.speedMs,
              accuracyM: 80, // > _maxTrustedAccuracyM
            )
          else
            p,
      ];
      final cleaned = cleanRideTrack(pts);
      expect(cleaned.any((p) => p.sequence == 20), isFalse);
      expect(cleaned.length, pts.length - 1);
    });

    test('keeps a genuine sharp corner (big detour, but sane speed)', () {
      // A real hairpin has a large turn angle yet a believable speed, so the
      // spike gate must not eat it.
      final pts =
          arcTrace(speedKmh: 30, radiusM: 12, seconds: 60, rightTurn: true);
      expect(cleanRideTrack(pts).length, pts.length);
    });

    test('a sub-250 km/h jump no longer inflates distance', () {
      // 50 m sideways on a slow (30 km/h) trace implies ~182 km/h — under the
      // old 250 km/h cap, so it used to be counted into distance. The cleaner
      // removes it, bringing distance back in line with the spike-free trace.
      final clean = computeStats(trace(List.filled(60, 30.0))).distanceKm;
      final withSpike =
          computeStats(trace(List.filled(60, 30.0), noiseAt: {30: 50.0}))
              .distanceKm;
      expect(withSpike, closeTo(clean, 0.02));
    });
  });

  group('computeDetailStats', () {
    test('counts stops and measures the longest one', () {
      final profile = [
        ...List.filled(60, 60.0),
        ...List.filled(40, 0.0), // 40 s stop
        ...List.filled(60, 60.0),
        ...List.filled(10, 0.0), // 10 s — below the 20 s stop threshold
        ...List.filled(30, 60.0),
      ];
      final d = computeDetailStats(trace(profile));
      expect(d.stopsCount, 1);
      expect(d.longestStop.inSeconds, closeTo(40, 3));
    });

    test('fastest km reflects the fast section', () {
      final profile = [
        ...List.filled(120, 60.0), // 2 km warmup
        ...List.filled(60, 110.0), // ~1.8 km fast
        ...List.filled(120, 60.0),
      ];
      final d = computeDetailStats(trace(profile));
      expect(d.fastestKmKmh, isNotNull);
      expect(d.fastestKmKmh!, greaterThan(95));
      expect(d.fastestKmKmh!, lessThanOrEqualTo(112));
    });

    test('straight ride has near-zero lean both sides', () {
      final d = computeDetailStats(trace(List.filled(240, 80.0)));
      expect(d.maxLeanLeftDeg, isNotNull);
      expect(d.maxLeanRightDeg, isNotNull);
      expect(d.maxLeanLeftDeg!, lessThan(5));
      expect(d.maxLeanRightDeg!, lessThan(5));
    });

    test('steady right-hand corner leans right by ~atan(v^2/rg)', () {
      // 72 km/h (20 m/s) around a 100 m circle -> ~22.2° of lean to the right.
      final d = computeDetailStats(
        arcTrace(speedKmh: 72, radiusM: 100, seconds: 120, rightTurn: true),
      );
      final expected =
          math.atan(400.0 / (100 * 9.80665)) * 180 / math.pi; // ~22.2°
      expect(d.maxLeanRightDeg, isNotNull);
      expect(d.maxLeanRightDeg!, closeTo(expected, 3));
      expect(d.maxLeanLeftDeg!, lessThan(5)); // essentially no left lean
    });

    test('left-hand corner leans left, not right', () {
      final d = computeDetailStats(
        arcTrace(speedKmh: 72, radiusM: 100, seconds: 120, rightTurn: false),
      );
      final expected = math.atan(400.0 / (100 * 9.80665)) * 180 / math.pi;
      expect(d.maxLeanLeftDeg!, closeTo(expected, 3));
      expect(d.maxLeanRightDeg!, lessThan(5));
    });

    test('speed bands cover the moving time', () {
      final profile = [
        ...List.filled(100, 40.0),
        ...List.filled(100, 70.0),
        ...List.filled(100, 110.0),
      ];
      final d = computeDetailStats(trace(profile));
      expect(d.speedBands, isNotEmpty);
      final sum = d.speedBands.fold<double>(0, (s, b) => s + b.fraction);
      expect(sum, closeTo(1.0, 0.01));
      // One third in each of <50, 50–80, >100.
      expect(d.speedBands[0].fraction, closeTo(0.33, 0.05));
      expect(d.speedBands[1].fraction, closeTo(0.33, 0.05));
      expect(d.speedBands[3].fraction, closeTo(0.33, 0.05));
    });

    test('elevation series present when altitude data exists', () {
      final d = computeDetailStats(
        trace(List.filled(120, 60.0), altitudeBase: 450),
      );
      expect(d.elevationSeries.length, greaterThan(10));
      expect(d.minAltitudeM, isNotNull);
      expect(d.maxAltitudeM! > d.minAltitudeM!, isTrue);
    });
  });
}
