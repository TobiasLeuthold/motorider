import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../models/fillup.dart';
import 'fillup_repository.dart';

const _seedAssetPath = 'assets/sample_data/fillups.csv';

/// Imports the bundled CSV into the database.
///
/// Idempotent and self-healing:
///   1. **Insert pass** — uses deterministic IDs (`csv-<odoKm>`) plus
///      `ConflictAlgorithm.ignore`, so re-imports never create duplicates and
///      never clobber a row that's already there.
///   2. **Reconciliation pass** — after inserting, collapses any odometer
///      with multiple rows down to the canonical `csv-<odoKm>` row. This
///      cleans up legacy installs whose pre-existing random-UUID seed rows
///      now coexist with the freshly inserted canonical rows.
///
/// Result: a clean `(odometer_km) -> 1 row` mapping for every CSV entry,
/// regardless of what was in the DB before.
Future<int> seedFromCsvIfEmpty(FillUpRepository repo) async {
  try {
    return await _seed(repo);
  } catch (e, st) {
    debugPrint('[motorider] CSV seed failed: $e\n$st');
    return 0;
  }
}

String seedIdForOdometer(int odoKm) => 'csv-$odoKm';

Future<int> _seed(FillUpRepository repo) async {
  final existing = await repo.count();
  debugPrint('[motorider] DB has $existing fill-ups before seed');

  final raw = await rootBundle.loadString(_seedAssetPath);
  final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rows = const CsvToListConverter(
    eol: '\n',
    shouldParseNumbers: false,
  ).convert(normalized);
  if (rows.isEmpty) {
    debugPrint('[motorider] Seed CSV is empty, nothing to import');
    return 0;
  }

  final header = rows.first.map((c) => c.toString()).toList();
  int idx(String name) => header.indexOf(name);

  final iDate = idx('date');
  final iOdo = idx('odometer_km');
  final iL = idx('liters');
  final iChf = idx('total_chf');
  final iLat = idx('latitude');
  final iLon = idx('longitude');
  final iStation = idx('station');
  final iNotes = idx('notes');
  final iFull = idx('full_tank');

  final fillups = <FillUp>[];
  for (final r in rows.skip(1)) {
    if (r.isEmpty || (r.length == 1 && r.first.toString().trim().isEmpty)) {
      continue;
    }
    String s(int i) => (i >= 0 && i < r.length) ? r[i].toString() : '';
    double? d(String x) => x.isEmpty ? null : double.tryParse(x);
    final date = DateTime.parse(s(iDate));
    final odo = int.parse(s(iOdo));
    fillups.add(FillUp(
      id: seedIdForOdometer(odo),
      date: date,
      odometerKm: odo,
      liters: double.parse(s(iL)),
      totalChf: double.parse(s(iChf)),
      latitude: d(s(iLat)),
      longitude: d(s(iLon)),
      station: s(iStation).isEmpty ? null : s(iStation),
      notes: s(iNotes).isEmpty ? null : s(iNotes),
      fullTank: s(iFull) != '0',
    ));
  }

  final inserted = await repo.insertManyIgnore(fillups);
  debugPrint('[motorider] CSV seed: ${fillups.length} rows in file, '
      '$inserted newly inserted (rest already present)');

  final seedOdometers = fillups.map((f) => f.odometerKm).toSet();
  final deleted = await reconcileSeedDuplicates(repo, seedOdometers);
  if (deleted > 0) {
    debugPrint('[motorider] Reconciled: removed $deleted duplicate row(s)');
  }

  return inserted;
}

/// For every CSV odometer reading, if the DB has >1 row at that odometer,
/// delete all but one. Prefers the canonical `csv-<odoKm>` row, otherwise
/// keeps the first. Returns the number of rows deleted.
///
/// This is what cleans up legacy installs that wrote random-UUID seed rows
/// before deterministic IDs existed.
Future<int> reconcileSeedDuplicates(
  FillUpRepository repo,
  Set<int> seedOdometers,
) async {
  final all = await repo.getAll();
  final byOdo = <int, List<FillUp>>{};
  for (final f in all) {
    if (seedOdometers.contains(f.odometerKm)) {
      byOdo.putIfAbsent(f.odometerKm, () => []).add(f);
    }
  }
  var deleted = 0;
  for (final entry in byOdo.entries) {
    final group = entry.value;
    if (group.length <= 1) continue;
    final canonicalId = seedIdForOdometer(entry.key);
    final keep = group.firstWhere(
      (f) => f.id == canonicalId,
      orElse: () => group.first,
    );
    for (final f in group) {
      if (f.id != keep.id) {
        await repo.delete(f.id);
        deleted++;
      }
    }
  }
  return deleted;
}
