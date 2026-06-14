// Verifies the sync merge never wipes a fuel stop's location: a location, once
// present locally, must survive a pull of a newer server record that arrives
// without one (the reinstall/old-client clobber the user hit). Other fields of
// the newer record still win as usual.
//
// Run: flutter test test/sync_location_preserve_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/database.dart';
import 'package:motorider/data/fillup_repository.dart';
import 'package:motorider/models/fillup.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  final t0 = DateTime(2026, 1, 1, 10);

  FillUp located({
    DateTime? updatedAt,
    double totalChf = 20,
    double? lat = 47.1,
    double? lon = 8.2,
  }) =>
      FillUp(
        id: 'fx1',
        date: t0,
        odometerKm: 1000,
        liters: 10,
        totalChf: totalChf,
        latitude: lat,
        longitude: lon,
        updatedAt: updatedAt ?? t0,
        syncState: SyncState.synced,
      );

  test('a newer server record WITHOUT a location keeps the existing location',
      () async {
    final repo = FillUpRepository(AppDatabase.instance);

    // Local row already has coordinates (as if previously synced).
    await repo.applyServerRecord(located());

    // Server sends a strictly-newer copy that lost its location, but changed
    // another field — the classic old-client / regressed-row case.
    final newerNoLoc = FillUp(
      id: 'fx1',
      date: t0,
      odometerKm: 1000,
      liters: 10,
      totalChf: 25,
      // latitude/longitude intentionally omitted -> null
      updatedAt: t0.add(const Duration(hours: 1)),
      syncState: SyncState.synced,
    );
    final changed = await repo.applyServerRecord(newerNoLoc);

    expect(changed, isTrue);
    final merged = (await repo.getAll()).firstWhere((f) => f.id == 'fx1');
    expect(merged.latitude, 47.1, reason: 'location must be preserved');
    expect(merged.longitude, 8.2, reason: 'location must be preserved');
    expect(merged.totalChf, 25, reason: 'other newer fields still win');
  });

  test('a newer server record WITH a location still updates the location',
      () async {
    final repo = FillUpRepository(AppDatabase.instance);
    await repo.applyServerRecord(located());

    final newerMoved = located(
      updatedAt: t0.add(const Duration(hours: 1)),
      lat: 46.0,
      lon: 7.0,
    );
    await repo.applyServerRecord(newerMoved);

    final merged = (await repo.getAll()).firstWhere((f) => f.id == 'fx1');
    expect(merged.latitude, 46.0);
    expect(merged.longitude, 7.0);
  });

  test('a located server record restores into an empty db (reinstall)',
      () async {
    final repo = FillUpRepository(AppDatabase.instance);
    await repo.applyServerRecord(located());

    final merged = (await repo.getAll()).firstWhere((f) => f.id == 'fx1');
    expect(merged.latitude, 47.1);
    expect(merged.longitude, 8.2);
  });
}
