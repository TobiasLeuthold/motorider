import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/database.dart';
import 'package:motorider/data/route_repository.dart';
import 'package:motorider/models/curviness.dart';
import 'package:motorider/models/planned_route.dart';

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

  PlannedRoute sample() => PlannedRoute(
        name: 'Furka-Runde',
        waypoints: const [LatLng(46.57, 8.42), LatLng(46.61, 8.41)],
        geometry: const [
          LatLng(46.57, 8.42),
          LatLng(46.59, 8.415),
          LatLng(46.61, 8.41),
        ],
        curviness: Curviness.extra,
        distanceM: 12345,
        durationS: 1500,
        ascentM: 640,
        curvinessScore: 220,
      );

  test('upsert then getAll round-trips all fields', () async {
    final repo = RouteRepository(AppDatabase.instance);
    final r = sample();
    await repo.upsert(r);

    final all = await repo.getAll();
    expect(all.length, 1);
    final got = all.first;
    expect(got.id, r.id);
    expect(got.name, 'Furka-Runde');
    expect(got.waypoints.length, 2);
    expect(got.geometry.length, 3);
    expect(got.geometry[1].latitude, closeTo(46.59, 1e-9));
    expect(got.curviness, Curviness.extra);
    expect(got.distanceM, 12345);
    expect(got.durationS, 1500);
    expect(got.ascentM, 640);
    expect(got.curvinessScore, 220);
  });

  test('delete tombstones the tour (hidden from getAll)', () async {
    final repo = RouteRepository(AppDatabase.instance);
    final r = sample();
    await repo.upsert(r);
    await repo.delete(r.id);
    expect(await repo.getAll(), isEmpty);
  });

  test('watchAll emits the current list to new subscribers', () async {
    final repo = RouteRepository(AppDatabase.instance);
    await repo.upsert(sample());
    await repo.primeStream();
    final first = await repo.watchAll().first;
    expect(first.length, 1);
  });

  test('pending sync queue picks up new tours, markSynced clears them',
      () async {
    final repo = RouteRepository(AppDatabase.instance);
    final r = sample();
    await repo.upsert(r);
    expect((await repo.getPendingForSync()).length, 1);
    await repo.markSynced(r.id);
    expect(await repo.getPendingForSync(), isEmpty);
  });
}
