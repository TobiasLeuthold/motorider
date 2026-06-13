// FillUp <-> PocketBase JSON edge cases.
//
// Run: flutter test test/fillup_json_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/models/fillup.dart';

Map<String, Object?> base(Map<String, Object?> overrides) => {
      'client_id': 'csv-1',
      'date_iso': '2026-01-01T10:00:00.000',
      'odometer_km': 100,
      'liters': 10,
      'total_chf': 20,
      'full_tank': true,
      'updated_at': '2026-01-01T10:00:00.000',
      ...overrides,
    };

void main() {
  test('(0,0) from the server is read as "no location"', () {
    // PocketBase returns 0 for an unset number field; that must NOT become a
    // real coordinate locally.
    final f = FillUp.fromPocketBaseJson(base({'latitude': 0, 'longitude': 0}));
    expect(f.latitude, isNull);
    expect(f.longitude, isNull);
  });

  test('a real location round-trips unchanged', () {
    final f = FillUp.fromPocketBaseJson(
        base({'latitude': 46.94809, 'longitude': 7.44744, 'station': 'Bern'}));
    expect(f.latitude, closeTo(46.94809, 1e-9));
    expect(f.longitude, closeTo(7.44744, 1e-9));
    expect(f.station, 'Bern');
  });

  test('a missing location stays null', () {
    final f = FillUp.fromPocketBaseJson(base({}));
    expect(f.latitude, isNull);
    expect(f.longitude, isNull);
  });
}
