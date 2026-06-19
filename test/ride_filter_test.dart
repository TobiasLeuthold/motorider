import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/models/ride.dart';
import 'package:motorider/stats/ride_filter.dart';

/// Build a ride with just the fields the filter/summary logic reads.
Ride ride({
  required String id,
  DateTime? startedAt,
  double distanceKm = 0,
  Duration total = Duration.zero,
  Duration moving = Duration.zero,
  double maxKmh = 0,
  double avgKmh = 0,
}) {
  return Ride(
    id: id,
    startedAt: startedAt ?? DateTime(2026, 1, 1),
    distanceKm: distanceKm,
    totalDuration: total,
    movingDuration: moving,
    maxSpeedKmh: maxKmh,
    avgMovingSpeedKmh: avgKmh,
  );
}

void main() {
  // A small fixture spanning a range of every metric and a year of dates.
  final sample = <Ride>[
    ride(
      id: 'a',
      startedAt: DateTime(2026, 1, 10),
      distanceKm: 12,
      total: const Duration(minutes: 30),
      moving: const Duration(minutes: 24),
      maxKmh: 90,
      avgKmh: 40,
    ),
    ride(
      id: 'b',
      startedAt: DateTime(2026, 3, 15),
      distanceKm: 80,
      total: const Duration(hours: 2),
      moving: const Duration(minutes: 100),
      maxKmh: 140,
      avgKmh: 70,
    ),
    ride(
      id: 'c',
      startedAt: DateTime(2026, 6, 1),
      distanceKm: 45,
      total: const Duration(hours: 1, minutes: 30),
      moving: const Duration(minutes: 70),
      maxKmh: 110,
      avgKmh: 55,
    ),
  ];

  group('RideFilter.matches — each dimension', () {
    test('distance lower bound', () {
      const f = RideFilter(minDistanceKm: 40);
      expect(sample.where(f.matches).map((r) => r.id), ['b', 'c']);
    });

    test('distance upper bound', () {
      const f = RideFilter(maxDistanceKm: 50);
      expect(sample.where(f.matches).map((r) => r.id), ['a', 'c']);
    });

    test('distance band (both bounds)', () {
      const f = RideFilter(minDistanceKm: 20, maxDistanceKm: 60);
      expect(sample.where(f.matches).map((r) => r.id), ['c']);
    });

    test('avg speed bounds', () {
      const f = RideFilter(minAvgSpeedKmh: 50, maxAvgSpeedKmh: 60);
      expect(sample.where(f.matches).map((r) => r.id), ['c']);
    });

    test('max speed lower bound', () {
      const f = RideFilter(minMaxSpeedKmh: 100);
      expect(sample.where(f.matches).map((r) => r.id), ['b', 'c']);
    });

    test('duration lower bound', () {
      const f = RideFilter(minDuration: Duration(hours: 1));
      expect(sample.where(f.matches).map((r) => r.id), ['b', 'c']);
    });

    test('duration upper bound', () {
      const f = RideFilter(maxDuration: Duration(minutes: 45));
      expect(sample.where(f.matches).map((r) => r.id), ['a']);
    });

    test('date window from', () {
      final f = RideFilter(from: DateTime(2026, 2, 1));
      expect(sample.where(f.matches).map((r) => r.id), ['b', 'c']);
    });

    test('date window to', () {
      final f = RideFilter(to: DateTime(2026, 4, 1));
      expect(sample.where(f.matches).map((r) => r.id), ['a', 'b']);
    });

    test('date window from+to (inclusive bounds)', () {
      final f = RideFilter(
        from: DateTime(2026, 3, 15),
        to: DateTime(2026, 6, 1, 23, 59),
      );
      expect(sample.where(f.matches).map((r) => r.id), ['b', 'c']);
    });

    test('empty filter matches everything', () {
      expect(sample.where(RideFilter.none.matches).length, 3);
    });
  });

  group('RideFilter — combined constraints', () {
    test('distance + max speed + date together', () {
      final f = RideFilter(
        minDistanceKm: 40,
        minMaxSpeedKmh: 100,
        from: DateTime(2026, 4, 1),
      );
      // Only c is >=40 km, >=100 max, and after Apr 1.
      expect(applyRideFilter(sample, f).map((r) => r.id), ['c']);
    });

    test('combined filter matching nothing yields empty list', () {
      const f = RideFilter(minDistanceKm: 200);
      expect(applyRideFilter(sample, f), isEmpty);
    });
  });

  group('applyRideFilter — sort orders', () {
    test('newest (default) is startedAt descending', () {
      final r = applyRideFilter(sample, RideFilter.none);
      expect(r.map((e) => e.id), ['c', 'b', 'a']);
    });

    test('longest distance', () {
      final r = applyRideFilter(
          sample, const RideFilter(sort: RideSort.longestDistance));
      expect(r.map((e) => e.id), ['b', 'c', 'a']);
    });

    test('fastest avg speed', () {
      final r = applyRideFilter(
          sample, const RideFilter(sort: RideSort.fastestAvg));
      expect(r.map((e) => e.id), ['b', 'c', 'a']);
    });

    test('fastest max speed', () {
      final r = applyRideFilter(
          sample, const RideFilter(sort: RideSort.fastestMax));
      expect(r.map((e) => e.id), ['b', 'c', 'a']);
    });

    test('longest duration', () {
      final r = applyRideFilter(
          sample, const RideFilter(sort: RideSort.longestDuration));
      expect(r.map((e) => e.id), ['b', 'c', 'a']);
    });

    test('does not mutate the input list', () {
      final input = List<Ride>.from(sample);
      final before = input.map((e) => e.id).toList();
      applyRideFilter(input, const RideFilter(sort: RideSort.longestDistance));
      expect(input.map((e) => e.id).toList(), before);
    });

    test('equal-metric rides tie-break by newest', () {
      final ties = [
        ride(id: 'x', startedAt: DateTime(2026, 1, 1), distanceKm: 50),
        ride(id: 'y', startedAt: DateTime(2026, 5, 1), distanceKm: 50),
        ride(id: 'z', startedAt: DateTime(2026, 3, 1), distanceKm: 50),
      ];
      final r =
          applyRideFilter(ties, const RideFilter(sort: RideSort.longestDistance));
      expect(r.map((e) => e.id), ['y', 'z', 'x']);
    });
  });

  group('rideSummary', () {
    test('totals over the full set', () {
      final s = rideSummary(sample);
      expect(s.count, 3);
      expect(s.totalDistanceKm, closeTo(137, 0.001));
      expect(s.totalDuration, const Duration(hours: 4));
      expect(s.longestRideKm, 80);
      expect(s.topSpeedKmh, 140);
    });

    test('avg speed = total km over total moving hours', () {
      final s = rideSummary(sample);
      // moving = 24 + 100 + 70 = 194 min = 3.2333 h; 137 / 3.2333 ≈ 42.37
      expect(s.avgSpeedKmh, closeTo(137 / (194 / 60), 0.01));
    });

    test('reflects only the filtered subset', () {
      final filtered =
          applyRideFilter(sample, const RideFilter(minDistanceKm: 40));
      final s = rideSummary(filtered);
      expect(s.count, 2);
      expect(s.totalDistanceKm, closeTo(125, 0.001));
      expect(s.longestRideKm, 80);
      expect(s.topSpeedKmh, 140);
    });

    test('empty set yields the empty summary', () {
      final s = rideSummary(const []);
      expect(s.isEmpty, isTrue);
      expect(s.count, 0);
      expect(s.totalDistanceKm, 0);
      expect(s.topSpeedKmh, 0);
      expect(s.avgSpeedKmh, 0);
    });

    test('zero moving time does not divide by zero', () {
      final s = rideSummary([ride(id: 'q', distanceKm: 10)]);
      expect(s.avgSpeedKmh, 0);
    });
  });

  group('metricRange & normalize (colour cue)', () {
    test('range over avg speed', () {
      final r = metricRange(sample, RideColorMetric.avgSpeed);
      expect(r.min, 40);
      expect(r.max, 70);
      expect(r.hasSpread, isTrue);
    });

    test('normalize maps min→0, max→1, midpoint→0.5', () {
      final r = metricRange(sample, RideColorMetric.avgSpeed);
      expect(r.normalize(40), 0);
      expect(r.normalize(70), 1);
      expect(r.normalize(55), closeTo(0.5, 0.001));
    });

    test('normalize clamps out-of-range values', () {
      const r = MetricRange(40, 70);
      expect(r.normalize(10), 0);
      expect(r.normalize(200), 1);
    });

    test('no spread → everything paints mid-scale', () {
      final flat = [
        ride(id: 'p', avgKmh: 50),
        ride(id: 'q', avgKmh: 50),
      ];
      final r = metricRange(flat, RideColorMetric.avgSpeed);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(50), 0.5);
    });

    test('empty list → degenerate range, no crash', () {
      final r = metricRange(const [], RideColorMetric.maxSpeed);
      expect(r.hasSpread, isFalse);
      expect(r.normalize(123), 0.5);
    });

    test('metric selects the right field', () {
      final r = metricRange(sample, RideColorMetric.maxSpeed);
      expect(r.min, 90);
      expect(r.max, 140);
    });
  });

  group('RideFilter helpers', () {
    test('hasActiveConstraints ignores sort', () {
      expect(const RideFilter(sort: RideSort.fastestMax).hasActiveConstraints,
          isFalse);
      expect(const RideFilter(minDistanceKm: 1).hasActiveConstraints, isTrue);
    });

    test('activeDimensionCount counts each dimension once', () {
      const f = RideFilter(
        minDistanceKm: 1,
        maxDistanceKm: 100, // same dimension → still 1
        minMaxSpeedKmh: 50,
      );
      expect(f.activeDimensionCount, 2);
    });

    test('clearedConstraints keeps sort, drops constraints', () {
      const f = RideFilter(minDistanceKm: 10, sort: RideSort.fastestAvg);
      final c = f.clearedConstraints();
      expect(c.hasActiveConstraints, isFalse);
      expect(c.sort, RideSort.fastestAvg);
    });

    test('copyWith can null out a bound via explicit null', () {
      const f = RideFilter(minDistanceKm: 10);
      expect(f.copyWith(minDistanceKm: null).minDistanceKm, isNull);
      // unspecified field is preserved
      expect(f.copyWith(sort: RideSort.newest).minDistanceKm, 10);
    });
  });
}
