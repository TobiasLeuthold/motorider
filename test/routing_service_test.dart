import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorider/models/curviness.dart';
import 'package:motorider/services/geo.dart';
import 'package:motorider/services/maneuvers.dart';
import 'package:motorider/services/routing_service.dart';
import 'package:latlong2/latlong.dart';

/// Builds a minimal BRouter-shaped GeoJSON body.
String geojson({
  required List<List<double>> lonLatElev,
  required int trackLength,
  required int totalTime,
  required int ascend,
}) {
  final coords = lonLatElev
      .map((c) => '[${c[0]}, ${c[1]}, ${c[2]}]')
      .join(', ');
  return '''
{ "type": "FeatureCollection",
  "features": [
    { "type": "Feature",
      "properties": {
        "track-length": "$trackLength",
        "total-time": "$totalTime",
        "filtered ascend": "$ascend"
      },
      "geometry": { "type": "LineString", "coordinates": [$coords] }
    }
  ]
}''';
}

void main() {
  test('parses BRouter GeoJSON into a RouteResult', () async {
    final client = MockClient((req) async {
      return http.Response(
        geojson(
          lonLatElev: [
            [8.0, 46.0, 500],
            [8.0, 46.01, 520],
            [8.0, 46.02, 540],
          ],
          trackLength: 2226,
          totalTime: 180,
          ascend: 40,
        ),
        200,
      );
    });
    final svc = RoutingService(client: client);
    final r = await svc.route(
      waypoints: const [LatLng(46.0, 8.0), LatLng(46.02, 8.0)],
      curviness: Curviness.fast,
    );
    expect(r.geometry.length, 3);
    expect(r.geometry.first, const LatLng(46.0, 8.0)); // lat/lon swap correct
    expect(r.distanceM, 2226);
    expect(r.durationS, 180);
    expect(r.ascentM, 40);
  });

  test('throws a friendly RoutingException on a plain-text error body',
      () async {
    final client = MockClient((req) async {
      return http.Response('no track found, position not mapped', 200);
    });
    final svc = RoutingService(client: client);
    expect(
      () => svc.route(
        waypoints: const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
        curviness: Curviness.balanced,
      ),
      throwsA(isA<RoutingException>()),
    );
  });

  test('curvy level keeps the curviest alternative', () async {
    // idx 0 → straight line (low curviness); idx 1+ → zigzag (high curviness).
    final client = MockClient((req) async {
      final idx = req.url.queryParameters['alternativeidx'] ?? '0';
      if (idx == '0') {
        return http.Response(
          geojson(
            lonLatElev: [
              for (var i = 0; i < 8; i++) [8.0, 46.0 + i * 0.01, 500],
            ],
            trackLength: 8000,
            totalTime: 600,
            ascend: 10,
          ),
          200,
        );
      }
      return http.Response(
        geojson(
          lonLatElev: [
            for (var i = 0; i < 8; i++)
              [8.0 + (i.isEven ? 0.0 : 0.01), 46.0 + i * 0.01, 500],
          ],
          trackLength: 9000,
          totalTime: 700,
          ascend: 30,
        ),
        200,
      );
    });
    final svc = RoutingService(client: client);
    final r = await svc.route(
      waypoints: const [LatLng(46.0, 8.0), LatLng(46.07, 8.0)],
      curviness: Curviness.curvy, // requests 3 alternatives
    );
    // Must have chosen the zigzag alternative.
    expect(r.distanceM, 9000);
    expect(r.curviness, greaterThan(30));
  });

  group('concatRouteLegs', () {
    RouteResult leg(
      List<LatLng> geometry, {
      required double distanceM,
      required int durationS,
      double? ascentM,
      String profile = 'car-eco',
      List<Maneuver> maneuvers = const [],
    }) =>
        RouteResult(
          geometry: geometry,
          distanceM: distanceM,
          durationS: durationS,
          ascentM: ascentM,
          curviness: curvinessScore(geometry),
          profile: profile,
          maneuvers: maneuvers,
        );

    test('joins geometry dropping the shared node and sums the stats', () {
      final leg0 = leg(
        const [LatLng(46.0, 8.0), LatLng(46.1, 8.0), LatLng(46.2, 8.05)],
        distanceM: 1000,
        durationS: 100,
        ascentM: 10,
        profile: 'car-fast',
      );
      final leg1 = leg(
        // First point equals leg0's last point — the shared waypoint node.
        const [LatLng(46.2, 8.05), LatLng(46.3, 8.2), LatLng(46.4, 8.1)],
        distanceM: 2000,
        durationS: 200,
        ascentM: 20,
        profile: 'moped',
      );

      final r = concatRouteLegs([leg0, leg1]);

      // Shared node appears once → 5 points, not 6.
      expect(r.geometry, const [
        LatLng(46.0, 8.0),
        LatLng(46.1, 8.0),
        LatLng(46.2, 8.05),
        LatLng(46.3, 8.2),
        LatLng(46.4, 8.1),
      ]);
      expect(r.distanceM, 3000);
      expect(r.durationS, 300);
      expect(r.ascentM, 30);
      // Mixed profiles collapse to 'mixed'.
      expect(r.profile, 'mixed');
      // Overall curviness is recomputed from the joined line, not averaged.
      expect(r.curviness, closeTo(curvinessScore(r.geometry), 1e-9));
    });

    test('offsets each leg maneuver index by the running joined length', () {
      final leg0 = leg(
        const [LatLng(46.0, 8.0), LatLng(46.1, 8.0), LatLng(46.2, 8.0)],
        distanceM: 1000,
        durationS: 100,
        maneuvers: const [Maneuver(geometryIndex: 1, command: 2)], // left at B
      );
      final leg1 = leg(
        const [LatLng(46.2, 8.0), LatLng(46.3, 8.0), LatLng(46.4, 8.0)],
        distanceM: 1000,
        durationS: 100,
        maneuvers: const [
          Maneuver(geometryIndex: 0, command: 1), // at the shared node
          Maneuver(geometryIndex: 1, command: 5), // right at D
        ],
      );
      final leg2 = leg(
        const [LatLng(46.4, 8.0), LatLng(46.5, 8.0)],
        distanceM: 1000,
        durationS: 100,
        maneuvers: const [Maneuver(geometryIndex: 1, command: 7)], // sharp-right
      );

      final r = concatRouteLegs([leg0, leg1, leg2]);

      // Joined geometry: [A,B,C, D,E, F] = 6 points (two shared nodes dropped).
      expect(r.geometry.length, 6);
      final idx = r.maneuvers.map((m) => m.geometryIndex).toList();
      // leg0: 1 stays 1. leg1 base=3 → 3-1+0=2 (shared node C), 3-1+1=3 (D).
      // leg2 base=5 → 5-1+1=5 (F).
      expect(idx, [1, 2, 3, 5]);
      // Each maneuver still points at a real vertex of the joined line.
      for (final m in r.maneuvers) {
        expect(m.geometryIndex, inInclusiveRange(0, r.geometry.length - 1));
      }
      // Commands preserved in order.
      expect(r.maneuvers.map((m) => m.command).toList(), [2, 1, 5, 7]);
    });

    test('single leg is returned unchanged', () {
      final only = leg(
        const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
        distanceM: 500,
        durationS: 50,
        profile: 'car-fast',
      );
      final r = concatRouteLegs([only]);
      expect(identical(r, only), isTrue);
    });

    test('uniform profile is kept (not forced to mixed)', () {
      final a = leg(const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
          distanceM: 1, durationS: 1, profile: 'car-eco');
      final b = leg(const [LatLng(46.1, 8.0), LatLng(46.2, 8.0)],
          distanceM: 1, durationS: 1, profile: 'car-eco');
      expect(concatRouteLegs([a, b]).profile, 'car-eco');
    });
  });

  test('routeLegs routes each leg with its own curviness profile', () async {
    // 3 waypoints → 2 legs. Leg 0 = fast (car-fast), leg 1 = extra (moped).
    final seenProfiles = <String>[];
    final client = MockClient((req) async {
      final profile = req.url.queryParameters['profile']!;
      seenProfiles.add(profile);
      // Distinct geometry per profile so we can tell the legs apart.
      final lat = profile == 'car-fast' ? 46.0 : 46.5;
      return http.Response(
        geojson(
          lonLatElev: [
            [8.0, lat, 500],
            [8.0, lat + 0.05, 510],
          ],
          trackLength: profile == 'car-fast' ? 3000 : 7000,
          totalTime: 300,
          ascend: 10,
        ),
        200,
      );
    });
    final svc = RoutingService(client: client);
    final legs = await svc.routeLegs(
      waypoints: const [
        LatLng(46.0, 8.0),
        LatLng(46.2, 8.0),
        LatLng(46.4, 8.0),
      ],
      legCurviness: const [Curviness.fast, Curviness.extra],
    );
    expect(legs.length, 2);
    expect(seenProfiles.toSet(), {'car-fast', 'moped'});
    // routePerLeg fuses them: distances sum, shared node dropped.
    final combined = concatRouteLegs(legs);
    expect(combined.distanceM, 10000);
    expect(combined.geometry.length, 3); // 2 + 2 - 1 shared
  });

  test('routeLegs rejects a mismatched legCurviness length', () {
    final svc = RoutingService(client: MockClient((_) async {
      return http.Response('{}', 200);
    }));
    expect(
      () => svc.routeLegs(
        waypoints: const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
        legCurviness: const [Curviness.fast, Curviness.curvy], // too many
      ),
      throwsA(isA<RoutingException>()),
    );
  });

  test('retries a transient HTTP 400 and then succeeds', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls == 1) return http.Response('busy', 400); // transient frontend
      return http.Response(
        geojson(
          lonLatElev: const [
            [8.0, 46.0, 500],
            [8.0, 46.02, 520],
          ],
          trackLength: 1500,
          totalTime: 120,
          ascend: 10,
        ),
        200,
      );
    });
    final svc = RoutingService(client: client);
    final r = await svc.route(
      waypoints: const [LatLng(46.0, 8.0), LatLng(46.02, 8.0)],
      curviness: Curviness.fast, // a single request → easy to count retries
    );
    expect(calls, 2); // one retry
    expect(r.distanceM, 1500);
  });

  test('surfaces a RoutingException after exhausting retries', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('still busy', 429);
    });
    final svc = RoutingService(client: client);
    await expectLater(
      svc.route(
        waypoints: const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
        curviness: Curviness.fast,
      ),
      throwsA(isA<RoutingException>()),
    );
    expect(calls, 3); // 1 initial + 2 retries
  });

  test('does not retry a 200 plain-text "no route" body', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('no track found, position not mapped', 200);
    });
    final svc = RoutingService(client: client);
    await expectLater(
      svc.route(
        waypoints: const [LatLng(46.0, 8.0), LatLng(46.1, 8.0)],
        curviness: Curviness.fast,
      ),
      throwsA(isA<RoutingException>()),
    );
    expect(calls, 1); // a permanent routing error is not retried
  });
}
