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

  /// Live (non-tombstoned) rows, sorted by odometer ascending.
  Future<List<FillUp>> getAll() async {
    final db = await _database.db;
    final rows = await db.query(
      'fillups',
      where: 'deleted_at IS NULL',
      orderBy: 'odometer_km ASC',
    );
    return rows.map(FillUp.fromMap).toList();
  }

  Future<int> count() async {
    final db = await _database.db;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM fillups WHERE deleted_at IS NULL',
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// User-facing upsert. Stamps `updated_at` and flips the row back to
  /// `pending` so the next sync run pushes it.
  Future<void> upsert(FillUp f) async {
    final db = await _database.db;
    final stamped = f.copyWith(
      updatedAt: DateTime.now(),
      syncState: SyncState.pending,
    );
    await db.insert(
      'fillups',
      stamped.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emit();
  }

  Future<void> insertMany(List<FillUp> fillups) async {
    final db = await _database.db;
    final batch = db.batch();
    final now = DateTime.now();
    for (final f in fillups) {
      final stamped = f.copyWith(
        updatedAt: now,
        syncState: SyncState.pending,
      );
      batch.insert(
        'fillups',
        stamped.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    await _emit();
  }

  /// Inserts rows only if their IDs don't already exist. Used by the CSV seed
  /// so re-imports don't clobber user edits and don't create duplicates.
  Future<int> insertManyIgnore(List<FillUp> fillups) async {
    final db = await _database.db;
    final batch = db.batch();
    final now = DateTime.now();
    for (final f in fillups) {
      final stamped = f.copyWith(
        updatedAt: now,
        syncState: SyncState.pending,
      );
      batch.insert(
        'fillups',
        stamped.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final results = await batch.commit();
    final inserted = results.where((r) => r is int && r != 0).length;
    if (inserted > 0) await _emit();
    return inserted;
  }

  /// User-facing delete. Soft-deletes so the deletion can replicate to the
  /// NAS and any other device. The row stays in the table as a tombstone.
  Future<void> delete(String id) async {
    final db = await _database.db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'fillups',
      {
        'deleted_at': now,
        'updated_at': now,
        'sync_state': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _emit();
  }

  /// Local-only cleanup that should NOT propagate to the server. Used by the
  /// CSV seed's reconciliation pass to strip legacy duplicate rows that never
  /// had any business being there in the first place.
  Future<void> hardDeleteById(String id) async {
    final db = await _database.db;
    await db.delete('fillups', where: 'id = ?', whereArgs: [id]);
    await _emit();
  }

  // ──────────────────────────────────────────────────────────────────────
  // Sync helpers
  // ──────────────────────────────────────────────────────────────────────

  /// Rows the local app owes the server. Includes tombstones.
  Future<List<FillUp>> getPendingForSync() async {
    final db = await _database.db;
    final rows = await db.query(
      'fillups',
      where: 'sync_state = ?',
      whereArgs: ['pending'],
    );
    return rows.map(FillUp.fromMap).toList();
  }

  /// Mark a row as in-sync with the server. Called after a successful push.
  /// Does NOT bump updated_at — the push already preserved the client's
  /// timestamp on the server, and we want the next LWW comparison to use it.
  Future<void> markSynced(String id) async {
    final db = await _database.db;
    await db.update(
      'fillups',
      {'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
    // Intentionally no _emit(): UI doesn't care about sync_state transitions.
  }

  /// Merge a record received from the server into the local DB using
  /// last-write-wins by `updated_at`. Equal timestamps keep the local copy
  /// to avoid pointless churn. The merged row is marked `synced`.
  ///
  /// Returns true if the local DB actually changed.
  Future<bool> applyServerRecord(FillUp serverRow) async {
    final db = await _database.db;
    final existing = await db.query(
      'fillups',
      where: 'id = ?',
      whereArgs: [serverRow.id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final local = FillUp.fromMap(existing.first);
      if (!serverRow.updatedAt.isAfter(local.updatedAt)) return false;
    }
    final mapped = serverRow.toMap();
    mapped['sync_state'] = 'synced';
    await db.insert(
      'fillups',
      mapped,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emit();
    return true;
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
