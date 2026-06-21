import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/geo.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// Per-crossing stats — now a FIXED-distance, foot-to-foot, moving-time metric:
/// average speed = the pass's known street length ÷ the (stop-free) time taken
/// between its two defined feet. These exercise the PURE corridor/timing math in
/// isolation from the database, the map and any Flutter binding.
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
/// is [end], geometry is the straight meridian south-foot → col → north-foot.
/// [footM] is how far each foot sits from the col; [lengthKm] is the pass's
/// FIXED street distance, defaulting to the true foot-to-foot length.
Pass _segPass({
  double footM = 4000,
  double? lengthKm,
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
      start:
          PassPoint(lat: _north(-footM).latitude, lon: _col.longitude, ele: 1500),
      end: PassPoint(lat: _north(footM).latitude, lon: _col.longitude, ele: 1600),
      lengthKm: lengthKm ?? (2 * footM / 1000.0),
      geometry: [_north(-footM), _col, _north(footM)],
    );

/// A ride track from [pts] with explicit per-fix [times].
RideTrack _trackT(String id, List<LatLng> pts, List<DateTime> times) =>
    RideTrack(rideId: id, points: pts, times: times, speedsMs: const []);

/// A constant-cadence track walking the given north-offsets (metres), one fix
/// every [stepS] seconds.
RideTrack _walk(String id, List<double> offsetsM, {int stepS = 10}) {
  final t0 = DateTime(2026, 6, 1, 10);
  return _trackT(
    id,
    [for (final m in offsetsM) _north(m)],
    [for (var i = 0; i < offsetsM.length; i++) t0.add(Duration(seconds: i * stepS))],
  );
}

/// Run detection + per-crossing stats end-to-end for one pass + one ride.
PassProgress _explore(Pass pass, RideTrack ride) =>
    explorePasses([pass], [ride]).progress.single;

DirectionStats _dir(PassProgress p, PassDirection d) =>
    p.directions.firstWhere((s) => s.direction == d);

void main() {
  // ─────────────────────────── corridor membership ────────────────────────
  group('isInCorridor', () {
    final geom = _segPass().geometry;

    test('a point on the segment line is inside the corridor', () {
      expect(isInCorridor(_north(0), geom), isTrue);
      expect(isInCorridor(_north(2000), geom), isTrue);
    });

    test('a point 80 m to the side is inside (< 120 m half-width)', () {
      final mPerLon = 111195.0 * 0.687; // cos(46.57°) ≈ 0.687
      final p = LatLng(_col.latitude, _col.longitude + 80 / mPerLon);
      expect(isInCorridor(p, geom), isTrue);
    });

    test('a point 250 m to the side is outside the corridor', () {
      final mPerLon = 111195.0 * 0.687;
      final p = LatLng(_col.latitude, _col.longitude + 250 / mPerLon);
      expect(isInCorridor(p, geom), isFalse);
    });
  });

  // ─────────────────────────── corridor window ────────────────────────────
  group('corridorWindow', () {
    final pass = _segPass(footM: 5000);

    test('grows to the maximal run of corridor fixes around the trigger', () {
      final ride = _walk('r', [-8000, -4000, -1000, 0, 1000, 4000, 8000]);
      final crossings = detectCrossingsInTrack(ride, pass.latLng);
      expect(crossings, hasLength(1));
      final win =
          corridorWindow(ride, pass, triggerIndex: crossings.first.triggerIndex);
      expect(win, isNotNull);
      expect(win!.startIndex, 1);
      expect(win.endIndex, 5);
    });

    test('returns null when the trigger fix is not actually in the corridor',
        () {
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
      final win =
          corridorWindow(ride, pass, triggerIndex: crossings.first.triggerIndex);
      expect(win, isNull, reason: '200 m off the road → not a corridor traversal');
    });
  });

  // ───────────────── fixed-distance, moving-time average speed ─────────────
  group('crossingStats — fixed-distance speed + moving time', () {
    test('constant-speed foot-to-foot traversal → length ÷ moving time', () {
      // 8 km pass (feet ±4000), ridden -4000→4000 at 20 m/s (400 m steps, 20 s
      // each): 20 legs × 20 s = 400 s moving, 8 km / 400 s = 72 km/h.
      final pass = _segPass(footM: 4000); // lengthKm = 8.0
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final ride = _walk('r', offsets, stepS: 20);
      final c = _explore(pass, ride).crossings.single;
      expect(c.avgSpeedKmh, closeTo(72.0, 0.001));
      expect(c.movingTimeS, 400);
      expect(c.durationS, 400); // no stops → moving == elapsed
      expect(c.direction, PassDirection.startToEnd);
    });

    test('uses the pass FIXED street length, not the GPS track length', () {
      // Same 8 km of GPS path, but the pass's official street length is 10 km.
      // Speed must come from 10 km ÷ 400 s = 90 km/h, NOT 72.
      final pass = _segPass(footM: 4000, lengthKm: 10.0);
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final ride = _walk('r', offsets, stepS: 20);
      final c = _explore(pass, ride).crossings.single;
      expect(c.avgSpeedKmh, closeTo(90.0, 0.001));
      expect(c.movingTimeS, 400);
    });

    test('moving time EXCLUDES a red-light stop at the col', () {
      // -4000→4000 with a 120 s standstill at the col. The 120 s must be dropped
      // from the moving time (so speed reflects riding, not waiting).
      final pass = _segPass(footM: 4000); // lengthKm 8.0
      final t0 = DateTime(2026, 6, 1, 10);
      final pts = [
        _north(-4000), _north(-2000), _north(0), _north(0), _north(0),
        _north(2000), _north(4000),
      ];
      final times = <DateTime>[
        t0,
        t0.add(const Duration(seconds: 100)), // moving 2 km @ 20 m/s
        t0.add(const Duration(seconds: 200)), // moving 2 km
        t0.add(const Duration(seconds: 260)), // STOPPED 60 s
        t0.add(const Duration(seconds: 320)), // STOPPED 60 s
        t0.add(const Duration(seconds: 420)), // moving 2 km
        t0.add(const Duration(seconds: 520)), // moving 2 km
      ];
      final c = _explore(pass, _trackT('r', pts, times)).crossings.single;
      expect(c.movingTimeS, 400, reason: 'the 120 s standstill must be excluded');
      expect(c.durationS, 520, reason: 'wall-clock still includes the stop');
      expect(c.avgSpeedKmh, closeTo(72.0, 0.1)); // 8 km / 400 s, NOT / 520 s
    });

    test('a ride that does not reach both feet gets no fixed-distance speed', () {
      // Up the south side to the col and back — never reaches the north foot.
      final pass = _segPass(footM: 4000);
      final t0 = DateTime(2026, 6, 1, 10);
      final ride = _trackT(
        'r',
        [_north(-4000), _north(0), _north(-4000)],
        [t0, t0.add(const Duration(seconds: 200)), t0.add(const Duration(seconds: 400))],
      );
      final prog = _explore(pass, ride);
      expect(prog.count, 1, reason: 'still a crossing');
      expect(prog.crossings, hasLength(1));
      expect(prog.crossings.single.avgSpeedKmh, isNull);
      expect(prog.crossings.single.movingTimeS, isNull);
      expect(prog.bestSpeedKmh, isNull);
      expect(prog.directions, isEmpty);
    });
  });

  // ─────────────────────────────── direction ──────────────────────────────
  group('crossingStats — direction', () {
    test('south→north over a start(south)→end(north) pass is startToEnd', () {
      final pass = _segPass(connects: ['Süd', 'Nord']);
      final ride = _walk('r', [-4000, -2000, 0, 2000, 4000], stepS: 100);
      final c = _explore(pass, ride).crossings.single;
      expect(c.direction, PassDirection.startToEnd);
      expect(c.directionLabel, 'Süd → Nord');
    });

    test('north→south is the reverse direction (endToStart)', () {
      final pass = _segPass(connects: ['Süd', 'Nord']);
      final ride = _walk('r', [4000, 2000, 0, -2000, -4000], stepS: 100);
      final c = _explore(pass, ride).crossings.single;
      expect(c.direction, PassDirection.endToStart);
      expect(c.directionLabel, 'Nord → Süd');
    });

    test('falls back to ↑/↓ arrows when connects is missing', () {
      final pass = _segPass(connects: null);
      final up = _explore(pass, _walk('u', [-4000, 0, 4000], stepS: 100))
          .crossings
          .single;
      final down = _explore(pass, _walk('d', [4000, 0, -4000], stepS: 100))
          .crossings
          .single;
      expect(up.directionLabel, '↑');
      expect(down.directionLabel, '↓');
    });
  });

  // ───────────────── two crossings, kept apart per direction ───────────────
  group('per-direction roll-up', () {
    test('out-and-back: each direction keeps its own fastest + average', () {
      // Leg 1 south→north slow (10 m/s → 36 km/h over the fixed 8 km); jump out
      // past the north foot to re-arm; leg 2 north→south fast (20 m/s → 72 km/h).
      final pass = _segPass(footM: 4000, connects: ['Süd', 'Nord']);
      final offsets = <double>[-4000, 0, 4000, 8000, 4000, 0, -4000];
      final t0 = DateTime(2026, 6, 1, 10);
      final times = <DateTime>[
        t0, // -4000
        t0.add(const Duration(seconds: 400)), // 0   (leg1 4 km @ 10 m/s)
        t0.add(const Duration(seconds: 800)), // 4000
        t0.add(const Duration(seconds: 1000)), // 8000 (jump out of corridor)
        t0.add(const Duration(seconds: 1200)), // 4000 (jump back)
        t0.add(const Duration(seconds: 1400)), // 0   (leg2 4 km @ 20 m/s)
        t0.add(const Duration(seconds: 1600)), // -4000
      ];
      final prog = _explore(pass, _trackT('r', [for (final m in offsets) _north(m)], times));

      expect(prog.count, 2, reason: 'genuine out-and-back counts twice');
      expect(prog.crossings, hasLength(2));
      final first = prog.crossings[0];
      final second = prog.crossings[1];
      expect(first.direction, PassDirection.startToEnd);
      expect(first.avgSpeedKmh, closeTo(36.0, 0.5));
      expect(first.movingTimeS, 800);
      expect(second.direction, PassDirection.endToStart);
      expect(second.avgSpeedKmh, closeTo(72.0, 0.5));
      expect(second.movingTimeS, 400);

      // Split per direction.
      expect(prog.directions, hasLength(2));
      final up = _dir(prog, PassDirection.startToEnd);
      final down = _dir(prog, PassDirection.endToStart);
      expect(up.count, 1);
      expect(up.label, 'Süd → Nord');
      expect(up.bestSpeedKmh, closeTo(36.0, 0.5));
      expect(up.bestTimeS, 800);
      expect(down.count, 1);
      expect(down.label, 'Nord → Süd');
      expect(down.bestSpeedKmh, closeTo(72.0, 0.5));

      // Pooled aggregates still available.
      expect(prog.bestSpeedKmh, closeTo(72.0, 0.5));
      expect(prog.meanSpeedKmh, closeTo((36.0 + 72.0) / 2, 0.5));
    });
  });

  // ──────────────────────────── edge clipping ─────────────────────────────
  group('a ride that only clips the corridor edge is not a measured crossing',
      () {
    test('clip near the col but off-road → fires count but no crossing stats',
        () {
      final pass = _segPass(footM: 5000);
      final mPerLon = 111195.0 * 0.687;
      LatLng side(double northM) =>
          LatLng(_col.latitude + northM / _mPerLat, _col.longitude + 200 / mPerLon);
      final t0 = DateTime(2026, 6, 1, 10);
      final ride = RideTrack(
        rideId: 'r',
        points: [side(-3000), side(-100), side(0), side(100), side(3000)],
        times: [for (var i = 0; i < 5; i++) t0.add(Duration(seconds: i * 10))],
      );
      final prog = _explore(pass, ride);
      expect(prog.count, 1);
      expect(prog.crossings, isEmpty);
      expect(prog.bestSpeedKmh, isNull);
    });
  });

  // ─────────────────── GPS-distance independence ───────────────────────────
  group('robust to GPS distance noise', () {
    test('lateral jitter that lengthens the GPS path leaves the speed unchanged',
        () {
      // Two rides, identical timing, one with sideways GPS jitter (a longer GPS
      // path). Because the metric uses the FIXED street length, both report the
      // same speed.
      final pass = _segPass(footM: 4000); // 8 km
      final offsets = [for (var m = -4000; m <= 4000; m += 400) m.toDouble()];
      final clean = _walk('clean', offsets, stepS: 20);
      final mPerLon = 111195.0 * 0.687;
      final t0 = DateTime(2026, 6, 1, 10);
      final jittery = RideTrack(
        rideId: 'jit',
        points: [
          for (var i = 0; i < offsets.length; i++)
            LatLng(_north(offsets[i]).latitude,
                _col.longitude + (i.isEven ? 60 : -60) / mPerLon),
        ],
        times: [for (var i = 0; i < offsets.length; i++) t0.add(Duration(seconds: i * 20))],
      );
      final a = _explore(pass, clean).crossings.single.avgSpeedKmh;
      final b = _explore(pass, jittery).crossings.single.avgSpeedKmh;
      expect(a, closeTo(72.0, 0.001));
      expect(b, closeTo(72.0, 0.001), reason: 'fixed distance ⇒ jitter-immune');
    });
  });

  // ──────────────────── collection-level cool stats ───────────────────────
  group('collection stats — fastest crossing + total moving time', () {
    Pass seg(String name, LatLng col) => Pass(
          name: name,
          lat: col.latitude,
          lon: col.longitude,
          ele: 2000,
          cantons: const ['UR'],
          lengthKm: 8.0,
          start: PassPoint(lat: col.latitude - 4000 / _mPerLat, lon: col.longitude),
          end: PassPoint(lat: col.latitude + 4000 / _mPerLat, lon: col.longitude),
          geometry: [
            LatLng(col.latitude - 4000 / _mPerLat, col.longitude),
            col,
            LatLng(col.latitude + 4000 / _mPerLat, col.longitude),
          ],
        );

    RideTrack rideOver(String id, LatLng col, int legSeconds) {
      final offsets = [-4000.0, -2000, 0, 2000, 4000]; // reaches both feet
      final pts = [
        for (final m in offsets) LatLng(col.latitude + m / _mPerLat, col.longitude),
      ];
      final t0 = DateTime(2026, 6, 1, 10);
      final times = [
        for (var i = 0; i < offsets.length; i++)
          t0.add(Duration(seconds: i * legSeconds)),
      ];
      return RideTrack(rideId: id, points: pts, times: times, speedsMs: const []);
    }

    test('fastestCrossing picks the single fastest pass crossing anywhere', () {
      // Pass A: 4 legs × 100 s = 400 s → 8 km/400 s = 72 km/h.
      // Pass B: 4 legs × 80 s  = 320 s → 8 km/320 s = 90 km/h.  Fastest = B.
      final colA = const LatLng(46.50, 8.40);
      final colB = const LatLng(46.70, 9.00);
      final res = explorePasses(
        [seg('A', colA), seg('B', colB)],
        [rideOver('rA', colA, 100), rideOver('rB', colB, 80)],
      );
      expect(res.stats.fastestCrossing, isNotNull);
      expect(res.stats.fastestCrossing!.pass.name, 'B');
      expect(res.stats.fastestCrossing!.avgSpeedKmh, closeTo(90.0, 0.001));
      expect(res.stats.fastestCrossing!.rideId, 'rB');
      expect(res.stats.fastestCrossing!.movingTimeS, 320);
      expect(res.stats.fastestCrossing!.directionLabel, '↑'); // no connects
      // Total MOVING time on passes = 400 + 320.
      expect(res.stats.totalTimeOnPassesS, 720);
    });

    test('no measurable crossings → fastestCrossing null, total time 0', () {
      final res = explorePasses([_segPass()], const []);
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
