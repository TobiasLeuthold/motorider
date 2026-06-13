import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorider/models/curviness.dart';
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
}
