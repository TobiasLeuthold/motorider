import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:motorider/data/database.dart';
import 'package:motorider/data/ride_repository.dart';
import 'package:motorider/services/ride_tracker.dart';

/// Minimal fake [GeolocatorPlatform] so [RideTracker] can run headless: it
/// grants permission, reports the location service as enabled, and feeds
/// positions from a controllable stream.
class _FakeGeolocator extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  final _positions = StreamController<Position>.broadcast();

  void emit(Position p) => _positions.add(p);

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.always;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.always;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _positions.stream;
}

Position _pos(double lat, double lon, {double speed = 10}) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 400,
      altitudeAccuracy: 3,
      heading: 90,
      headingAccuracy: 5,
      speed: speed,
      speedAccuracy: 1,
    );

void main() {
  late _FakeGeolocator fakeGeo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    AppDatabase.instance.debugUsePath(inMemoryDatabasePath);
    fakeGeo = _FakeGeolocator();
    GeolocatorPlatform.instance = fakeGeo;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  test('startRide() starts a session and returns true', () async {
    final tracker = RideTracker(RideRepository(AppDatabase.instance));
    expect(tracker.state.isTracking, isFalse);

    final started = await tracker.startRide();

    expect(started, isTrue, reason: 'first start owns a fresh session');
    expect(tracker.state.isTracking, isTrue);
    expect(tracker.state.currentRide, isNotNull);

    await tracker.dispose();
  });

  test(
      'startRide() is idempotent: a second call while tracking is a no-op '
      'and returns false', () async {
    // This is the exact invariant navigation relies on to COEXIST with a tour
    // the rider already started: it must adopt the running session, never
    // start a competing second one.
    final tracker = RideTracker(RideRepository(AppDatabase.instance));

    final first = await tracker.startRide();
    final ride1 = tracker.state.currentRide;

    final second = await tracker.startRide();
    final ride2 = tracker.state.currentRide;

    expect(first, isTrue);
    expect(second, isFalse, reason: 'already tracking → adopt, do not restart');
    // The session is untouched: same ride, still tracking.
    expect(tracker.state.isTracking, isTrue);
    expect(identical(ride1, ride2), isTrue,
        reason: 'the running ride must not be replaced');

    await tracker.dispose();
  });

  test('the adopted session keeps emitting fixes navigation can consume',
      () async {
    // Models the navigation-while-tracking path: a tour is already running and
    // a (would-be) second start adopts it; the live fix stream stays the one
    // shared source, so the navigator can be driven from tracker.lastPoint.
    final tracker = RideTracker(RideRepository(AppDatabase.instance));
    await tracker.startRide();

    // A second start (what NavigationScreen does on entry) is a no-op.
    final adopted = await tracker.startRide();
    expect(adopted, isFalse);

    final seen = <int>[];
    final sub = tracker.changes.listen((s) {
      if (s.lastPoint != null) seen.add(s.lastPoint!.sequence);
    });

    fakeGeo.emit(_pos(47.0, 8.0));
    fakeGeo.emit(_pos(47.001, 8.001));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(seen, isNotEmpty,
        reason: 'tracker.lastPoint must flow so navigation gets fixes');
    expect(tracker.state.lastPoint, isNotNull);

    await sub.cancel();
    await tracker.dispose();
  });

  test('stopRide() ends the session; a later startRide() owns a new one',
      () async {
    // Navigation only ever stops a session IT started. After any stop, the
    // next start is a fresh, owned session again (returns true).
    final tracker = RideTracker(RideRepository(AppDatabase.instance));

    expect(await tracker.startRide(), isTrue);
    final ride = await tracker.stopRide();
    expect(ride, isNotNull);
    expect(tracker.state.isTracking, isFalse);

    expect(await tracker.startRide(), isTrue,
        reason: 'after stopping, a new start owns the new session');

    await tracker.dispose();
  });
}
