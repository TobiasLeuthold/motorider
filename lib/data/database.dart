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
      version: 4,
      onCreate: (db, version) async {
        await _createFillupsV2(db);
        await _createRidesAndPoints(db);
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
        if (oldVersion < 3) {
          await _createRidesAndPoints(db);
        }
        if (oldVersion < 4) {
          // v3 → v4: weather columns on rides. All nullable — old rides
          // remain "weather-unknown" until the user opens them again and
          // weather is back-filled.
          await db.execute('ALTER TABLE rides ADD COLUMN temp_min_c REAL');
          await db.execute('ALTER TABLE rides ADD COLUMN temp_max_c REAL');
          await db.execute('ALTER TABLE rides ADD COLUMN temp_avg_c REAL');
          await db.execute('ALTER TABLE rides ADD COLUMN precipitation_mm REAL');
          await db.execute('ALTER TABLE rides ADD COLUMN wind_max_kmh REAL');
          await db.execute('ALTER TABLE rides ADD COLUMN weather_code INTEGER');
          await db.execute('ALTER TABLE rides ADD COLUMN weather_fetched_at TEXT');
        }
      },
    );
  }

  Future<void> _createFillupsV2(Database db) async {
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
    await db.execute('CREATE INDEX idx_fillups_date ON fillups(date_iso)');
    await db.execute('CREATE INDEX idx_fillups_odo ON fillups(odometer_km)');
    await db.execute('CREATE INDEX idx_fillups_updated_at ON fillups(updated_at)');
    await db.execute('CREATE INDEX idx_fillups_sync_state ON fillups(sync_state)');
  }

  Future<void> _createRidesAndPoints(Database db) async {
    await db.execute('''
      CREATE TABLE rides (
        id TEXT PRIMARY KEY,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        distance_km REAL NOT NULL DEFAULT 0,
        total_duration_s INTEGER NOT NULL DEFAULT 0,
        moving_duration_s INTEGER NOT NULL DEFAULT 0,
        max_speed_kmh REAL NOT NULL DEFAULT 0,
        avg_moving_speed_kmh REAL NOT NULL DEFAULT 0,
        elevation_gain_m REAL,
        title TEXT,
        notes TEXT,
        temp_min_c REAL,
        temp_max_c REAL,
        temp_avg_c REAL,
        precipitation_mm REAL,
        wind_max_kmh REAL,
        weather_code INTEGER,
        weather_fetched_at TEXT,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        sync_state TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    await db.execute('CREATE INDEX idx_rides_started_at ON rides(started_at)');
    await db.execute('CREATE INDEX idx_rides_updated_at ON rides(updated_at)');
    await db.execute('CREATE INDEX idx_rides_sync_state ON rides(sync_state)');

    await db.execute('''
      CREATE TABLE ride_points (
        ride_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        ts TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        altitude_m REAL,
        speed_ms REAL,
        accuracy_m REAL,
        heading REAL,
        PRIMARY KEY (ride_id, sequence)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_ride_points_ride_id ON ride_points(ride_id)',
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
