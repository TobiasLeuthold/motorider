import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/fillup.dart' show SyncState;
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../stats/ride_stats.dart';
import 'database.dart';

/// Persistence layer for [Ride]s + their child `ride_points`.
///
/// API shape mirrors [FillUpRepository] for consistency:
///   - `watchAll()` for the UI to subscribe to the live list of rides
///   - `upsert` / `delete` mark the row pending and emit
///   - Sync helpers: `getPendingForSync`, `markSynced`, `applyServerRecord`,
///     and the JSON marshalling for the points-as-blob wire format.
class RideRepository {
  RideRepository(this._database);

  final AppDatabase _database;

  final _controller = StreamController<List<Ride>>.broadcast();
  final _localWritesController = StreamController<void>.broadcast();
  List<Ride> _latest = const [];

  List<Ride> get latest => _latest;

  Stream<List<Ride>> watchAll() async* {
    yield _latest;
    yield* _controller.stream;
  }

  Stream<void> get localWrites => _localWritesController.stream;

  /// Live (non-tombstoned) rides, newest start first.
  Future<List<Ride>> getAll() async {
    final db = await _database.db;
    final rows = await db.query(
      'rides',
      where: 'deleted_at IS NULL',
      orderBy: 'started_at DESC',
    );
    return rows.map(Ride.fromMap).toList();
  }

  Future<Ride?> getById(String id) async {
    final db = await _database.db;
    final rows = await db.query('rides', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Ride.fromMap(rows.first);
  }

  Future<List<RidePoint>> getPoints(String rideId) async {
    final db = await _database.db;
    final rows = await db.query(
      'ride_points',
      where: 'ride_id = ?',
      whereArgs: [rideId],
      orderBy: 'sequence ASC',
    );
    return rows.map(RidePoint.fromMap).toList();
  }

  /// User-facing upsert. Stamps `updated_at` and marks the row pending.
  Future<void> upsert(Ride r) async {
    final db = await _database.db;
    final stamped = r.copyWith(
      updatedAt: DateTime.now(),
      syncState: SyncState.pending,
    );
    await db.insert(
      'rides',
      stamped.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _emit();
    _localWritesController.add(null);
  }

  /// Append a batch of points to an in-progress ride. Points are immutable
  /// once written, so we use insert-or-ignore on the composite PK to make
  /// re-tries safe if the tracker fires the same point twice.
  Future<void> appendPoints(List<RidePoint> points) async {
    if (points.isEmpty) return;
    final db = await _database.db;
    final batch = db.batch();
    for (final p in points) {
      batch.insert(
        'ride_points',
        p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
    // No _emit() — UI subscribes to the ride row + live tracker state, not to
    // every individual point insert.
  }

  /// User-facing soft delete: tombstone the ride and trigger sync. Child
  /// points are intentionally NOT deleted yet — they're cheap to keep and
  /// help with eventual undelete.
  Future<void> delete(String id) async {
    final db = await _database.db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'rides',
      {
        'deleted_at': now,
        'updated_at': now,
        'sync_state': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _emit();
    _localWritesController.add(null);
  }

  /// Recompute the cached stats of every ride from its raw points.
  ///
  /// Two self-heal jobs, both idempotent and cheap to run at every startup:
  ///   • Stats-algorithm changes (e.g. the Doppler-based max-speed fix):
  ///     rides whose numbers actually changed are rewritten (and re-synced).
  ///   • Orphaned active rides (app killed mid-tracking, `ended_at` never
  ///     set): finalized using the last persisted point's timestamp. Called
  ///     at startup, before any new tracking session, so an active row here
  ///     is always an orphan.
  Future<int> recomputeAllStats() async {
    final rides = await getAll();
    var changed = 0;
    for (final r in rides) {
      final points = await getPoints(r.id);
      if (points.length < 2) {
        if (r.endedAt == null) {
          // Orphan without usable track — close it so it stops looking like
          // a running ride; stats stay zero.
          await upsert(r.copyWith(endedAt: r.startedAt));
          changed++;
        }
        continue;
      }
      final s = computeStats(points);
      final differs = r.endedAt == null ||
          (s.maxSpeedKmh - r.maxSpeedKmh).abs() > 0.5 ||
          (s.distanceKm - r.distanceKm).abs() > 0.05 ||
          (s.avgMovingSpeedKmh - r.avgMovingSpeedKmh).abs() > 0.5 ||
          ((s.elevationGainM ?? -1) - (r.elevationGainM ?? -1)).abs() > 0.5;
      if (!differs) continue;
      await upsert(r.copyWith(
        endedAt: r.endedAt ?? points.last.ts,
        distanceKm: s.distanceKm,
        totalDuration: s.totalDuration,
        movingDuration: s.movingDuration,
        maxSpeedKmh: s.maxSpeedKmh,
        avgMovingSpeedKmh: s.avgMovingSpeedKmh,
        elevationGainM: s.elevationGainM,
      ));
      changed++;
    }
    return changed;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Sync helpers
  // ──────────────────────────────────────────────────────────────────────

  Future<List<Ride>> getPendingForSync() async {
    final db = await _database.db;
    final rows = await db.query(
      'rides',
      where: 'sync_state = ?',
      whereArgs: ['pending'],
    );
    return rows.map(Ride.fromMap).toList();
  }

  Future<void> markSynced(String id) async {
    final db = await _database.db;
    await db.update(
      'rides',
      {'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Serialize all points of a ride into the compact JSON-tuple form used on
  /// the wire. The choice of compact tuples (vs. one object per point) keeps
  /// the payload manageable — see [RidePoint.toJsonTuple].
  Future<String> serializePointsForSync(String rideId) async {
    final points = await getPoints(rideId);
    final tuples = points.map((p) => p.toJsonTuple()).toList();
    return jsonEncode(tuples);
  }

  /// Merge a server ride into the local DB using LWW on `updated_at`. If we
  /// accept the server version, the entire `ride_points` table for that
  /// ride is replaced — there's no partial-point reconciliation, the JSON
  /// blob IS the points.
  ///
  /// Returns true if the local DB actually changed.
  Future<bool> applyServerRecord(Ride server, String? pointsJson) async {
    final db = await _database.db;
    final existing = await db.query(
      'rides',
      where: 'id = ?',
      whereArgs: [server.id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final local = Ride.fromMap(existing.first);
      // Last-write-wins, mirroring FillUpRepository.applyServerRecord: server
      // wins when strictly newer, or on an exact tie when the local row is
      // still pending (re-created/regressed). A tie with a synced local row is
      // a no-op; a strictly-older server record is ignored.
      final serverNewer = server.updatedAt.isAfter(local.updatedAt);
      final tie = !serverNewer && !local.updatedAt.isAfter(server.updatedAt);
      if (!serverNewer && !(tie && local.syncState == SyncState.pending)) {
        return false;
      }
    }

    final mapped = server.toMap();
    mapped['sync_state'] = 'synced';
    await db.insert(
      'rides',
      mapped,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (pointsJson != null && pointsJson.isNotEmpty) {
      await db.delete(
        'ride_points',
        where: 'ride_id = ?',
        whereArgs: [server.id],
      );
      final decoded = jsonDecode(pointsJson);
      if (decoded is List) {
        final batch = db.batch();
        for (final t in decoded) {
          if (t is List) {
            final p = RidePoint.fromJsonTuple(server.id, t);
            batch.insert('ride_points', p.toMap());
          }
        }
        await batch.commit(noResult: true);
      }
    }

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
