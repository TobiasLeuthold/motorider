// Regression test for the reinstall location-loss bug.
//
// Scenario the user hit: they add a location (lat/lon/station) to a fill-up on
// the phone; it syncs to the NAS; but after REINSTALLING the app and syncing
// back, the location is gone.
//
// Root cause: on reinstall the CSV seed re-creates rows as `pending` with
// updated_at = the fill DATE (old), no location. The first sync pushes those
// stale rows BEFORE pulling, and the push had no last-write-wins guard — it
// PATCHed the server and regressed the row's updated_at back to the old date.
// PocketBase PATCH leaves omitted fields untouched, so the location survived
// ON the server, but the regressed timestamp then made the pull skip the row
// (equal updated_at → applyServerRecord returns "no change"), so the phone
// never got the location back.
//
// This test runs the REAL SyncService / FillUpRepository / csv_seed / sqflite
// against an in-memory fake that mimics PocketBase's partial-update PATCH.
//
// Run: flutter test test/sync_reinstall_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/csv_seed.dart';
import 'package:motorider/data/database.dart';
import 'package:motorider/data/fillup_repository.dart';
import 'package:motorider/data/ride_repository.dart';
import 'package:motorider/services/nas_settings.dart';
import 'package:motorider/services/sync_service.dart';

import 'fake_pocketbase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<NasSettings> freshSettings() async {
    // Simulate a clean install's SharedPreferences: credentials present (so
    // sync runs) but no lastPullTs.
    SharedPreferences.setMockInitialValues({
      'nas.email': 'test@local',
      'nas.password': 'secret',
    });
    return NasSettings.load();
  }

  test('location added on the phone survives an app reinstall + resync',
      () async {
    final server = FakePocketBase();

    // ── Install #1: seed, push, then add a location and sync it up ────────
    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
    var fillRepo = FillUpRepository(AppDatabase.instance);
    var rideRepo = RideRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(fillRepo);
    await fillRepo.primeStream();

    var settings = await freshSettings();
    var sync = SyncService(fillRepo, rideRepo, settings,
        backend: server, autoSync: false);

    final r1 = await sync.syncOnce();
    expect(r1.ok, isTrue, reason: 'initial sync failed: ${r1.error}');

    final seeded = await fillRepo.getAll();
    expect(seeded, isNotEmpty);
    final target = seeded.first;
    expect(target.latitude, isNull, reason: 'seed rows start with no location');

    await fillRepo.upsert(target.copyWith(
      latitude: 46.94809,
      longitude: 7.44744,
      station: 'Tankstelle Bern',
    ));
    final r2 = await sync.syncOnce();
    expect(r2.ok, isTrue, reason: 'edit sync failed: ${r2.error}');

    // Sanity: the location really did reach the "NAS".
    final onServer = await server.findByClientId('fillups', target.id);
    expect(onServer, isNotNull);
    expect((onServer!['latitude'] as num?)?.toDouble(), closeTo(46.94809, 1e-9),
        reason: 'edit must persist server-side');

    await sync.dispose();
    await AppDatabase.instance.close();

    // ── Reinstall: fresh local DB + fresh prefs, SAME NAS ────────────────
    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
    fillRepo = FillUpRepository(AppDatabase.instance);
    rideRepo = RideRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(fillRepo); // re-seeds csv-<odo>, NO location
    await fillRepo.primeStream();

    settings = await freshSettings();
    sync = SyncService(fillRepo, rideRepo, settings,
        backend: server, autoSync: false);

    final r3 = await sync.syncOnce();
    expect(r3.ok, isTrue, reason: 'post-reinstall sync failed: ${r3.error}');

    // The location added before the reinstall must come back.
    final restored = (await fillRepo.getAll()).firstWhere((f) => f.id == target.id);
    expect(restored.latitude, closeTo(46.94809, 1e-9),
        reason: 'location added before reinstall was lost after resync');
    expect(restored.longitude, closeTo(7.44744, 1e-9));
    expect(restored.station, 'Tankstelle Bern');

    await sync.dispose();
    await AppDatabase.instance.close();
  });

  test('a location whose server timestamp was regressed to the seed date is '
      'recovered on resync', () async {
    // Models the state the OLD bug left behind: the location is still on the
    // NAS, but its updated_at was regressed to exactly the seed/fill date. A
    // plain last-write-wins-by-isAfter pull would skip it forever (tie). The
    // fix recovers it because the re-seeded local row is `pending`.
    final server = FakePocketBase();

    final seedRows = await parseSeedCsv();
    final s = seedRows.first; // id = csv-<odo>, updatedAt = fill date
    expect(s.latitude, isNull);

    // Server holds the location at the regressed (== seed) timestamp.
    await server.createRecord(
      'fillups',
      s
          .copyWith(
            latitude: 46.5,
            longitude: 7.5,
            station: 'Recovered Station',
          )
          .toPocketBaseJson(),
    );

    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
    final fillRepo = FillUpRepository(AppDatabase.instance);
    final rideRepo = RideRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(fillRepo);
    await fillRepo.primeStream();

    final settings = await freshSettings();
    final sync = SyncService(fillRepo, rideRepo, settings,
        backend: server, autoSync: false);

    final r = await sync.syncOnce();
    expect(r.ok, isTrue, reason: r.error);

    final row = (await fillRepo.getAll()).firstWhere((f) => f.id == s.id);
    expect(row.station, 'Recovered Station',
        reason: 'an equal-timestamp server record should be adopted for a '
            're-seeded (pending) local row');
    expect(row.latitude, closeTo(46.5, 1e-9));

    await sync.dispose();
    await AppDatabase.instance.close();
  });
}
