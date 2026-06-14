// Nearest-road selection over Overpass `out geom` responses. Pure/hermetic —
// no network.
//
// Run: flutter test test/road_snap_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/road_snap_service.dart';

// Point we want to snap. A close road runs ~111 m north of it; a second road
// sits ~2 km away. 0.0010° latitude ≈ 111 m.
const _p = LatLng(47.0, 8.0);

const _sample = '''
{
  "version": 0.6,
  "elements": [
    {
      "type": "way", "id": 1,
      "geometry": [
        { "lat": 47.0010, "lon": 7.9990 },
        { "lat": 47.0010, "lon": 8.0010 }
      ]
    },
    {
      "type": "way", "id": 2,
      "geometry": [
        { "lat": 47.0200, "lon": 8.0200 },
        { "lat": 47.0200, "lon": 8.0300 }
      ]
    },
    {
      "type": "way", "id": 3,
      "geometry": [ { "lat": 47.0, "lon": 8.0 } ]
    }
  ]
}
''';

void main() {
  test('snaps to the nearest way within radius', () {
    final snapped = RoadSnapService.nearestInBody(_sample, _p, 500);
    expect(snapped, isNotNull);
    // Closest point on the near road: same latitude, projected to our longitude.
    expect(snapped!.latitude, closeTo(47.0010, 1e-6));
    expect(snapped.longitude, closeTo(8.0, 1e-4));
  });

  test('returns null when the nearest road is outside the radius', () {
    // The near road is ~111 m away — a 50 m radius excludes it (and the far one).
    final snapped = RoadSnapService.nearestInBody(_sample, _p, 50);
    expect(snapped, isNull);
  });

  test('ignores ways with fewer than two nodes', () {
    // Only the single-node way (id 3) is present → nothing to snap onto.
    const onlyDegenerate = '''
{ "elements": [ { "type": "way", "id": 3, "geometry": [ { "lat": 47.0, "lon": 8.0 } ] } ] }
''';
    expect(RoadSnapService.nearestInBody(onlyDegenerate, _p, 500), isNull);
  });

  test('empty element list yields no snap', () {
    expect(RoadSnapService.nearestInBody('{"elements":[]}', _p, 500), isNull);
  });

  test('garbage body throws a RoadSnapException', () {
    expect(() => RoadSnapService.nearestInBody('not json', _p, 500),
        throwsA(isA<RoadSnapException>()));
  });
}
