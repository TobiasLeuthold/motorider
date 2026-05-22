import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get db async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'motorider.db');
    return openDatabase(
      path,
      version: 1,
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
            full_tank INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_fillups_date ON fillups(date_iso)',
        );
        await db.execute(
          'CREATE INDEX idx_fillups_odo ON fillups(odometer_km)',
        );
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
