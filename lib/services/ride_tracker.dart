import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:geolocator/geolocator.dart';

import '../data/ride_repository.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../stats/ride_stats.dart';
import 'weather_service.dart';

/// Live state of [RideTracker]. UI subscribes to [RideTracker.state] for
/// reactive updates during a ride.
class TrackerState {
  const TrackerState({
    required this.isTracking,
    required this.isAutoPaused,
    required this.isManuallyPaused,
    required this.currentRide,
    required this.stats,
    required this.lastPoint,
    required this.pointsCount,
  });

  const TrackerState.idle()
      : isTracking = false,
        isAutoPaused = false,
        isManuallyPaused = false,
        currentRide = null,
        stats = RideStats.empty,
        lastPoint = null,
        pointsCount = 0;

  final bool isTracking;
  /// Speed dropped below threshold for long enough that the cosmetic
  /// "PAUSIERT" hint should show. Does NOT stop point collection — auto-pause
  /// is purely UI; data still flows in case the rider resumes movement.
  final bool isAutoPaused;
  /// User tapped the Pause button. While true, incoming GPS points are
  /// dropped — distance/duration don't accumulate through coffee breaks.
  final bool isManuallyPaused;
  final Ride? currentRide;
  final RideStats stats;
  final RidePoint? lastPoint;
  final int pointsCount;

  /// True if either the user or the auto-pause heuristic has us in a paused
  /// state. UI uses this for the "PAUSIERT" badge.
  bool get isPaused => isAutoPaused || isManuallyPaused;

  TrackerState copyWith({
    bool? isTracking,
    bool? isAutoPaused,
    bool? isManuallyPaused,
    Object? currentRide = _sentinel,
    RideStats? stats,
    Object? lastPoint = _sentinel,
    int? pointsCount,
  }) {
    return TrackerState(
      isTracking: isTracking ?? this.isTracking,
      isAutoPaused: isAutoPaused ?? this.isAutoPaused,
      isManuallyPaused: isManuallyPaused ?? this.isManuallyPaused,
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
  // How many buffered points have been confirmed written to SQLite. Batches
  // flush from this offset, so a failed write is simply retried with the next
  // batch (insert-or-ignore makes overlaps safe).
  int _persistedCount = 0;

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
    _persistedCount = 0;
    _lastMovingTs = null;

    _emit(TrackerState(
      isTracking: true,
      isAutoPaused: false,
      isManuallyPaused: false,
      currentRide: ride,
      stats: RideStats.empty,
      lastPoint: null,
      pointsCount: 0,
    ));

    _subscribePositions(forceLocationManager: false);
  }

  /// Subscribe to the position stream. Tries the fused (Google Play
  /// services) provider first; if GMS reports its settings check as
  /// unsatisfiable (no network provider — common on emulators, also seen on
  /// degoogled devices), falls back to the raw Android LocationManager once
  /// instead of silently recording nothing.
  void _subscribePositions({required bool forceLocationManager}) {
    _positionSub = Geolocator.getPositionStream(
      locationSettings:
          _locationSettings(forceLocationManager: forceLocationManager),
    ).listen(
      _onPosition,
      onError: (Object e, StackTrace st) async {
        debugPrint('[motorider] RideTracker position stream error: $e');
        if (!forceLocationManager &&
            _state.isTracking &&
            e is LocationServiceDisabledException) {
          debugPrint(
              '[motorider] RideTracker falling back to LocationManager');
          // Fully tear down the failed stream before re-subscribing — the
          // plugin has a single event sink, and a late cancel would
          // otherwise kill the new subscription.
          await _positionSub?.cancel();
          _positionSub = null;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (_state.isTracking && _positionSub == null) {
            _subscribePositions(forceLocationManager: true);
          }
        }
      },
    );
  }

  Future<Ride?> stopRide() async {
    if (!_state.isTracking) return null;

    await _positionSub?.cancel();
    _positionSub = null;

    final ride = _state.currentRide!;
    // Flush everything not yet confirmed written (covers both the regular
    // tail and any batches whose earlier write failed) so the persisted ride
    // is complete before we hand control back to the UI.
    if (_pointsBuffer.length > _persistedCount) {
      await _repo.appendPoints(_pointsBuffer.sublist(_persistedCount));
      _persistedCount = _pointsBuffer.length;
    }

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

    // Fire-and-forget weather enrichment. The first sync push has already
    // been scheduled by the upsert above (debounced 1.5 s); when weather
    // arrives we upsert the ride again, which triggers a second push. If
    // Open-Meteo is unreachable the ride still syncs without weather, and
    // the detail screen's "Wetter abrufen" retry button can fix it later.
    // ignore: unawaited_futures
    WeatherService.enrichRide(repo: _repo, rideId: finalized.id);

    return finalized;
  }

  void _onPosition(Position pos) async {
    final ride = _state.currentRide;
    if (ride == null) return;

    // While manually paused we still get fixes but throw them away —
    // distance/duration must not accumulate through a coffee stop. Auto-pause
    // does NOT skip points: the rider may resume mid-stride and we want the
    // ramp-up speed in the data.
    if (_state.isManuallyPaused) return;

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
    // write cost. _persistedCount only advances after the write succeeds, so
    // a failed batch is included again in the next flush.
    if (_pointsBuffer.length - _persistedCount >= 10) {
      final batch = _pointsBuffer.sublist(_persistedCount);
      final upTo = _pointsBuffer.length;
      // ignore: unawaited_futures
      _repo.appendPoints(batch).then((_) {
        if (upTo > _persistedCount) _persistedCount = upTo;
      }).catchError((Object e) {
        debugPrint('[motorider] RideTracker batch write failed (will retry): $e');
      });
    }

    // Auto-pause heuristic.
    final speedKmh = (pos.speed >= 0 ? pos.speed : 0) * 3.6;
    final now = pos.timestamp;
    final wasAutoPaused = _state.isAutoPaused;
    bool isAutoPaused;
    if (speedKmh >= _movingThresholdKmh) {
      _lastMovingTs = now;
      isAutoPaused = false;
    } else {
      final lastMoving = _lastMovingTs ?? now;
      isAutoPaused = now.difference(lastMoving) >= _pauseAfter;
    }

    final stats = computeStats(_pointsBuffer);
    _emit(_state.copyWith(
      isAutoPaused: isAutoPaused,
      stats: stats,
      lastPoint: point,
      pointsCount: _pointsBuffer.length,
    ));

    if (!wasAutoPaused && isAutoPaused) {
      debugPrint('[motorider] RideTracker auto-paused');
    } else if (wasAutoPaused && !isAutoPaused) {
      debugPrint('[motorider] RideTracker resumed (auto)');
    }
  }

  /// User-initiated pause. Subsequent GPS fixes are dropped until [resumeRide]
  /// flips the flag back. Polyline will have a gap; stats skip the interval.
  void pauseRide() {
    if (!_state.isTracking || _state.isManuallyPaused) return;
    _emit(_state.copyWith(isManuallyPaused: true));
    debugPrint('[motorider] RideTracker manually paused');
  }

  void resumeRide() {
    if (!_state.isTracking || !_state.isManuallyPaused) return;
    // Reset the moving-timestamp so the auto-pause heuristic doesn't
    // immediately flip back to paused on the first fix after resume.
    _lastMovingTs = DateTime.now();
    _emit(_state.copyWith(isManuallyPaused: false));
    debugPrint('[motorider] RideTracker manually resumed');
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

  LocationSettings _locationSettings({bool forceLocationManager = false}) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      forceLocationManager: forceLocationManager,
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
