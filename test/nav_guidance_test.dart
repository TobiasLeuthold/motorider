import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:motorider/services/geo.dart';
import 'package:motorider/services/maneuvers.dart';
import 'package:motorider/services/route_navigator.dart';

void main() {
  group('parseVoicehints', () {
    test('parses BRouter voicehints into maneuvers', () {
      final raw = [
        [2, 2, 0, 51, -87], // turn left
        [16, 6, 0, 308, 57], // slight right
        [78, 13, 2, 392, -60], // roundabout, exit 2
        [90, 1, 0, 0, 0], // continue
      ];
      final ms = parseVoicehints(raw);
      expect(ms.length, 4);

      expect(ms[0].geometryIndex, 2);
      expect(ms[0].command, 2);
      expect(ms[0].side, TurnSide.left);
      expect(ms[0].label, 'Links abbiegen');
      expect(ms[0].isTurn, isTrue);

      expect(ms[1].side, TurnSide.right);
      expect(ms[1].label, 'Leicht rechts');

      expect(ms[2].exitNumber, 2);
      expect(ms[2].label, contains('Ausfahrt'));

      expect(ms[3].command, 1);
      expect(ms[3].isTurn, isFalse); // "continue" is not announced
    });

    test('tolerant of junk input', () {
      expect(parseVoicehints(null), isEmpty);
      expect(parseVoicehints('nope'), isEmpty);
      expect(parseVoicehints([1, 2, 3]), isEmpty); // not lists
    });
  });

  group('navZoomForSpeed', () {
    test('clamps at the ends', () {
      expect(navZoomForSpeed(-10), 16.5);
      expect(navZoomForSpeed(0), 16.5);
      expect(navZoomForSpeed(250), 13.1);
    });

    test('interpolates between stops', () {
      expect(navZoomForSpeed(45), closeTo(15.2, 0.05)); // halfway 30->60
    });

    test('monotonically zooms out with speed', () {
      for (var v = 0.0; v < 160; v += 10) {
        expect(navZoomForSpeed(v + 10), lessThanOrEqualTo(navZoomForSpeed(v)));
      }
    });
  });

  group('RouteNavigator next maneuver', () {
    // 11 points heading east, ~77 m apart.
    final geom = [for (var i = 0; i < 11; i++) LatLng(46.0, 8.0 + i * 0.001)];
    final cum = cumulativeMeters(geom);
    final maneuvers = [
      const Maneuver(geometryIndex: 4, command: 5), // right
      const Maneuver(geometryIndex: 8, command: 2), // left
    ];

    test('picks the first turn ahead, then advances past it', () {
      final nav =
          RouteNavigator(geometry: geom, totalDurationS: 600, maneuvers: maneuvers);

      nav.update(NavFix(position: geom[0]));
      final s1 = nav.state;
      expect(s1.nextManeuver?.command, 5); // right
      expect(s1.nextManeuverMeters, closeTo(cum[4], 5));

      nav.update(NavFix(position: geom[5])); // now past the first turn
      final s2 = nav.state;
      expect(s2.nextManeuver?.command, 2); // left
      expect(s2.nextManeuverMeters, closeTo(cum[8] - cum[5], 5));
    });

    test('no maneuvers → null next turn', () {
      final nav = RouteNavigator(geometry: geom, totalDurationS: 600);
      nav.update(NavFix(position: geom[0]));
      expect(nav.state.nextManeuver, isNull);
    });

    test('course follows the route bearing on-route (heading-up)', () {
      // geom heads due east (lon increasing) → bearing ~90°.
      final nav = RouteNavigator(geometry: geom, totalDurationS: 600);
      nav.update(NavFix(position: geom[2]));
      expect(nav.state.courseDeg, isNotNull);
      expect(nav.state.courseDeg!, closeTo(90, 5));
    });
  });

  group('RouteNavigator arrival', () {
    // A square loop whose finish coincides with its start: A→B(E)→C(N)→D(W)→A.
    // Densely sampled so stepping along it never jumps more than the navigator's
    // believable-advance cap. Start ≈ finish, so this is the round-trip trap.
    List<LatLng> loopRoute() {
      final corners = <LatLng>[
        const LatLng(46.0000, 8.0000), // A (start == finish)
        const LatLng(46.0000, 8.0100), // B east  (~770 m)
        const LatLng(46.0100, 8.0100), // C north (~1110 m)
        const LatLng(46.0100, 8.0000), // D west  (~770 m)
        const LatLng(46.0000, 8.0000), // back to A
      ];
      return _densify(corners, stepM: 25);
    }

    test('does NOT arrive at the start of a round trip', () {
      final route = loopRoute();
      final nav = RouteNavigator(
        geometry: route,
        totalDurationS: 600,
        arriveRadiusM: 60,
      );

      // First fixes are AT / just off the start. Because start ≈ finish, the
      // snap can land on the route's final segment (remaining ≈ 0) — the exact
      // condition that used to fire arrival instantly.
      nav.update(NavFix(position: route.first));
      expect(nav.state.arrived, isFalse, reason: 'arrived at the start vertex');

      // A touch of GPS jitter that snaps onto the closing segment near the end.
      nav.update(const NavFix(position: LatLng(46.00005, 8.00002)));
      expect(nav.state.arrived, isFalse,
          reason: 'jitter near the closing segment faked arrival');

      // A few more fixes leaving the start heading east — still nowhere near done.
      final cum = cumulativeMeters(route);
      for (final d in [30.0, 80.0, 150.0, 300.0]) {
        nav.update(NavFix(position: _pointAlong(route, cum, d)));
        expect(nav.state.arrived, isFalse,
            reason: 'arrived only $d m into the loop');
      }
    });

    test('arrives after actually traversing the whole round trip', () {
      final route = loopRoute();
      final nav = RouteNavigator(
        geometry: route,
        totalDurationS: 600,
        arriveRadiusM: 60,
      );

      var everArrivedEarly = false;
      var arrivedNearEnd = false;
      final cum = cumulativeMeters(route);
      final total = cum.last;
      for (var d = 0.0; d <= total; d += 40) {
        nav.update(NavFix(position: _pointAlong(route, cum, d)));
        // Must not arrive before the rider is genuinely near the end.
        if (d < total - 100 && nav.state.arrived) everArrivedEarly = true;
        if (d >= total - 100 && nav.state.arrived) arrivedNearEnd = true;
      }
      nav.update(NavFix(position: route.last));

      expect(everArrivedEarly, isFalse,
          reason: 'arrival fired before completing the loop');
      expect(arrivedNearEnd, isTrue,
          reason: 'never arrived while approaching the finish');
      // Sticky: the spatially-ambiguous closing fix must not un-arrive.
      expect(nav.state.arrived, isTrue,
          reason: 'arrival flipped off at the round-trip finish');
    });

    test('straight A→B route arrives only at B', () {
      // ~3 km dead-straight line, densely sampled.
      final line = _densify(
        [const LatLng(46.0, 8.0), const LatLng(46.0, 8.040)],
        stepM: 25,
      );
      final nav = RouteNavigator(
        geometry: line,
        totalDurationS: 400,
        arriveRadiusM: 60,
      );

      final cum = cumulativeMeters(line);
      final total = cum.last;
      // Not arrived anywhere short of the radius from B.
      for (var d = 0.0; d < total - 80; d += 40) {
        nav.update(NavFix(position: _pointAlong(line, cum, d)));
        expect(nav.state.arrived, isFalse, reason: 'arrived $d m in');
      }
      // Arrives at the end.
      nav.update(NavFix(position: line.last));
      expect(nav.state.arrived, isTrue);
    });

    test('lead-in: passing through the planned start is NOT arrival', () {
      // Lead-in connector (current → planned start) stitched in front of a
      // straight planned route. The planned START sits in the MIDDLE of the
      // joined geometry; reaching it must not count as arrival — only the true
      // final destination at the end does.
      final leadIn = _densify(
        [const LatLng(45.99, 8.0), const LatLng(46.0, 8.0)],
        stepM: 25,
      );
      final planned = _densify(
        [const LatLng(46.0, 8.0), const LatLng(46.01, 8.0)],
        stepM: 25,
      );
      final joined = <LatLng>[...leadIn, ...planned.skip(1)];
      final nav = RouteNavigator(
        geometry: joined,
        totalDurationS: 500,
        arriveRadiusM: 60,
      );

      final plannedStart = const LatLng(46.0, 8.0);
      final cum = cumulativeMeters(joined);
      final total = cum.last;
      var arrivedAtPlannedStart = false;
      for (var d = 0.0; d <= total; d += 40) {
        final p = _pointAlong(joined, cum, d);
        nav.update(NavFix(position: p));
        if (haversineMeters(p, plannedStart) < 30 && nav.state.arrived) {
          arrivedAtPlannedStart = true;
        }
      }
      nav.update(NavFix(position: joined.last));

      expect(arrivedAtPlannedStart, isFalse,
          reason: 'announced arrival at the planned start (mid-route)');
      expect(nav.state.arrived, isTrue,
          reason: 'never arrived at the true destination');
    });

    test('progress mark cannot be faked by an early jump to the end', () {
      // Feed ONLY fixes near the finish vertex of a loop from the very first
      // update. The per-fix advance cap must keep arrival disarmed because the
      // rider never actually progressed there.
      final route = loopRoute();
      final nav = RouteNavigator(
        geometry: route,
        totalDurationS: 600,
        arriveRadiusM: 60,
      );
      // The penultimate vertex sits near the start/finish corner; hammering it
      // should not arm arrival without real progress through the loop.
      for (var i = 0; i < 5; i++) {
        nav.update(const NavFix(position: LatLng(46.00003, 8.00001)));
        expect(nav.state.arrived, isFalse);
      }
    });
  });
}

/// Subdivide a polyline so consecutive points are at most [stepM] apart — a
/// stand-in for a routed line dense enough to step a rider along smoothly.
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
