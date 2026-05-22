import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../models/fillup.dart';
import 'fillup_repository.dart';

const _seedAssetPath = 'assets/sample_data/fillups.csv';

/// Imports the bundled CSV into the database when the table is empty.
///
/// Idempotent: calling on a populated DB is a no-op. Until NAS sync exists,
/// this guarantees a fresh install starts with usable data so charts and
/// stats render meaningfully during development.
Future<int> seedFromCsvIfEmpty(FillUpRepository repo) async {
  try {
    return await _seed(repo);
  } catch (e, st) {
    debugPrint('[motorider] CSV seed failed: $e\n$st');
    return 0;
  }
}

Future<int> _seed(FillUpRepository repo) async {
  final existing = await repo.count();
  debugPrint('[motorider] DB has $existing fill-ups before seed');
  if (existing > 0) return 0;

  final raw = await rootBundle.loadString(_seedAssetPath);
  // Normalize line endings so CRLF (Windows) and LF both work, then let
  // the CSV parser pick its default EOL.
  final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rows = const CsvToListConverter(
    eol: '\n',
    shouldParseNumbers: false,
  ).convert(normalized);
  if (rows.isEmpty) return 0;

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
    fillups.add(FillUp(
      date: DateTime.parse(s(iDate)),
      odometerKm: int.parse(s(iOdo)),
      liters: double.parse(s(iL)),
      totalChf: double.parse(s(iChf)),
      latitude: d(s(iLat)),
      longitude: d(s(iLon)),
      station: s(iStation).isEmpty ? null : s(iStation),
      notes: s(iNotes).isEmpty ? null : s(iNotes),
      fullTank: s(iFull) != '0',
    ));
  }
  await repo.insertMany(fillups);
  debugPrint('[motorider] CSV seed imported ${fillups.length} fill-ups');
  return fillups.length;
}
