// Guards against the "missing NAS column" class of data-loss bug: PocketBase
// silently DROPS unknown fields on create/update, so any field the app sends
// in toPocketBaseJson() that has no matching column in the NAS migrations is
// lost on the round-trip (and wiped on the next pull / after a reinstall).
//
// This test cross-checks every wire field the app emits against the union of
// field names declared across nas/pb_migrations/*.js. If you add a field to a
// model's toPocketBaseJson(), you must also add a column via a new migration —
// or this test fails.
//
// Run: flutter test test/nas_schema_completeness_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motorider/models/fillup.dart';
import 'package:motorider/models/ride.dart';

void main() {
  // Every distinct `name: "..."` declared anywhere in the migration files.
  // Spans collections and field definitions — fine, we only assert presence.
  Set<String> migrationNames() {
    final dir = Directory('nas/pb_migrations');
    expect(dir.existsSync(), isTrue,
        reason: 'nas/pb_migrations should exist (run from project root)');
    final re = RegExp(r'name:\s*"([^"]+)"');
    final names = <String>{};
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.js')) continue;
      for (final m in re.allMatches(f.readAsStringSync())) {
        names.add(m.group(1)!);
      }
    }
    return names;
  }

  // A fillup with every optional field populated, so toPocketBaseJson emits
  // the full set of keys.
  final fullFillUp = FillUp(
    id: 'x',
    date: DateTime.utc(2026, 1, 1),
    odometerKm: 1,
    liters: 1,
    totalChf: 1,
    latitude: 1,
    longitude: 1,
    station: 's',
    notes: 'n',
    deletedAt: DateTime.utc(2026, 1, 2),
  );

  // A ride with every optional field (incl. weather) populated.
  final fullRide = Ride(
    id: 'x',
    startedAt: DateTime.utc(2026, 1, 1),
    endedAt: DateTime.utc(2026, 1, 1, 1),
    distanceKm: 1,
    elevationGainM: 1,
    title: 't',
    notes: 'n',
    tempMinC: 1,
    tempMaxC: 2,
    tempAvgC: 1.5,
    precipitationMm: 0,
    windMaxKmh: 3,
    weatherCode: 1,
    weatherFetchedAt: DateTime.utc(2026, 1, 1, 2),
    deletedAt: DateTime.utc(2026, 1, 3),
  );

  test('every fillup wire field has a NAS column', () {
    final names = migrationNames();
    final missing = fullFillUp.toPocketBaseJson().keys
        .where((k) => !names.contains(k))
        .toList();
    expect(missing, isEmpty,
        reason: 'fillup fields with no NAS column would be silently dropped: '
            '$missing');
  });

  test('every ride wire field has a NAS column', () {
    final names = migrationNames();
    final missing = fullRide.toPocketBaseJson(pointsJson: '[]').keys
        .where((k) => !names.contains(k))
        .toList();
    expect(missing, isEmpty,
        reason: 'ride fields with no NAS column would be silently dropped: '
            '$missing');
  });
}
