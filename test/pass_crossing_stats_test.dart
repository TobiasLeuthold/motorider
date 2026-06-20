import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/geo.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// Stage B — per-crossing stats (direction, average speed, duration over a
/// pass). These exercise the PURE corridor/speed/direction math in isolation
/// from the database, the map and any Flutter binding.
///
/// Geometry trick: every fixture pass runs dead-straight north–south through a
/// reference col along a single meridian, so a point [_north]`(x)` of the col
/// sits exactly on the segment polyline (cross-track ≈ 0). That lets the tests
/// place fixes at precise distances and feed the real haversine/snap helpers.

const _col = LatLng(46.5727, 8.4152); // Furkapass-ish
const double _mPerLat = 111195.0; // metres per degree of latitude (spherical)

/// A point [metresNorth] of [_col] (negative = south), on the meridian.
LatLng _north(double metresNorth) =>
    LatLng(_col.latitude + metresNorth / _mPerLat, _col.longitude);

/// A north–south segment pass through [_col]: south foot is [start], north foot
/// is [end], geometry is the straight meridian line south-foot → col → north
/// foot. [footM] is how far each foot sits from the col.
Pass _segPass({
  double footM = 5000,
  List<String>? connects,
  int? ele = 2400,
}) =>
    Pass(
      name: 'Seg',
      lat: _col.latitude,
      lon: _col.longitude,
      ele: ele,
      cantons: const ['UR'],
      connects: connects,
      start: PassPoint(lat: _north(-footM).latitude, lon: _col.longitude, ele: 1500),
      end: PassPoint(lat: _north(footM).latitude, lon: _col.longitude, ele: 1600),
      geometry: [_north(-footM), _col, _north(footM)],
    );

/// A ride track from [pts] with explicit per-fix [times]; optional parallel
/// [speeds] (m/s). Distances/speeds are controlled by the caller.
RideTrack _trackT(
  String id,
  List<LatLng> pts,
  List<DateTime> times, {
  List<double?> speeds = const [],
}) =>
    RideTrack(rideId: id, points: pts, times: times, speedsMs: speeds);

/// Build a constant-cadence track that walks the given north-offsets (metres),
/// one fix every [stepS] seconds. Returns the track; if [speeds] given it's
/// attached as the recorded-speed channel.
RideTrack _walk(
  String id,
  List<double> offsetsM, {
  int stepS = 10,
  DateTime? start,
  List<double?> speeds = const [],
}) {
  final t0 = start ?? DateTime(2026, 6, 1, 10);
  return _trackT(
    id,
    [for (final m in offsetsM) _north(m)],
    [for (var i = 0; i < offsetsM.length; i++) t0.add(Duration(seconds: i * stepS))],
    speeds: speeds,
  );
}

/// Run detection + per-crossing stats end-to-end for one pass + one ride.
PassProgress _explore(Pass pass, RideTrack ride) =>
    explorePasses([pass], [ride]).progress.single;

void main() {
  // ─────────────────────────── corridor membership ────────────────────────
  group('isInCorridor', () {
    final pass = _segPass();
    final geom = pass.geometry;

    test('a point on the segment line is inside the corridor', () {
      expect(isInCorridor(_north(0), geom), isTrue);
      expect(isInCorridor(_north(2000), geom), isTrue);
    });

    test('a point 80 m to the side is inside (< 120 m half-width)', () {
      // Shift east by ~80 m at this latitude.
      final mPerLon = 111195.0 * 0.687; // cos(46.57°) ≈ 0.687
      final p = LatLng(_col.latitude, _col.longitude + 80 / mPerLon);
      expect(isInCorridor(p, geom), isTrue);
    });

    test('a point 250 m to the side is outside the corridor', () {
      final mPerLon = 111195.0 * 0.687;
      final p = LatLng(_col.latitude, _col.longitude + 250 / mPerLon);
      expect(isInCorridor(p, geom), isFalse);
    });

    test('with degenerate geometry it falls back to nearness to a foot', () {
      final s = PassPoint(lat: _north(-100).latitude, lon: _col.longitude);
      // No polyline, but within 120 m of the start foot.
      expect(
        isInCorridor(_north(-150), const [], startFoot: s),
        isTrue, // 50 m from the foot
      );
      expect(
        isInCorridor(_north(-400), const [], startFoot: s),
        isFalse, // 300 m from the foot
      );
    });
  });

  // ─────────────────────────── corridor window ────────────────────────────
  group('corridorWindow', () {
    final pass = _segPass(footM: 5000);

    test('grows to the maximal run of corridor fixes around the trigger', () {
      // Fixes: far south (outside), then a run through the corridor, then far
      // north (outside). The trigger is the col fix (index 3).
      final ride = _walk('r', [-8000, -4000, -1000, 0, 1000, 4000, 8000]);
      final crossings = detectCrossingsInTrack(ride, pass.latLng);
      expect(crossings, hasLength(1));
      final win = corridorWindow(ride, pass, triggerIndex: crossings.first.triggerIndex);
      expect(win, isNotNull);
      // -4000..4000 are within the 5 km segment + corridor; ±8000 are not.
      expect(win!.startIndex, 1);
      expect(win.endIndex, 5);
      // Entered nearer the south (start) foot → start→end.
      expect(win.entryNearStartFoot, isTrue);
    });

    test('returns null when the trigger fix is not actually in the corridor',
        () {
      // A ride that passes within 250 m of the col (so the hysteresis detector
      // FIRES) but stays ~200 m to the SIDE of the road the whole time — it
      // only clips near the col, never enters the corridor.
      final mPerLon = 111195.0 * 0.687;
      LatLng side(double northM) =>
          LatLng(_col.latitude + northM / _mPerLat, _col.longitude + 200 / mPerLon);
      final t0 = DateTime(2026, 6, 1, 10);
      final ride = RideTrack(
        rideId: 'r',
        points: [side(-3000), side(0), side(3000)],
        times: [t0, t0.add(const Duration(seconds: 10)), t0.add(const Duration(seconds: 20))],
      );
      final crossings = detectCrossingsInTrack(ride, pass.latLng);
      expect(crossings, hasLength(1), reason: 'within 250 m of col → fires');
      final win = corridorWindow(ride, pass, triggerIndex: crossings.first.triggerIndex);
      expect(win, isNull, reason: '200 m off the road → not a corridor traversal');
    });
  });

  // ─────────────────── average speed: recorded vs fallback ─────────────────
  group('crossingStats — average speed', () {
    final pass = _segPass(footM: 5000);

    test('constant 72 km/h drive-through → correct avgSpeed + duration', () {
      // 72 km/h = 20 m/s. Walk -4000→4000 in 400 m steps, one fix per step.
      // 21 fixes, 20 m/s constant. Recorded speeds all 20 m/s.
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final speeds = [for (final _ in offsets) 20.0 as double?];
      // Each 400 m leg at 20 m/s = 20 s.
      final ride = _walk('r', offsets, stepS: 20, speeds: speeds);
      final prog = _explore(pass, ride);
      expect(prog.crossings, hasLength(1));
      final c = prog.crossings.single;
      expect(c.avgSpeedKmh, closeTo(72.0, 0.001));
      // 20 legs × 20 s = 400 s in the corridor.
      expect(c.durationS, 400);
      expect(c.direction, PassDirection.startToEnd);
    });

    test('falls back to corridor distance ÷ time when speeds are absent', () {
      // No recorded speeds. 8 km of corridor (-4000→4000) covered in 400 s →
      // 8000 m / 400 s = 20 m/s = 72 km/h.
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final ride = _walk('r', offsets, stepS: 20); // no speeds
      final c = _explore(pass, ride).crossings.single;
      expect(c.avgSpeedKmh, closeTo(72.0, 0.5));
      expect(c.durationS, 400);
    });

    test('falls back when recorded speeds are present but all zero/null', () {
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final speeds = [for (final _ in offsets) 0.0 as double?]; // all zero
      final ride = _walk('r', offsets, stepS: 20, speeds: speeds);
      final c = _explore(pass, ride).crossings.single;
      // Zeroes ignored → distance/time fallback gives ~72 km/h, not 0.
      expect(c.avgSpeedKmh, closeTo(72.0, 0.5));
    });

    test('recorded-speed average ignores an implausible outlier fix', () {
      // Three corridor fixes at a steady 20 m/s with one 500 m/s garbage spike.
      // Mean of the valid three is 20 m/s = 72 km/h; the spike must be dropped.
      final offsets = [-2000.0, -1000.0, 0.0, 1000.0, 2000.0];
      final speeds = <double?>[20, 20, 500, 20, 20]; // index 2 is garbage
      final ride = _walk('r', offsets, stepS: 50, speeds: speeds);
      final c = _explore(pass, ride).crossings.single;
      expect(c.avgSpeedKmh, closeTo(72.0, 0.001));
    });
  });

  // ─────────────────────────────── direction ──────────────────────────────
  group('crossingStats — direction', () {
    test('south→north over a start(south)→end(north) pass is startToEnd', () {
      final pass = _segPass(connects: ['Süd', 'Nord']);
      final ride = _walk('r', [-4000, -1000, 0, 1000, 4000], stepS: 20);
      final c = _explore(pass, ride).crossings.single;
      expect(c.direction, PassDirection.startToEnd);
      expect(c.directionLabel, 'Süd → Nord');
    });

    test('north→south is the reverse direction (endToStart)', () {
      final pass = _segPass(connects: ['Süd', 'Nord']);
      final ride = _walk('r', [4000, 1000, 0, -1000, -4000], stepS: 20);
      final c = _explore(pass, ride).crossings.single;
      expect(c.direction, PassDirection.endToStart);
      expect(c.directionLabel, 'Nord → Süd');
    });

    test('falls back to ↑/↓ arrows when connects is missing', () {
      final pass = _segPass(connects: null);
      final up = _explore(pass, _walk('u', [-4000, 0, 4000], stepS: 20))
          .crossings
          .single;
      final down = _explore(pass, _walk('d', [4000, 0, -4000], stepS: 20))
          .crossings
          .single;
      expect(up.directionLabel, '↑');
      expect(down.directionLabel, '↓');
    });
  });

  // ───────────────────────── two crossings, measured ──────────────────────
  group('two separate crossings each measured independently', () {
    final pass = _segPass(footM: 4000);

    test('out-and-back: two crossings, opposite directions, own speeds', () {
      // Leg 1 (south→north) slow at ~36 km/h (10 m/s); go > 3 km past to
      // re-arm; Leg 2 (north→south) fast at ~72 km/h (20 m/s).
      // Build offsets + matching times so each corridor leg has its own speed.
      final offsets = <double>[
        -3000, -1500, 0, 1500, 3000, // leg 1 (10 m/s)
        6000, // way past north foot → re-arm (outside corridor)
        3000, 1500, 0, -1500, -3000, // leg 2 (20 m/s)
      ];
      // Times: leg 1 legs are 1500 m @ 10 m/s = 150 s each; the jump out and
      // back is arbitrary; leg 2 legs are 1500 m @ 20 m/s = 75 s each.
      final t0 = DateTime(2026, 6, 1, 10);
      var t = t0;
      final times = <DateTime>[];
      void add(int s) {
        t = t.add(Duration(seconds: s));
        times.add(t);
      }
      times.add(t0); // index 0
      add(150); add(150); add(150); add(150); // leg 1 (indices 1..4)
      add(600); // big jump out north (index 5)
      add(600); // jump back to north foot (index 6, start of leg 2)
      add(75); add(75); add(75); add(75); // leg 2 (indices 7..10)
      final ride = _trackT('r', [for (final m in offsets) _north(m)], times);

      final prog = _explore(pass, ride);
      expect(prog.count, 2, reason: 'genuine out-and-back counts twice');
      expect(prog.crossings, hasLength(2));

      final first = prog.crossings[0]; // chronologically first = leg 1
      final second = prog.crossings[1];
      expect(first.direction, PassDirection.startToEnd);
      expect(second.direction, PassDirection.endToStart);
      // Leg 1 ≈ 36 km/h (distance/time fallback), leg 2 ≈ 72 km/h.
      expect(first.avgSpeedKmh, closeTo(36.0, 1.0));
      expect(second.avgSpeedKmh, closeTo(72.0, 1.0));
      // best/mean aggregates over the two.
      expect(prog.bestSpeedKmh, closeTo(72.0, 1.0));
      expect(prog.meanSpeedKmh, closeTo((36.0 + 72.0) / 2, 1.0));
    });
  });

  // ──────────────────────────── edge clipping ─────────────────────────────
  group('a ride that only clips the corridor edge is not a measured crossing',
      () {
    final pass = _segPass(footM: 5000);

    test('clip near the col but off-road → fires count but no crossing stats',
        () {
      final mPerLon = 111195.0 * 0.687;
      LatLng side(double northM) =>
          LatLng(_col.latitude + northM / _mPerLat, _col.longitude + 200 / mPerLon);
      final t0 = DateTime(2026, 6, 1, 10);
      final ride = RideTrack(
        rideId: 'r',
        points: [side(-3000), side(-100), side(0), side(100), side(3000)],
        times: [
          for (var i = 0; i < 5; i++) t0.add(Duration(seconds: i * 10)),
        ],
      );
      final prog = _explore(pass, ride);
      // Hysteresis still counts it (within 250 m of the col)...
      expect(prog.count, 1);
      // ...but no corridor traversal was measured (200 m off the road).
      expect(prog.crossings, isEmpty);
      expect(prog.bestSpeedKmh, isNull);
    });
  });

  // ───────────────────────── GPS-gap robustness ───────────────────────────
  group('GPS-gap robustness', () {
    final pass = _segPass(footM: 6000);

    test('a mid-corridor teleport leg does not inflate the fallback speed', () {
      // A clean 36 km/h run straight over the col (col fix kept, so it fires),
      // but ONE intermediate fix is a GPS teleport ~50 km off the line and back
      // within 1 s. The fallback must skip the teleport legs (implausible leg
      // speed) so the measured speed stays ~36 km/h, not in the hundreds.
      // Offsets along the meridian: 500 m legs @ 10 m/s = 50 s each; index 2 is
      // the teleport (a wild outlier in BOTH position and timing).
      final offsets = <double>[-1500, -1000, -500, 0, 500, 1000, 1500];
      final t0 = DateTime(2026, 6, 1, 10);
      final pts = [for (final m in offsets) _north(m)];
      pts[2] = _north(50000); // teleport ~50 km north for one fix
      final times = <DateTime>[
        t0,
        t0.add(const Duration(seconds: 50)),
        t0.add(const Duration(seconds: 51)), // 1 s jump out
        t0.add(const Duration(seconds: 52)), // 1 s jump back
        t0.add(const Duration(seconds: 102)),
        t0.add(const Duration(seconds: 152)),
        t0.add(const Duration(seconds: 202)),
      ];
      final ride = _trackT('r', pts, times);
      // The col fix (index 3) is within 250 m → a crossing fires.
      final crossings = detectCrossingsInTrack(ride, pass.latLng);
      expect(crossings, isNotEmpty);
      // The teleport fix is far outside the corridor, so it breaks the
      // contiguous corridor run; the window is the part containing the col.
      final c = crossingStats(ride, pass, crossings.first);
      expect(c, isNotNull);
      expect(c!.avgSpeedKmh, isNotNull);
      expect(c.avgSpeedKmh!, lessThan(60.0),
          reason: 'teleport leg must not inflate the fallback speed');
      expect(c.avgSpeedKmh!, greaterThan(20.0));
    });

    test('recorded-speed path is immune to a position teleport entirely', () {
      // Same shape, but recorded speeds are a steady 10 m/s. The average uses
      // the recorded channel (not positions), so the answer is an exact
      // 36 km/h regardless of the bad position fix.
      final offsets = <double>[-1500, -1000, -500, 0, 500, 1000, 1500];
      final pts = [for (final m in offsets) _north(m)];
      pts[2] = _north(50000); // outlier position, but still inside corridor run?
      // Keep the teleport OUTSIDE the corridor so it splits the run, then make
      // sure the recorded average over the surviving window is exact.
      final t0 = DateTime(2026, 6, 1, 10);
      final times = <DateTime>[
        for (var i = 0; i < 7; i++) t0.add(Duration(seconds: i * 50)),
      ];
      final speeds = <double?>[10, 10, 10, 10, 10, 10, 10];
      final ride = _trackT('r', pts, times, speeds: speeds);
      final crossings = detectCrossingsInTrack(ride, pass.latLng);
      expect(crossings, isNotEmpty);
      final c = crossingStats(ride, pass, crossings.first);
      expect(c, isNotNull);
      expect(c!.avgSpeedKmh, closeTo(36.0, 0.001));
    });
  });

  // ──────────────────── collection-level cool stats ───────────────────────
  group('collection stats — fastest crossing + total time on passes', () {
    test('fastestCrossing picks the single fastest pass crossing anywhere', () {
      // Two passes far apart. Pass A ridden at 54 km/h (15 m/s); pass B at
      // 90 km/h (25 m/s). The collection's fastest crossing is B @ 90.
      final colA = const LatLng(46.50, 8.40);
      final colB = const LatLng(46.70, 9.00);

      Pass seg(String name, LatLng col) => Pass(
            name: name,
            lat: col.latitude,
            lon: col.longitude,
            ele: 2000,
            cantons: const ['UR'],
            start: PassPoint(lat: col.latitude - 4000 / _mPerLat, lon: col.longitude),
            end: PassPoint(lat: col.latitude + 4000 / _mPerLat, lon: col.longitude),
            geometry: [
              LatLng(col.latitude - 4000 / _mPerLat, col.longitude),
              col,
              LatLng(col.latitude + 4000 / _mPerLat, col.longitude),
            ],
          );

      RideTrack rideOver(String id, LatLng col, double speedMs) {
        final offsets = [-3000.0, -1500, 0, 1500, 3000];
        final pts = [
          for (final m in offsets) LatLng(col.latitude + m / _mPerLat, col.longitude),
        ];
        final t0 = DateTime(2026, 6, 1, 10);
        final times = [
          for (var i = 0; i < offsets.length; i++) t0.add(Duration(seconds: i * 10)),
        ];
        final speeds = [for (final _ in offsets) speedMs as double?];
        return RideTrack(rideId: id, points: pts, times: times, speedsMs: speeds);
      }

      final res = explorePasses(
        [seg('A', colA), seg('B', colB)],
        [rideOver('rA', colA, 15), rideOver('rB', colB, 25)],
      );
      expect(res.stats.fastestCrossing, isNotNull);
      expect(res.stats.fastestCrossing!.pass.name, 'B');
      expect(res.stats.fastestCrossing!.avgSpeedKmh, closeTo(90.0, 0.001));
      expect(res.stats.fastestCrossing!.rideId, 'rB');
      // Total time on passes = both corridor durations summed.
      // Each ride: 4 legs × 10 s = 40 s in the corridor → 80 s total.
      expect(res.stats.totalTimeOnPassesS, 80);
    });

    test('no measurable crossings → fastestCrossing null, total time 0', () {
      final res = explorePasses(
        [_segPass()],
        const [],
      );
      expect(res.stats.fastestCrossing, isNull);
      expect(res.stats.totalTimeOnPassesS, 0);
    });
  });

  // ─────────────── sanity: scaffolding distance is what we think ───────────
  group('scaffolding sanity', () {
    test('_north places points at the requested metres from the col', () {
      expect(haversineMeters(_north(1500), _col), closeTo(1500, 2));
      expect(haversineMeters(_north(-4000), _col), closeTo(4000, 5));
    });
  });
}
