import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/models/ride_point.dart';
import 'package:motorider/stats/ride_track_color.dart';

/// Build a point with a Doppler speed (m/s) so [downsampleTrack] picks it up
/// directly without leaning on the haversine fallback.
RidePoint pt(int seq, double lat, double lon, {double? speedMs}) => RidePoint(
      rideId: 'r',
      sequence: seq,
      ts: DateTime(2026, 1, 1).add(Duration(seconds: seq)),
      lat: lat,
      lon: lon,
      speedMs: speedMs,
    );

void main() {
  group('colorOnScale', () {
    test('endpoints and midpoint hit the scale anchors', () {
      expect(colorOnScale(0), scaleLow);
      expect(colorOnScale(1), scaleHigh);
      expect(colorOnScale(0.5), scaleMid);
    });

    test('clamps out-of-range input instead of extrapolating', () {
      expect(colorOnScale(-5), scaleLow);
      expect(colorOnScale(5), scaleHigh);
    });

    test('is monotonic-ish: low half greener, high half redder', () {
      final lo = colorOnScale(0.25);
      final hi = colorOnScale(0.75);
      // Lower t keeps more green, higher t more red.
      expect(lo.g, greaterThan(hi.g));
      expect(hi.r, greaterThanOrEqualTo(lo.r));
    });
  });

  group('RideColorMode', () {
    test('labels are the German UI strings', () {
      expect(RideColorMode.uniform.label, 'Einfarbig');
      expect(RideColorMode.avgSpeed.label, 'Ø Tempo');
      expect(RideColorMode.maxSpeed.label, 'Max Tempo');
      expect(RideColorMode.distance.label, 'Distanz');
      expect(RideColorMode.speedHeatmap.label, 'Tempo-Verlauf');
    });

    test('metric maps the three uniform modes, null for the rest', () {
      expect(RideColorMode.avgSpeed.metric, RideColorMetric.avgSpeed);
      expect(RideColorMode.maxSpeed.metric, RideColorMetric.maxSpeed);
      expect(RideColorMode.distance.metric, RideColorMetric.distance);
      expect(RideColorMode.uniform.metric, isNull);
      expect(RideColorMode.speedHeatmap.metric, isNull);
    });

    test('only the heatmap mode is per-segment', () {
      expect(RideColorMode.speedHeatmap.isPerSegment, isTrue);
      for (final m in RideColorMode.values.where((m) => m != RideColorMode.speedHeatmap)) {
        expect(m.isPerSegment, isFalse, reason: '$m');
      }
    });
  });

  group('downsampleTrack', () {
    test('empty trace → empty track', () {
      expect(downsampleTrack(const []), isEmpty);
    });

    test('single point is kept (as the last point) with its speed', () {
      final track = downsampleTrack([pt(0, 46.0, 8.0, speedMs: 10)]);
      expect(track.length, 1);
      expect(track.first.pt, const LatLng(46.0, 8.0));
      expect(track.first.speedKmh, closeTo(36, 0.001)); // 10 m/s = 36 km/h
    });

    test('keeps every point when under target, preserving Doppler speed', () {
      final raw = [
        pt(0, 46.0, 8.0, speedMs: 5), // first point: no fallback estimate
        pt(1, 46.001, 8.0, speedMs: 10),
        pt(2, 46.002, 8.0, speedMs: 20),
      ];
      final track = downsampleTrack(raw, target: 400);
      expect(track.length, 3);
      // Doppler is trusted outright when it reports movement (>= 2 km/h).
      expect(track[1].speedKmh, closeTo(36, 0.001));
      expect(track[2].speedKmh, closeTo(72, 0.001));
    });

    test('decimates toward the target but always keeps the last point', () {
      final raw = [
        for (var i = 0; i < 1000; i++)
          pt(i, 46.0 + i * 0.0001, 8.0, speedMs: 10),
      ];
      final track = downsampleTrack(raw, target: 400);
      // ~400 evenly strided points, plus possibly the appended last one.
      expect(track.length, lessThanOrEqualTo(401));
      expect(track.length, greaterThan(300));
      final last = raw.last;
      expect(track.last.pt.latitude, closeTo(last.lat, 1e-9));
      expect(track.last.pt.longitude, closeTo(last.lon, 1e-9));
    });

    test('null Doppler with no movement yields a null speed at the first point',
        () {
      final raw = [pt(0, 46.0, 8.0), pt(1, 46.0, 8.0)];
      final track = downsampleTrack(raw);
      // First point can never have a derived speed.
      expect(track.first.speedKmh, isNull);
    });
  });

  group('heatmapSpeedRange', () {
    LatLng p(double lat) => LatLng(lat, 8.0);
    TrackPoint tp(double lat, double? kmh) => TrackPoint(p(lat), kmh);

    test('no tracks → degenerate range, normalises mid-scale', () {
      final r = heatmapSpeedRange(const []);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(123), 0.5);
    });

    test('all-null speeds → degenerate range (no divide-by-zero)', () {
      final track = [tp(46.0, null), tp(46.1, null), tp(46.2, null)];
      final r = heatmapSpeedRange([track]);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(50), 0.5);
    });

    test('spans segment end-speeds across all tracks, ignoring point 0', () {
      // Point 0's speed is ignored (no segment ends there).
      final a = [tp(46.0, 999), tp(46.1, 20), tp(46.2, 60)];
      final b = [tp(47.0, 10), tp(47.1, 80)];
      final r = heatmapSpeedRange([a, b]);
      expect(r.min, 20); // 999 at index 0 excluded; min segment-end is 20
      expect(r.max, 80);
      expect(r.hasSpread, isTrue);
    });

    test('single segment → no spread (one value), paints mid-scale', () {
      final a = [tp(46.0, 0), tp(46.1, 50)];
      final r = heatmapSpeedRange([a]);
      expect(r.min, 50);
      expect(r.max, 50);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(50), 0.5);
    });
  });

  group('segmentSpeedColors', () {
    LatLng p(double lat) => LatLng(lat, 8.0);
    TrackPoint tp(double lat, double? kmh) => TrackPoint(p(lat), kmh);

    test('fewer than two points → no segments', () {
      expect(segmentSpeedColors(const [], const MetricRange(0, 100)), isEmpty);
      expect(segmentSpeedColors([tp(46, 10)], const MetricRange(0, 100)),
          isEmpty);
    });

    test('one colour per segment (length = points - 1)', () {
      final track = [tp(46.0, 0), tp(46.1, 50), tp(46.2, 100)];
      final colors = segmentSpeedColors(track, const MetricRange(0, 100));
      expect(colors.length, 2);
    });

    test('endpoints map to scale ends, middle to amber', () {
      final track = [tp(46.0, 0), tp(46.1, 0), tp(46.2, 50), tp(46.3, 100)];
      final colors = segmentSpeedColors(track, const MetricRange(0, 100));
      // seg1 ends at 0 → green; seg2 ends at 50 → amber; seg3 ends at 100 → red.
      expect(colors[0], scaleLow);
      expect(colors[1], scaleMid);
      expect(colors[2], scaleHigh);
    });

    test('unknown segment speed falls back to mid-scale (amber)', () {
      final track = [tp(46.0, 10), tp(46.1, null)];
      final colors = segmentSpeedColors(track, const MetricRange(0, 100));
      expect(colors.single, scaleMid);
    });

    test('no spread in the range → every segment mid-scale', () {
      final track = [tp(46.0, 42), tp(46.1, 42), tp(46.2, 42)];
      // Degenerate range (min == max): normalize always returns 0.5.
      final colors = segmentSpeedColors(track, const MetricRange(42, 42));
      expect(colors, everyElement(scaleMid));
    });
  });

  group('metricRange reuse (uniform modes share ride_filter logic)', () {
    test('single ride → no spread, normalises mid-scale (no divide-by-zero)',
        () {
      const r = MetricRange(55, 55);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(55), 0.5);
      expect(colorOnScale(r.normalize(55)), scaleMid);
    });

    test('endpoints across a set map to scale ends', () {
      const r = MetricRange(40, 70);
      expect(colorOnScale(r.normalize(40)), scaleLow);
      expect(colorOnScale(r.normalize(70)), scaleHigh);
      expect(colorOnScale(r.normalize(55)), scaleMid);
    });
  });
}
