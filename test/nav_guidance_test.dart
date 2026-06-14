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
}
