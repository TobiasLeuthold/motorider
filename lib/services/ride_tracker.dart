import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:geolocator/geolocator.dart';

import '../data/ride_repository.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../stats/ride_stats.dart';

/// Live state of [RideTracker]. UI subscribes to [RideTracker.state] for
/// reactive updates during a ride.
class TrackerState {
  const TrackerState({
    required this.isTracking,
    required this.isPaused,
    required this.currentRide,
    required this.stats,
    required this.lastPoint,
    required this.pointsCount,
  });

  const TrackerState.idle()
      : isTracking = false,
        isPaused = false,
        currentRide = null,
        stats = RideStats.empty,
        lastPoint = null,
        pointsCount = 0;

  final bool isTracking;
  final bool isPaused;
  final Ride? currentRide;
  final RideStats stats;
  final RidePoint? lastPoint;
  final int pointsCount;

  TrackerState copyWith({
    bool? isTracking,
    bool? isPaused,
    Object? currentRide = _sentinel,
    RideStats? stats,
    Object? lastPoint = _sentinel,
    int? pointsCount,
  }) {
    return TrackerState(
      isTracking: isTracking ?? this.isTracking,
      isPaused: isPaused ?? this.isPaused,
      currentRide: identical(currentRide, _sentinel)
          ? this.currentRide
          : currentRide as Ride?,
      stats: stats ?? this.stats,
      lastPoint: identical(lastPoint, _sentinel)
          ? this.lastPoint
          : lastPoint as RidePoint?,
      pointsCount: pointsCount ?? this.pointsCount,
    );
  }
}

const Object _sentinel = Object();

/// Orchestrates GPS tracking for the active ride.
///
/// Lifecycle:
///   - [startRide] writes the parent ride row and starts the location stream.
///   - The location stream runs at 1 Hz, high accuracy. On Android we attach
///     a foreground-service notification so the OS doesn't kill us when the
///     app is backgrounded (screen off, switched to nav app, etc.).
///   - Each fix is appended to `ride_points` AND kept in [_pointsBuffer] for
///     live stats. Stats are recomputed on every new point.
///   - Auto-pause: when speed < [_movingThresholdKmh] for [_pauseAfter], we
///     flip [isPaused] = true. Distance and moving-duration accumulation
///     stops automatically (handled by [computeStats] anyway).
///   - [stopRide] finalizes: persists end time + final stats, stops the
///     stream, and (caller's responsibility) typically pings sync.
class RideTracker {
  RideTracker(this._repo);

  final RideRepository _repo;

  final _controller = StreamController<TrackerState>.broadcast();
  TrackerState _state = const TrackerState.idle();
  TrackerState get state => _state;
  Stream<TrackerState> get changes => _controller.stream;

  StreamSubscription<Position>? _positionSub;
  final List<RidePoint> _pointsBuffer = [];
  int _nextSequence = 0;

  // Auto-pause heuristic.
  DateTime? _lastMovingTs;
  static const _pauseAfter = Duration(seconds: 15);
  static const _movingThresholdKmh = 3.0;

  Future<void> startRide() async {
    if (_state.isTracking) return;

    // Permission gate. The user should already have ACCESS_FINE_LOCATION
    // from the fillup flow; we additionally need background location.
    final ok = await _ensurePermissions();
    if (!ok) {
      throw StateError('Standortzugriff fehlt — bitte in den Einstellungen erlauben.');
    }

    final ride = Ride(startedAt: DateTime.now());
    await _repo.upsert(ride);

    _pointsBuffer.clear();
    _nextSequence = 0;
    _lastMovingTs = null;

    _emit(TrackerState(
      isTracking: true,
      isPaused: false,
      currentRide: ride,
      stats: RideStats.empty,
      lastPoint: null,
      pointsCount: 0,
    ));

    _positionSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(),
    ).listen(
      _onPosition,
      onError: (Object e, StackTrace st) {
        debugPrint('[motorider] RideTracker position stream error: $e');
      },
    );
  }

  Future<Ride?> stopRide() async {
    if (!_state.isTracking) return null;

    await _positionSub?.cancel();
    _positionSub = null;

    final ride = _state.currentRide!;
    final stats = computeStats(_pointsBuffer);
    final finalized = ride.copyWith(
      endedAt: DateTime.now(),
      distanceKm: stats.distanceKm,
      totalDuration: stats.totalDuration,
      movingDuration: stats.movingDuration,
      maxSpeedKmh: stats.maxSpeedKmh,
      avgMovingSpeedKmh: stats.avgMovingSpeedKmh,
      elevationGainM: stats.elevationGainM,
    );
    await _repo.upsert(finalized);

    _emit(const TrackerState.idle());
    _pointsBuffer.clear();
    return finalized;
  }

  void _onPosition(Position pos) async {
    final ride = _state.currentRide;
    if (ride == null) return;

    final point = RidePoint(
      rideId: ride.id,
      sequence: _nextSequence++,
      ts: pos.timestamp,
      lat: pos.latitude,
      lon: pos.longitude,
      altitudeM: pos.altitude,
      speedMs: pos.speed >= 0 ? pos.speed : null,
      accuracyM: pos.accuracy,
      heading: pos.heading >= 0 ? pos.heading : null,
    );

    _pointsBuffer.add(point);
    // Persist points in small batches to avoid hammering SQLite at 1Hz.
    // Every 10 points (~10s) is a good compromise between durability and
    // write cost.
    if (_pointsBuffer.length % 10 == 0) {
      final batch = _pointsBuffer.sublist(_pointsBuffer.length - 10);
      // Fire-and-forget; if it fails the points stay in the buffer and will
      // be re-attempted next batch (insert-or-ignore semantics).
      // ignore: unawaited_futures
      _repo.appendPoints(batch);
    }

    // Auto-pause heuristic.
    final speedKmh = (pos.speed >= 0 ? pos.speed : 0) * 3.6;
    final now = pos.timestamp;
    final wasPaused = _state.isPaused;
    bool isPaused;
    if (speedKmh >= _movingThresholdKmh) {
      _lastMovingTs = now;
      isPaused = false;
    } else {
      final lastMoving = _lastMovingTs ?? now;
      isPaused = now.difference(lastMoving) >= _pauseAfter;
    }

    final stats = computeStats(_pointsBuffer);
    _emit(_state.copyWith(
      isPaused: isPaused,
      stats: stats,
      lastPoint: point,
      pointsCount: _pointsBuffer.length,
    ));

    if (!wasPaused && isPaused) {
      debugPrint('[motorider] RideTracker auto-paused');
    } else if (wasPaused && !isPaused) {
      debugPrint('[motorider] RideTracker resumed');
    }
  }

  Future<bool> _ensurePermissions() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    // `whileInUse` is enough to START tracking — the user has to upgrade to
    // `always` themselves via the system settings dialog for backgrounding.
    // We don't gate startRide on `always` since the foreground service keeps
    // us alive while the screen is on regardless.
    return true;
  }

  LocationSettings _locationSettings() {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Tour läuft',
        notificationText: 'MotoRider zeichnet deine Fahrt auf',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
  }

  void _emit(TrackerState s) {
    _state = s;
    _controller.add(s);
  }

  Future<void> dispose() async {
    await _positionSub?.cancel();
    await _controller.close();
  }
}
