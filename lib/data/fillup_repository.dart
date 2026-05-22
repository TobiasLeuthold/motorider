import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../models/fillup.dart';
import 'database.dart';

class FillUpRepository {
  FillUpRepository(this._database);

  final AppDatabase _database;

  final _controller = StreamController<List<FillUp>>.broadcast();
  List<FillUp> _latest = const [];

  /// Last emitted list. Useful for StreamBuilder's `initialData` so the UI
  /// doesn't flash an empty state on subscribe.
  List<FillUp> get latest => _latest;

  /// Stream that emits the cached state immediately to every new subscriber
  /// (broadcast streams normally only see emissions after subscribe time),
  /// then forwards live updates.
  Stream<List<FillUp>> watchAll() async* {
    yield _latest;
    yield* _controller.stream;
  }

  Future<List<FillUp>> getAll() async {
    final db = await _database.db;
    final rows = await db.query('fillups', orderBy: 'odometer_km ASC');
    return rows.map(FillUp.fromMap).toList();
  }

  Future<int> count() async {
    final db = await _database.db;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM fillups');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> upsert(FillUp f) async {
    final db = await _database.db;
    await db.insert(
      'fillups',
      f.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emit();
  }

  Future<void> insertMany(List<FillUp> fillups) async {
    final db = await _database.db;
    final batch = db.batch();
    for (final f in fillups) {
      batch.insert(
        'fillups',
        f.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    await _emit();
  }

  Future<void> delete(String id) async {
    final db = await _database.db;
    await db.delete('fillups', where: 'id = ?', whereArgs: [id]);
    await _emit();
  }

  Future<void> _emit() async {
    _latest = await getAll();
    _controller.add(_latest);
  }

  /// Call once after construction to seed the cached state and stream.
  Future<void> primeStream() async {
    _latest = await getAll();
    _controller.add(_latest);
  }
}
