import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/geo.dart';

void main() {
  group('haversineMeters', () {
    test('one degree of latitude is ~111 km', () {
      final d = haversineMeters(const LatLng(46, 8), const LatLng(47, 8));
      expect(d, closeTo(111195, 500));
    });

    test('zero for identical points', () {
      expect(haversineMeters(const LatLng(46.8, 8.2), const LatLng(46.8, 8.2)),
          0);
    });
  });

  group('bearingDeg', () {
    test('due north is ~0°', () {
      expect(bearingDeg(const LatLng(46, 8), const LatLng(47, 8)),
          closeTo(0, 0.5));
    });
    test('due east is ~90°', () {
      expect(bearingDeg(const LatLng(46, 8), const LatLng(46, 9)),
          closeTo(90, 1.0));
    });
  });

  group('curvinessScore', () {
    test('a straight line scores ~0', () {
      final straight = [
        for (var i = 0; i < 10; i++) LatLng(46.0 + i * 0.01, 8.0),
      ];
      expect(curvinessScore(straight), lessThan(1.0));
    });

    test('a zigzag scores much higher than a straight line', () {
      final straight = [
        for (var i = 0; i < 10; i++) LatLng(46.0 + i * 0.01, 8.0),
      ];
      final zigzag = <LatLng>[];
      for (var i = 0; i < 10; i++) {
        zigzag.add(LatLng(46.0 + i * 0.01, 8.0 + (i.isEven ? 0.0 : 0.01)));
      }
      expect(curvinessScore(zigzag), greaterThan(curvinessScore(straight) + 30));
    });
  });

  group('snapToPath', () {
    final path = const [
      LatLng(46.0, 8.0),
      LatLng(46.0, 8.1), // due east leg
    ];

    test('cross-track distance matches the perpendicular offset', () {
      // A point ~111 m north of the midpoint of the east-west leg.
      final p = const LatLng(46.001, 8.05);
      final snap = snapToPath(p, path)!;
      expect(snap.crossTrackMeters, closeTo(111, 12));
      expect(snap.segmentIndex, 0);
    });

    test('along distance is ~half the leg at the midpoint', () {
      final legLen = haversineMeters(path[0], path[1]);
      final snap = snapToPath(const LatLng(46.0, 8.05), path)!;
      expect(snap.alongMeters, closeTo(legLen / 2, legLen * 0.05));
    });

    test('clamps to the start vertex for points before the line', () {
      final snap = snapToPath(const LatLng(46.0, 7.9), path)!;
      expect(snap.alongMeters, closeTo(0, 5));
    });
  });

  group('midpointAlong', () {
    test('is the geometric centre of a straight line', () {
      final mid = midpointAlong(const [
        LatLng(46.0, 8.0),
        LatLng(46.0, 8.2),
      ]);
      expect(mid.longitude, closeTo(8.1, 0.001));
      expect(mid.latitude, closeTo(46.0, 0.001));
    });
  });

  group('slippy tiles', () {
    test('Bern (z14) lands on a sane tile index', () {
      // Bern ≈ 46.948 N, 7.447 E.
      final x = lonToTileX(7.447, 14);
      final y = latToTileY(46.948, 14);
      expect(x, inInclusiveRange(8500, 8540));
      expect(y, inInclusiveRange(5740, 5790));
    });

    test('metersPerPixel shrinks as zoom grows', () {
      expect(metersPerPixel(47, 14), lessThan(metersPerPixel(47, 11)));
    });
  });

  group('snapToPathWindowed', () {
    // An out-and-back along the same east-west line: A→M→B then B→M→A. The
    // midpoint M is visited TWICE — at ~773 m (outbound) and ~2319 m (return) —
    // which is exactly the self-revisiting geometry that breaks a global snap.
    final outAndBack = const [
      LatLng(46.0, 8.00), // A  @ 0
      LatLng(46.0, 8.01), // M  @ ~773  (first pass)
      LatLng(46.0, 8.02), // B  @ ~1546 (turnaround)
      LatLng(46.0, 8.01), // M  @ ~2319 (second pass)
      LatLng(46.0, 8.00), // A  @ ~3092
    ];
    final cum = cumulativeMeters(outAndBack);
    final m = const LatLng(46.0, 8.01); // the revisited point

    test('a window over the first pass matches the first occurrence', () {
      final snap =
          snapToPathWindowed(m, outAndBack, 0, 1200, cumulative: cum)!;
      expect(snap.crossTrackMeters, closeTo(0, 5));
      expect(snap.alongMeters, closeTo(cum[1], 20)); // ~773, NOT ~2319
    });

    test('a window over the second pass matches the later occurrence', () {
      final snap =
          snapToPathWindowed(m, outAndBack, 1800, 3092, cumulative: cum)!;
      expect(snap.crossTrackMeters, closeTo(0, 5));
      expect(snap.alongMeters, closeTo(cum[3], 20)); // ~2319
    });

    test('an unrestricted window equals the global snap', () {
      final windowed = snapToPathWindowed(
          const LatLng(46.0005, 8.015), outAndBack, -1e9, 1e9,
          cumulative: cum)!;
      final global = snapToPath(const LatLng(46.0005, 8.015), outAndBack,
          cumulative: cum)!;
      expect(windowed.alongMeters, closeTo(global.alongMeters, 1e-6));
      expect(windowed.crossTrackMeters, closeTo(global.crossTrackMeters, 1e-6));
      expect(windowed.segmentIndex, global.segmentIndex);
    });

    test('a window past the end of the line matches nothing', () {
      final snap = snapToPathWindowed(m, outAndBack, 99000, 100000,
          cumulative: cum);
      expect(snap, isNull);
    });
  });

  group('navBands', () {
    // A dead-straight ~3.09 km east line (two vertices is enough — the bands are
    // built by length, not vertex count).
    final line = const [LatLng(46.0, 8.0), LatLng(46.0, 8.04)];
    final total = pathLengthMeters(line);

    test('at the start: nothing passed, a 1 km highlight, rest beyond', () {
      final b = navBands(line, 0, 1000);
      expect(b.passed, isEmpty);
      expect(pathLengthMeters(b.near), closeTo(1000, 30));
      expect(pathLengthMeters(b.far), closeTo(total - 1000, 30));
    });

    test('the three bands together cover the whole route length', () {
      final b = navBands(line, 600, 1000);
      final covered = pathLengthMeters(b.passed) +
          pathLengthMeters(b.near) +
          pathLengthMeters(b.far);
      expect(covered, closeTo(total, 1.0));
      expect(pathLengthMeters(b.passed), closeTo(600, 30));
      expect(pathLengthMeters(b.near), closeTo(1000, 30));
    });

    test('near the end the highlight is the whole remaining route, far empty',
        () {
      final b = navBands(line, total - 300, 1000);
      expect(b.far, isEmpty);
      expect(pathLengthMeters(b.near), closeTo(300, 30));
    });

    test('the bands meet seamlessly (shared boundary points)', () {
      final b = navBands(line, 600, 1000);
      expect(b.passed.last.longitude, closeTo(b.near.first.longitude, 1e-9));
      expect(b.near.last.longitude, closeTo(b.far.first.longitude, 1e-9));
    });
  });
}
