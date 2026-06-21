import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:motorider/services/geo.dart';
import 'package:motorider/services/route_navigator.dart';

/// A ~3 km dead-straight line heading due east at latitude 46, densely sampled
/// so snapping/stepping along it is smooth.
List<LatLng> _line() => _densify(
      [const LatLng(46.0, 8.0), const LatLng(46.0, 8.040)],
      stepM: 25,
    );

void main() {
  group('RouteNavigator dead reckoning (coast)', () {
    test('coasts the puck forward at the last known speed while GPS is silent',
        () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(geometry: line, totalDurationS: 300);

      // One real fix at 200 m in, moving 72 km/h (= 20 m/s).
      nav.update(NavFix(position: _pointAlong(line, cum, 200), speedKmh: 72));
      expect(nav.state.estimated, isFalse);
      final startAlong = nav.state.alongMeters;
      expect(startAlong, closeTo(200, 5));

      // GPS goes quiet: ten 1 s coast ticks should advance ~200 m (20 m/s·10 s).
      for (var i = 0; i < 10; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      expect(nav.state.estimated, isTrue);
      expect(nav.state.alongMeters, closeTo(startAlong + 200, 5));
      expect(nav.state.remainingMeters, lessThan(cum.last - startAlong - 150));
      // The estimated point really moved east along the line.
      expect(nav.state.snapped!.longitude, greaterThan(8.0));
    });

    test('does not invent motion when the rider was stopped', () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(geometry: line, totalDurationS: 300);

      // Stopped at a light / tunnel mouth: last speed below the coast floor.
      nav.update(NavFix(position: _pointAlong(line, cum, 200), speedKmh: 1));
      final along = nav.state.alongMeters;

      for (var i = 0; i < 10; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      // No estimated emission — the puck holds its position.
      expect(nav.state.estimated, isFalse);
      expect(nav.state.alongMeters, closeTo(along, 0.001));
    });

    test('a returning real fix clears the estimate and snaps back to truth', () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(geometry: line, totalDurationS: 300);

      nav.update(NavFix(position: _pointAlong(line, cum, 200), speedKmh: 72));
      for (var i = 0; i < 5; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      expect(nav.state.estimated, isTrue);

      // GPS reacquires at 260 m. The estimate must give way to the real fix.
      nav.update(NavFix(position: _pointAlong(line, cum, 260), speedKmh: 72));
      expect(nav.state.estimated, isFalse);
      expect(nav.state.alongMeters, closeTo(260, 5));
    });

    test('never coasts off-route', () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(geometry: line, totalDurationS: 300);

      // Three fixes ~80 m north of the east-west line trip the off-route streak.
      const offsetDeg = 80 / 111320.0; // ~80 m of latitude
      for (var i = 0; i < 3; i++) {
        final on = _pointAlong(line, cum, 200 + i * 5);
        nav.update(NavFix(
          position: LatLng(on.latitude + offsetDeg, on.longitude),
          speedKmh: 72,
        ));
      }
      expect(nav.state.offRoute, isTrue);

      for (var i = 0; i < 10; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      // Off-route, the route line isn't where the rider is, so we must not coast.
      expect(nav.state.estimated, isFalse);
      expect(nav.state.offRoute, isTrue);
    });

    test('coasting alone never fires arrival', () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(
        geometry: line,
        totalDurationS: 300,
        arriveRadiusM: 60,
      );

      // Real fix ~150 m before the end, moving fast.
      nav.update(NavFix(
        position: _pointAlong(line, cum, cum.last - 150),
        speedKmh: 108, // 30 m/s
      ));
      // Coast well past the finish line.
      for (var i = 0; i < 20; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      expect(nav.state.alongMeters, closeTo(cum.last, 1));
      // Only a real fix may end the tour — an estimate must not.
      expect(nav.state.arrived, isFalse);
    });

    test('bounds the blind drift at coastMaxSeconds', () {
      final line = _line();
      final cum = cumulativeMeters(line);
      final nav = RouteNavigator(
        geometry: line,
        totalDurationS: 300,
        coastMaxSeconds: 5, // stop extrapolating after 5 s
      );

      nav.update(NavFix(position: _pointAlong(line, cum, 100), speedKmh: 72));
      final start = nav.state.alongMeters;
      for (var i = 0; i < 20; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      // Advanced only for the first ~5 s (20 m/s · 5 s = 100 m), then frozen.
      expect(nav.state.alongMeters, closeTo(start + 100, 5));
    });

    test('coasting past the snap window does not teleport onto the parallel '
        'outbound carriageway', () {
      // An out-and-back where the return runs on the opposite carriageway, ~11 m
      // north of (and parallel to) the outbound — the everyday case of riding a
      // road out and back. Drive onto the return leg, coast through a tunnel
      // longer than the 350 m forward snap window, then a returning fix that GPS
      // noise has nudged onto the OUTBOUND line (a few metres of lane error).
      // Progress must stay on the return leg. Regression: coast used to leave the
      // snap anchor frozen at the tunnel entrance, so the far-off returning fix
      // forced an occurrence-blind global re-acquire that jumped to the outbound
      // pass (which the noisy fix sits exactly on).
      final route = _densify(const [
        LatLng(46.00000, 8.00), // A   outbound (lat 46.00000)
        LatLng(46.00000, 8.06), // T   turnaround (~4638 m)
        LatLng(46.00010, 8.06), // T'  jog ~11 m north onto the return lane
        LatLng(46.00010, 8.00), // A'  return, parallel ~11 m north of outbound
      ], stepM: 25);
      final cum = cumulativeMeters(route);
      final nav = RouteNavigator(geometry: route, totalDurationS: 900);

      // Drive from the start, through the turnaround, onto the return leg.
      for (var d = 0.0; d <= 5000; d += 40) {
        nav.update(NavFix(position: _pointAlong(route, cum, d), speedKmh: 108));
      }
      expect(nav.state.alongMeters, closeTo(5000, 150),
          reason: 'failed to track onto the return leg');

      // Tunnel: GPS silent. Coast 20 s at 30 m/s ≈ 600 m — past the 350 m window.
      for (var i = 0; i < 20; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      expect(nav.state.estimated, isTrue);
      expect(nav.state.alongMeters, closeTo(5600, 80),
          reason: 'coast did not advance the estimate along the return leg');

      // GPS returns at the exit, but ~11 m off — laterally onto the outbound
      // line (same longitude, outbound latitude).
      final trueExit = _pointAlong(route, cum, 5600);
      final noisyFix = LatLng(46.00000, trueExit.longitude);
      nav.update(NavFix(position: noisyFix, speedKmh: 108));

      expect(nav.state.estimated, isFalse);
      expect(nav.state.alongMeters, greaterThan(5000),
          reason: 'returning fix teleported backward onto the outbound leg');
      expect(nav.state.alongMeters, closeTo(5600, 150),
          reason: 'returning fix was not matched at the true exit');
    });

    test('recovers and completes the route after a long tunnel on a '
        'self-crossing route', () {
      // Same offset out-and-back: a lane-crossing fix on tunnel exit must not
      // strand progress on the outbound leg. Without the anchor sync that fix
      // teleports onto the outbound carriageway and then mirrors backward
      // (subsequent return fixes stay closer to the nearby outbound line than
      // the out-of-window return leg), so the ride never reaches the finish.
      final route = _densify(const [
        LatLng(46.00000, 8.00),
        LatLng(46.00000, 8.06),
        LatLng(46.00010, 8.06),
        LatLng(46.00010, 8.00),
      ], stepM: 25);
      final cum = cumulativeMeters(route);
      final total = cum.last;
      final nav = RouteNavigator(
        geometry: route,
        totalDurationS: 900,
        arriveRadiusM: 60,
      );

      for (var d = 0.0; d <= 5000; d += 40) {
        nav.update(NavFix(position: _pointAlong(route, cum, d), speedKmh: 108));
      }
      for (var i = 0; i < 20; i++) {
        nav.coast(const Duration(seconds: 1));
      }
      // Lane-crossing fix at tunnel exit, then clean return fixes to the finish.
      final trueExit = _pointAlong(route, cum, 5600);
      nav.update(NavFix(
          position: LatLng(46.00000, trueExit.longitude), speedKmh: 108));
      for (var d = 5640.0; d <= total; d += 40) {
        nav.update(NavFix(position: _pointAlong(route, cum, d), speedKmh: 108));
      }
      nav.update(NavFix(position: route.last, speedKmh: 108));

      expect(nav.state.alongMeters, closeTo(total, 100),
          reason: 'progress never recovered to the finish after the tunnel');
      expect(nav.state.arrived, isTrue,
          reason: 'arrival never fired after the tunnel');
    });
  });
}

/// Subdivide a polyline so consecutive points are at most [stepM] apart.
List<LatLng> _densify(List<LatLng> coarse, {double stepM = 25}) {
  final out = <LatLng>[coarse.first];
  for (var i = 1; i < coarse.length; i++) {
    final a = coarse[i - 1], b = coarse[i];
    final segLen = haversineMeters(a, b);
    final n = (segLen / stepM).ceil().clamp(1, 100000);
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      out.add(LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      ));
    }
  }
  return out;
}

/// Point [d] metres along [route] (with precomputed [cum]), clamped to its ends.
LatLng _pointAlong(List<LatLng> route, List<double> cum, double d) {
  final total = cum.last;
  if (d <= 0) return route.first;
  if (d >= total) return route.last;
  var i = 1;
  while (i < cum.length - 1 && cum[i] < d) {
    i++;
  }
  final segLen = cum[i] - cum[i - 1];
  final t = segLen == 0 ? 0.0 : (d - cum[i - 1]) / segLen;
  final a = route[i - 1], b = route[i];
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );
}
