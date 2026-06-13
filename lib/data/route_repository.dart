import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../models/fillup.dart' show SyncState;
import '../models/planned_route.dart';
import 'database.dart';

/// Persistence for [PlannedRoute]s. API shape mirrors [RideRepository] /
/// [FillUpRepository]: a broadcast `watchAll()` for the UI, `upsert` / `delete`
/// that stamp `updated_at` and mark the row pending, plus the sync helpers so a
/// future NAS/PocketBase collection can adopt tours with no model changes.
class RouteRepository {
  RouteRepository(this._database);

  final AppDatabase _database;

  final _controller = StreamController<List<PlannedRoute>>.broadcast();
  final _localWritesController = StreamController<void>.broadcast();
  List<PlannedRoute> _latest = const [];

  List<PlannedRoute> get latest => _latest;

  Stream<List<PlannedRoute>> watchAll() async* {
    yield _latest;
    yield* _controller.stream;
  }

  Stream<void> get localWrites => _localWritesController.stream;

  /// Live (non-tombstoned) tours, newest first.
  Future<List<PlannedRoute>> getAll() async {
    final db = await _database.db;
    final rows = await db.query(
      'planned_routes',
      where: 'deleted_at IS NULL',
      orderBy: 'updated_at DESC',
    );
    return rows.map(PlannedRoute.fromMap).toList();
  }

  Future<PlannedRoute?> getById(String id) async {
    final db = await _database.db;
    final rows = await db.query(
      'planned_routes',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PlannedRoute.fromMap(rows.first);
  }

  /// User-facing upsert. Stamps `updated_at` and marks the row pending.
  Future<void> upsert(PlannedRoute r) async {
    final db = await _database.db;
    final stamped = r.copyWith(
      updatedAt: DateTime.now(),
      syncState: SyncState.pending,
    );
    await db.insert(
      'planned_routes',
      stamped.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emit();
    _localWritesController.add(null);
  }

  /// Soft delete: tombstone the tour and trigger sync.
  Future<void> delete(String id) async {
    final db = await _database.db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'planned_routes',
      {'deleted_at': now, 'updated_at': now, 'sync_state': 'pending'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _emit();
    _localWritesController.add(null);
  }

  // ── Sync helpers (mirror RideRepository) ────────────────────────────────

  Future<List<PlannedRoute>> getPendingForSync() async {
    final db = await _database.db;
    final rows = await db.query(
      'planned_routes',
      where: 'sync_state = ?',
      whereArgs: ['pending'],
    );
    return rows.map(PlannedRoute.fromMap).toList();
  }

  Future<void> markSynced(String id) async {
    final db = await _database.db;
    await db.update(
      'planned_routes',
      {'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Merge a server tour into the local DB using LWW on `updated_at`. Returns
  /// true if the local DB actually changed.
  Future<bool> applyServerRecord(PlannedRoute server) async {
    final db = await _database.db;
    final existing = await db.query(
      'planned_routes',
      where: 'id = ?',
      whereArgs: [server.id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final local = PlannedRoute.fromMap(existing.first);
      if (!server.updatedAt.isAfter(local.updatedAt)) return false;
    }
    final mapped = server.toMap();
    mapped['sync_state'] = 'synced';
    await db.insert(
      'planned_routes',
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

  Future<void> primeStream() async {
    _latest = await getAll();
    _controller.add(_latest);
  }
}
