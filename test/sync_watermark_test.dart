// Regression tests for the shared pull high-water mark (lastPullTs).
//
// Two bugs this guards against:
//   1. _pullFillups computed a high-water timestamp but never persisted it —
//      only _pullRides moved the watermark. A fillup changed on the NAS could
//      therefore stop advancing the mark, and a `DateTime.now()` fallback in
//      _pullRides could jump the mark PAST a server edit (client clock skew),
//      permanently skipping it on later pulls.
//   2. The watermark must track server-sourced timestamps, never the local
//      clock.
//
// Run: flutter test test/sync_watermark_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/database.dart';
import 'package:motorider/data/fillup_repository.dart';
import 'package:motorider/data/ride_repository.dart';
import 'package:motorider/models/fillup.dart';
import 'package:motorider/services/nas_settings.dart';
import 'package:motorider/services/sync_service.dart';

import 'fake_pocketbase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
    SharedPreferences.setMockInitialValues({
      'nas.email': 'test@local',
      'nas.password': 'secret',
    });
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  // Put a fillup straight onto the fake "NAS" (as if added via the web UI or
  // another device), with a chosen server-side updated_at.
  Future<void> putOnServer(FakePocketBase server, FillUp f) async {
    await server.createRecord('fillups', f.toPocketBaseJson());
  }

  test('a fillup-only change advances the watermark to the server timestamp',
      () async {
    final server = FakePocketBase();
    final fillRepo = FillUpRepository(AppDatabase.instance);
    final rideRepo = RideRepository(AppDatabase.instance);
    final settings = await NasSettings.load();
    final sync = SyncService(fillRepo, rideRepo, settings,
        backend: server, autoSync: false);

    final t1 = DateTime.utc(2026, 6, 10, 12, 0, 0);
    await putOnServer(
      server,
      FillUp(
        id: 'remote-1',
        date: DateTime.utc(2026, 6, 10),
        odometerKm: 1000,
        liters: 10,
        totalChf: 20,
        latitude: 46.9,
        longitude: 7.4,
        station: 'NAS Station',
        updatedAt: t1,
      ),
    );

    final r1 = await sync.syncOnce();
    expect(r1.ok, isTrue, reason: r1.error);

    // The NAS record (with location) was pulled in...
    final local = (await fillRepo.getAll()).firstWhere((f) => f.id == 'remote-1');
    expect(local.station, 'NAS Station');
    // ...and the watermark advanced to the SERVER timestamp, not now().
    // (No rides were involved, so the old code would have jumped to now().)
    expect(settings.lastPullTs, t1,
        reason: 'watermark must be the observed server updated_at, not the '
            'local clock — and fillups alone must advance it');

    await sync.dispose();
  });

  test('a later NAS edit is pulled incrementally after the watermark', () async {
    final server = FakePocketBase();
    final fillRepo = FillUpRepository(AppDatabase.instance);
    final rideRepo = RideRepository(AppDatabase.instance);
    final settings = await NasSettings.load();
    final sync = SyncService(fillRepo, rideRepo, settings,
        backend: server, autoSync: false);

    final t1 = DateTime.utc(2026, 6, 10, 12, 0, 0);
    await putOnServer(
      server,
      FillUp(
        id: 'remote-1',
        date: DateTime.utc(2026, 6, 10),
        odometerKm: 1000,
        liters: 10,
        totalChf: 20,
        updatedAt: t1,
      ),
    );
    await sync.syncOnce();
    expect(settings.lastPullTs, t1);

    // A second NAS record appears with a newer timestamp.
    final t2 = DateTime.utc(2026, 6, 11, 8, 30, 0);
    await putOnServer(
      server,
      FillUp(
        id: 'remote-2',
        date: DateTime.utc(2026, 6, 11),
        odometerKm: 1100,
        liters: 11,
        totalChf: 22,
        station: 'Second NAS Station',
        updatedAt: t2,
      ),
    );

    final r2 = await sync.syncOnce();
    expect(r2.ok, isTrue, reason: r2.error);
    expect(r2.pulled, 1, reason: 'only the newer record should be pulled');

    final ids = (await fillRepo.getAll()).map((f) => f.id).toSet();
    expect(ids, containsAll(<String>['remote-1', 'remote-2']));
    expect(settings.lastPullTs, t2);

    await sync.dispose();
  });
}
