// End-to-end test that uses the REAL repository, REAL seed loader, and REAL
// sqflite (via FFI on host) to verify that:
//   1. The CSV asset is bundled and parseable.
//   2. The seed inserts every CSV row exactly once.
//   3. The repo emits the seed data through `watchAll()`.
//   4. The Dashboard, mounted with the real stream, shows real stat values.
//
// Row counts are derived from the CSV at runtime — adding a new row to
// `assets/sample_data/fillups.csv` must NOT require a test edit.
//
// Run: flutter test test/data_wiring_test.dart
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
    final csvFillups = await parseSeedCsv();
    final n = csvFillups.length;

    // Pre-populate "legacy" rows at the same odometers as the CSV but with
    // random UUIDs (NOT the canonical `csv-<odo>` IDs the seed produces).
    await repo.insertMany([
      for (final f in csvFillups)
        FillUp(
          date: f.date,
          odometerKm: f.odometerKm,
          liters: f.liters,
          totalChf: f.totalChf,
        ),
    ]);
    expect(await repo.count(), n, reason: 'pre-seed legacy rows in place');

    // Run the seed. Reconcile should delete the legacy rows and insert the
    // canonical `csv-<odo>` ones. Total stays at n, not 2n.
    await seedFromCsvIfEmpty(repo);

    expect(await repo.count(), n,
        reason: 'must NOT double the rows; reconcile should run');

    final all = await repo.getAll();
    for (final f in all) {
      expect(f.id.startsWith('csv-'), isTrue,
          reason: 'every seed-odometer row should have a canonical ID, got "${f.id}"');
    }
  });

  test('seed imports every CSV row on first run', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    final expected = (await parseSeedCsv()).length;
    expect(await repo.count(), 0, reason: 'fresh DB should be empty');

    final inserted = await seedFromCsvIfEmpty(repo);
    expect(inserted, expected);
    expect(await repo.count(), expected);
  });

  test('seed is idempotent when called twice (no duplicates)', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    final expected = (await parseSeedCsv()).length;

    await seedFromCsvIfEmpty(repo);
    final inserted2 = await seedFromCsvIfEmpty(repo);
    expect(inserted2, 0, reason: 'second call should insert nothing');
    expect(await repo.count(), expected);
  });

  test('repo emits seed data to new subscribers (initial replay)', () async {
    final repo = FillUpRepository(AppDatabase.instance);
    final csvFillups = await parseSeedCsv();
    await seedFromCsvIfEmpty(repo);
    await repo.primeStream();
    final first = await repo.watchAll().first;
    expect(first.length, csvFillups.length);
    expect(
      first.map((f) => f.odometerKm).toSet(),
      csvFillups.map((f) => f.odometerKm).toSet(),
    );
  });

  testWidgets('Dashboard, mounted with real stream after seed, shows stats',
      (tester) async {
    final repo = FillUpRepository(AppDatabase.instance);
    final expected = (await parseSeedCsv()).length;
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
    expect(find.text('Bereit für die erste Ausfahrt?'), findsNothing);
    expect(find.text('Kilometerstand'), findsOneWidget);
    expect(find.text('Ø Verbrauch'), findsOneWidget);
    expect(find.textContaining('$expected Tankfüllungen'), findsOneWidget);
  });

  testWidgets('FuelLog, mounted with real stream, shows all entries',
      (tester) async {
    final repo = FillUpRepository(AppDatabase.instance);
    final expected = (await parseSeedCsv()).length;
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
    expect(find.text('$expected Einträge'), findsOneWidget);
    expect(find.text('Startkilometer'), findsOneWidget);
  });
}
