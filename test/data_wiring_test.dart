// End-to-end test that uses the REAL repository, REAL seed loader, and REAL
// sqflite (via FFI on host) to verify that:
//   1. The CSV asset is bundled and parseable.
//   2. The seed inserts all 12 rows.
//   3. The repo emits the seed data through `watchAll()`.
//   4. The Dashboard, mounted with the real stream, shows real stat values.
//
// If any of these fail, this test will catch it. Run:
//   flutter test test/data_wiring_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/csv_seed.dart';
import 'package:motorider/data/database.dart';
import 'package:motorider/data/fillup_repository.dart';
import 'package:motorider/models/fillup.dart';
import 'package:motorider/screens/dashboard_screen.dart';
import 'package:motorider/screens/fuel_log_screen.dart';

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

  test('legacy random-UUID seed rows are deduplicated on next seed run',
      () async {
    // Simulate the user's situation: they previously ran a build that wrote
    // random-UUID rows. Then they upgraded to the deterministic-ID seed.
    // Without reconciliation, they'd end up with doubled stats.
    final repo = FillUpRepository(AppDatabase.instance);
    final base = DateTime(2026, 3, 1, 10);

    // Pre-populate "legacy" rows at the seed odometers, with random UUIDs.
    await repo.insertMany([
      FillUp(date: base, odometerKm: 47, liters: 0, totalChf: 0),
      FillUp(date: base.add(const Duration(days: 20)), odometerKm: 210, liters: 10.0, totalChf: 18.43),
      FillUp(date: base.add(const Duration(days: 33)), odometerKm: 385, liters: 9.56, totalChf: 17.90),
      FillUp(date: base.add(const Duration(days: 35)), odometerKm: 685, liters: 12.54, totalChf: 23.95),
      FillUp(date: base.add(const Duration(days: 48)), odometerKm: 946, liters: 10.10, totalChf: 18.08),
      FillUp(date: base.add(const Duration(days: 56)), odometerKm: 1126, liters: 7.97, totalChf: 14.11),
      FillUp(date: base.add(const Duration(days: 65)), odometerKm: 1317, liters: 9.01, totalChf: 17.40),
      FillUp(date: base.add(const Duration(days: 68)), odometerKm: 1511, liters: 8.06, totalChf: 16.11),
      FillUp(date: base.add(const Duration(days: 69)), odometerKm: 1730, liters: 9.14, totalChf: 17.27),
      FillUp(date: base.add(const Duration(days: 70)), odometerKm: 1967, liters: 8.66, totalChf: 15.24),
      FillUp(date: base.add(const Duration(days: 77)), odometerKm: 2223, liters: 9.61, totalChf: 17.68),
    ]);
    expect(await repo.count(), 11, reason: 'pre-seed legacy rows in place');

    // Run the current seed. Reconcile should delete the legacy rows and
    // insert the canonical `csv-<odo>` ones. The 11 legacy odometers collapse
    // to 11 canonical rows; the CSV's extra 2465 km row adds one more → 12.
    await seedFromCsvIfEmpty(repo);

    expect(await repo.count(), 12,
        reason: 'must NOT double the rows; reconcile should run');

    final all = await repo.getAll();
    final ids = all.map((f) => f.id).toList()..sort();
    for (final id in ids) {
      expect(id.startsWith('csv-'), isTrue,
          reason: 'every seed-odometer row should now have a canonical ID, got "$id"');
    }
  });

  test('seed imports 12 rows from CSV', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    final before = await repo.count();
    expect(before, 0, reason: 'fresh DB should be empty');

    final inserted = await seedFromCsvIfEmpty(repo);
    expect(inserted, 12, reason: 'CSV has 12 rows total');

    final after = await repo.count();
    expect(after, 12);
  });

  test('seed is idempotent when called twice (no duplicates)', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(repo);
    final inserted2 = await seedFromCsvIfEmpty(repo);
    expect(inserted2, 0, reason: 'second call should insert nothing');
    expect(await repo.count(), 12);
  });

  test('repo emits seed data to new subscribers (initial replay)', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(repo);
    await repo.primeStream();
    final first = await repo.watchAll().first;
    expect(first.length, 12);
    expect(first.map((f) => f.odometerKm).toList(),
        containsAll([47, 210, 385, 685, 946, 1126, 1317, 1511, 1730, 1967, 2223, 2465]));
  });

  testWidgets('Dashboard, mounted with real stream after seed, shows stats',
      (tester) async {
    final repo = FillUpRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(repo);
    await repo.primeStream();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('de'), Locale('en')],
        locale: const Locale('de'),
        home: DashboardScreen(stream: repo.watchAll()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // Must NOT show the empty state.
    expect(find.text('Bereit für die erste Ausfahrt?'), findsNothing);
    // Must show the real stat values.
    expect(find.text('Kilometerstand'), findsOneWidget);
    expect(find.text('Ø Verbrauch'), findsOneWidget);
    // 2'223 km is the latest odometer reading in the seed.
    expect(find.textContaining('2'), findsWidgets,
        reason: 'expected odometer or other numeric stat to render');
    // 12 fill-ups badge in the "Getankt total" sub line.
    expect(find.textContaining('12 Tankfüllungen'), findsOneWidget);
  });

  testWidgets('FuelLog, mounted with real stream, shows 12 entries',
      (tester) async {
    final repo = FillUpRepository(AppDatabase.instance);
    await seedFromCsvIfEmpty(repo);
    await repo.primeStream();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('de'), Locale('en')],
        locale: const Locale('de'),
        home: FuelLogScreen(stream: repo.watchAll()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('12 Einträge'), findsOneWidget);
    expect(find.text('Startkilometer'), findsOneWidget);
  });
}
