import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// A single position update feeding navigation. Comes either from the GPS
/// ([NavGps]) or, for testing on an emulator, from [RouteSimulator].
class NavFix {
  const NavFix({
    required this.position,
    this.speedKmh,
    this.headingDeg,
  });
  final LatLng position;
  final double? speedKmh;
  final double? headingDeg;
}

/// Immutable snapshot of where the rider is relative to the route.
class NavState {
  const NavState({
    this.raw,
    this.snapped,
    this.speedKmh,
    this.headingDeg,
    this.remainingMeters = 0,
    this.remainingSeconds = 0,
    this.traveledFraction = 0,
    this.offRouteMeters = 0,
    this.offRoute = false,
    this.arrived = false,
  });

  const NavState.initial() : this();

  /// Raw GPS position.
  final LatLng? raw;

  /// Position snapped onto the route line (what we draw the chevron at).
  final LatLng? snapped;

  final double? speedKmh;
  final double? headingDeg;

  final double remainingMeters;
  final int remainingSeconds;
  final double traveledFraction; // 0..1 along the route
  final double offRouteMeters; // perpendicular distance to the route
  final bool offRoute;
  final bool arrived;

  double get remainingKm => remainingMeters / 1000.0;
}

/// Tracks progress of a [NavFix] stream along a fixed route: snaps each fix to
/// the line, computes remaining distance + ETA, and debounces an off-route
/// flag. Pure compute — the screen owns the fix source and reacts to
/// [changes].
class RouteNavigator {
  RouteNavigator({
    required this.geometry,
    required this.totalDurationS,
    this.offRouteThresholdM = 45,
    this.offRouteStreakNeeded = 3,
    this.arriveRadiusM = 35,
  }) : _cum = cumulativeMeters(geometry);

  final List<LatLng> geometry;
  final int totalDurationS;
  final double offRouteThresholdM;
  final int offRouteStreakNeeded;
  final double arriveRadiusM;

  final List<double> _cum;
  int _offStreak = 0;

  final _controller = StreamController<NavState>.broadcast();
  NavState _state = const NavState.initial();
  NavState get state => _state;
  Stream<NavState> get changes => _controller.stream;

  double get totalMeters => _cum.isEmpty ? 0 : _cum.last;

  void update(NavFix fix) {
    if (geometry.length < 2) return;
    final snap = snapToPath(fix.position, geometry, cumulative: _cum);
    if (snap == null) return;

    final along = snap.alongMeters.clamp(0.0, totalMeters);
    final remaining = (totalMeters - along).clamp(0.0, totalMeters);
    final frac = totalMeters == 0 ? 1.0 : (along / totalMeters);
    final remainingSeconds = (totalDurationS * (1.0 - frac)).round();

    final isOff = snap.crossTrackMeters > offRouteThresholdM;
    _offStreak = isOff ? _offStreak + 1 : 0;
    final offRoute = _offStreak >= offRouteStreakNeeded;

    final arrived = remaining <= arriveRadiusM &&
        snap.crossTrackMeters <= offRouteThresholdM;

    _emit(NavState(
      raw: fix.position,
      snapped: snap.point,
      speedKmh: fix.speedKmh,
      headingDeg: fix.headingDeg,
      remainingMeters: remaining,
      remainingSeconds: remainingSeconds,
      traveledFraction: frac,
      offRouteMeters: snap.crossTrackMeters,
      offRoute: offRoute,
      arrived: arrived,
    ));
  }

  void _emit(NavState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Live GPS as a [NavFix] stream. Thin wrapper over Geolocator with the same
/// high-accuracy / 1 Hz / foreground-service settings the ride tracker uses, so
/// navigation keeps running with the screen off.
///
/// Mirrors [RideTracker]'s fused→LocationManager fallback: the fused (Google
/// Play services) provider can't satisfy its settings check on emulators and
/// degoogled devices, so on that failure we fall back to the raw Android
/// LocationManager instead of silently emitting nothing.
class NavGps {
  StreamSubscription<Position>? _sub;
  final _controller = StreamController<NavFix>.broadcast();
  bool _started = false;

  Stream<NavFix> get stream => _controller.stream;

  /// Ensures permission, then starts streaming. Returns false if location is
  /// unavailable / denied.
  Future<bool> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    _started = true;
    _subscribe(forceLocationManager: false);
    return true;
  }

  void _subscribe({required bool forceLocationManager}) {
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        forceLocationManager: forceLocationManager,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Navigation läuft',
          notificationText: 'MotoRider führt dich entlang der Tour',
          enableWakeLock: true,
          setOngoing: true,
        ),
      ),
    ).listen(
      (pos) {
        _controller.add(NavFix(
          position: LatLng(pos.latitude, pos.longitude),
          speedKmh: pos.speed >= 0 ? pos.speed * 3.6 : null,
          headingDeg: pos.heading >= 0 ? pos.heading : null,
        ));
      },
      onError: (Object e) async {
        if (!forceLocationManager &&
            _started &&
            e is LocationServiceDisabledException) {
          await _sub?.cancel();
          _sub = null;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (_started && _sub == null) {
            _subscribe(forceLocationManager: true);
          }
        }
      },
    );
  }

  Future<void> stop() async {
    _started = false;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Drives a synthetic [NavFix] stream that walks along [route] at roughly
/// [speedKmh] (slowing through tight bends), emitting ~1 Hz. Lets navigation be
/// exercised end-to-end on an emulator that has no real movement. Optional
/// [lateralNoiseM] nudges fixes sideways to exercise off-route handling.
class RouteSimulator {
  RouteSimulator({
    required this.route,
    this.speedKmh = 55,
    this.lateralNoiseM = 0,
  }) : _cum = cumulativeMeters(route);

  final List<LatLng> route;
  final double speedKmh;
  final double lateralNoiseM;
  final List<double> _cum;

  Timer? _timer;
  double _along = 0;
  int _tick = 0;
  final _controller = StreamController<NavFix>.broadcast();
  Stream<NavFix> get stream => _controller.stream;

  double get _total => _cum.isEmpty ? 0 : _cum.last;
  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null || route.length < 2) return;
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _step());
  }

  void _step() {
    final stepM = speedKmh / 3.6; // meters per ~1s tick
    _along += stepM;
    _tick++;
    if (_along >= _total) {
      _along = _total;
      _emitAt(_along);
      stop();
      return;
    }
    _emitAt(_along);
  }

  void _emitAt(double along) {
    // Find the segment containing `along`.
    var i = 1;
    while (i < _cum.length - 1 && _cum[i] < along) {
      i++;
    }
    final segLen = _cum[i] - _cum[i - 1];
    final t = segLen == 0 ? 0.0 : (along - _cum[i - 1]) / segLen;
    final a = route[i - 1], b = route[i];
    var pos = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    final heading = bearingDeg(a, b);
    if (lateralNoiseM != 0) {
      // Push sideways (perpendicular to heading) by a slowly oscillating amount
      // to exercise off-route detection.
      final sign = (_tick ~/ 4).isEven ? 1.0 : -1.0;
      const mPerLat = 111320.0;
      final perp = (heading + 90) * math.pi / 180.0;
      final dN = lateralNoiseM * sign * math.cos(perp) / mPerLat;
      final cosLat =
          math.cos(pos.latitude * math.pi / 180.0).abs().clamp(0.01, 1.0);
      final dE = lateralNoiseM * sign * math.sin(perp) / (mPerLat * cosLat);
      pos = LatLng(pos.latitude + dN, pos.longitude + dE);
    }
    _controller.add(NavFix(position: pos, speedKmh: speedKmh, headingDeg: heading));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void reset() {
    _along = 0;
    _tick = 0;
  }

  Future<void> dispose() async {
    stop();
    await _controller.close();
  }
}
