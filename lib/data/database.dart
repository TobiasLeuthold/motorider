import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  String? _pathOverride;

  /// Tests can call this with `sqflite_common_ffi`'s `inMemoryDatabasePath` to
  /// avoid `path_provider` and exercise the real schema+SQL on host.
  @visibleForTesting
  void debugUsePath(String path) {
    _pathOverride = path;
    _db = null;
  }

  Future<Database> get db async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final String path;
    if (_pathOverride != null) {
      path = _pathOverride!;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      path = p.join(dir.path, 'motorider.db');
    }
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE fillups (
            id TEXT PRIMARY KEY,
            date_iso TEXT NOT NULL,
            odometer_km INTEGER NOT NULL,
            liters REAL NOT NULL,
            total_chf REAL NOT NULL,
            latitude REAL,
            longitude REAL,
            station TEXT,
            notes TEXT,
            full_tank INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            sync_state TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_fillups_date ON fillups(date_iso)',
        );
        await db.execute(
          'CREATE INDEX idx_fillups_odo ON fillups(odometer_km)',
        );
        await db.execute(
          'CREATE INDEX idx_fillups_updated_at ON fillups(updated_at)',
        );
        await db.execute(
          'CREATE INDEX idx_fillups_sync_state ON fillups(sync_state)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1 → v2: add sync metadata. updated_at is required for LWW; we
          // backfill it from date_iso so existing rows have a sensible
          // ordering relative to anything created post-upgrade.
          await db.execute(
            "ALTER TABLE fillups ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            'ALTER TABLE fillups ADD COLUMN deleted_at TEXT',
          );
          await db.execute(
            "ALTER TABLE fillups ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            "UPDATE fillups SET updated_at = date_iso WHERE updated_at = ''",
          );
          await db.execute(
            'CREATE INDEX idx_fillups_updated_at ON fillups(updated_at)',
          );
          await db.execute(
            'CREATE INDEX idx_fillups_sync_state ON fillups(sync_state)',
          );
        }
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
