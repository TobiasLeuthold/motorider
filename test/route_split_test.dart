import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/geo.dart';

void main() {
  // A simple three-vertex, due-east polyline: each leg is ~one degree of
  // longitude. We split by along-distance and check both halves.
  final path = const [
    LatLng(46.0, 8.0),
    LatLng(46.0, 8.1), // leg 0
    LatLng(46.0, 8.2), // leg 1
  ];
  final cum = cumulativeMeters(path);
  final total = cum.last;
  final mid = cum[1]; // exactly at vertex 1

  // The split point must be the SAME point in both halves (no gap).
  void expectSeam(SplitPath s) {
    if (s.passed.isEmpty || s.upcoming.isEmpty) return;
    expect(s.passed.last.latitude, s.upcoming.first.latitude);
    expect(s.passed.last.longitude, s.upcoming.first.longitude);
  }

  group('splitAlong', () {
    test('at the very start: nothing passed, whole line ahead', () {
      final s = splitAlong(path, 0, cumulative: cum);
      expect(s.passed, isEmpty);
      expect(s.upcoming, path);
    });

    test('negative along clamps to the start', () {
      final s = splitAlong(path, -50, cumulative: cum);
      expect(s.passed, isEmpty);
      expect(s.upcoming.length, path.length);
    });

    test('at the very end: whole line passed, nothing ahead', () {
      final s = splitAlong(path, total, cumulative: cum);
      expect(s.passed, path);
      expect(s.upcoming, isEmpty);
    });

    test('past the end clamps to the end', () {
      final s = splitAlong(path, total + 999, cumulative: cum);
      expect(s.passed.length, path.length);
      expect(s.upcoming, isEmpty);
    });

    test('exactly on an interior vertex splits there with no duplicate', () {
      final s = splitAlong(path, mid, cumulative: cum);
      // passed = vertices 0..1, upcoming = vertices 1..2 — the vertex is shared
      // but not duplicated within either half.
      expect(s.passed.length, 2);
      expect(s.upcoming.length, 2);
      expect(s.passed.last, path[1]);
      expect(s.upcoming.first, path[1]);
      expectSeam(s);
    });

    test('between vertices interpolates the split point', () {
      // Quarter of the way along the first leg.
      final along = cum[1] * 0.25;
      final s = splitAlong(path, along, cumulative: cum);
      expect(s.passed.length, 2); // start + interpolated split
      expect(s.upcoming.length, 3); // split + remaining two vertices
      // The interpolated point sits on the first leg, east of the start.
      final split = s.passed.last;
      expect(split.latitude, closeTo(46.0, 1e-6));
      expect(split.longitude, greaterThan(8.0));
      expect(split.longitude, lessThan(8.1));
      expect(split.longitude, closeTo(8.025, 1e-3));
      expectSeam(s);
    });

    test('in the middle of the second leg keeps the first leg fully passed', () {
      final along = cum[1] + (cum[2] - cum[1]) * 0.5;
      final s = splitAlong(path, along, cumulative: cum);
      // passed: v0, v1, split-on-leg-1
      expect(s.passed.length, 3);
      expect(s.passed[0], path[0]);
      expect(s.passed[1], path[1]);
      expect(s.passed.last.longitude, closeTo(8.15, 1e-3));
      // upcoming: split, v2
      expect(s.upcoming.length, 2);
      expect(s.upcoming.last, path[2]);
      expectSeam(s);
    });

    test('the two halves together cover the whole line length', () {
      final along = total * 0.4;
      final s = splitAlong(path, along, cumulative: cum);
      final covered =
          pathLengthMeters(s.passed) + pathLengthMeters(s.upcoming);
      expect(covered, closeTo(total, 1e-3));
    });

    test('degenerate single-point path: nothing to split', () {
      final s = splitAlong(const [LatLng(46, 8)], 0);
      expect(s.passed, isEmpty);
      expect(s.upcoming.length, 1);
    });

    test('works without a precomputed cumulative table', () {
      final s = splitAlong(path, mid);
      expect(s.passed.length, 2);
      expect(s.upcoming.length, 2);
      expectSeam(s);
    });
  });
}
