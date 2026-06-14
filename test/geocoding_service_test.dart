// Parsing of Photon GeoJSON responses. Pure/hermetic — no network.
//
// Run: flutter test test/geocoding_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/services/geocoding_service.dart';

const _sample = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": { "type": "Point", "coordinates": [7.4474468, 46.9484742] },
      "properties": {
        "osm_key": "place", "osm_value": "city",
        "name": "Bern", "postcode": "3011", "state": "Bern",
        "country": "Switzerland", "countrycode": "CH"
      }
    },
    {
      "type": "Feature",
      "geometry": { "type": "Point", "coordinates": [8.540192, 47.378177] },
      "properties": {
        "osm_key": "highway", "name": null,
        "street": "Bahnhofstrasse", "housenumber": "1",
        "postcode": "8001", "city": "Zürich", "state": "Zürich",
        "country": "Switzerland"
      }
    },
    {
      "type": "Feature",
      "geometry": { "type": "Point" },
      "properties": { "name": "Broken (no coords)" }
    }
  ]
}
''';

void main() {
  test('parses Photon features, skipping malformed ones', () {
    final places = GeocodingService.parsePhoton(_sample);
    // The third feature has no coordinates and must be dropped.
    expect(places.length, 2);
  });

  test('named place: coordinates and label', () {
    final p = GeocodingService.parsePhoton(_sample).first;
    expect(p.primary, 'Bern');
    expect(p.position.latitude, closeTo(46.9484742, 1e-7));
    expect(p.position.longitude, closeTo(7.4474468, 1e-7));
    // Context trail present, deduped against the primary name.
    expect(p.secondary, contains('3011'));
    expect(p.secondary, contains('Switzerland'));
    expect(p.label, startsWith('Bern, '));
  });

  test('address without a name falls back to street + housenumber', () {
    final p = GeocodingService.parsePhoton(_sample)[1];
    expect(p.primary, 'Bahnhofstrasse 1');
    expect(p.secondary, contains('8001'));
    expect(p.secondary, contains('Zürich'));
  });

  test('empty feature collection yields no places', () {
    final places = GeocodingService.parsePhoton(
        '{"type":"FeatureCollection","features":[]}');
    expect(places, isEmpty);
  });

  test('garbage body throws a GeocodingException', () {
    expect(() => GeocodingService.parsePhoton('not json'),
        throwsA(isA<GeocodingException>()));
  });
}
