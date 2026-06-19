import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'maneuvers.dart';

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
    this.alongMeters = 0,
    this.offRouteMeters = 0,
    this.offRoute = false,
    this.arrived = false,
    this.nextManeuver,
    this.nextManeuverMeters = 0,
    this.courseDeg,
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

  /// Distance from the route start to the snapped position, in meters. The live
  /// split point for colouring already-passed vs. upcoming route.
  final double alongMeters;

  final double offRouteMeters; // perpendicular distance to the route
  final bool offRoute;
  final bool arrived;

  /// The next turn ahead (null near the end or when there are no maneuvers).
  final Maneuver? nextManeuver;

  /// Distance along the route to [nextManeuver], in meters.
  final double nextManeuverMeters;

  /// Direction of travel in degrees (0 = north, clockwise). Drives the
  /// heading-up map rotation. On-route this is the bearing of the route at the
  /// snapped position (smooth); off-route it's the rider's GPS course.
  final double? courseDeg;

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
    this.maneuvers = const [],
    this.offRouteThresholdM = 45,
    this.offRouteStreakNeeded = 3,
    this.arriveRadiusM = 35,
    this.arriveProgressFraction = 0.9,
  }) : _cum = cumulativeMeters(geometry) {
    for (final m in maneuvers) {
      if (m.isTurn && m.geometryIndex >= 0 && m.geometryIndex < _cum.length) {
        _turns.add(_TurnAt(m, _cum[m.geometryIndex]));
      }
    }
    _turns.sort((a, b) => a.along.compareTo(b.along));
  }

  final List<LatLng> geometry;
  final int totalDurationS;
  final List<Maneuver> maneuvers;
  final double offRouteThresholdM;
  final int offRouteStreakNeeded;
  final double arriveRadiusM;

  /// Fraction of the route's total length the rider must have progressed
  /// through before the destination radius is armed. This is what defeats the
  /// round-trip case: when start ≈ finish, a fix at the *start* can snap onto
  /// the route's final segment (it's spatially near the end), which alone would
  /// report `remaining ≈ 0` and trip arrival instantly. Requiring the rider to
  /// have actually advanced through most of the polyline first means the
  /// destination radius only goes live once they've done the loop. For a plain
  /// A→B route the rider naturally crosses this near the end, so arrival still
  /// fires there. Default 0.9 (≈ last tenth of the route).
  final double arriveProgressFraction;

  final List<double> _cum;
  final List<_TurnAt> _turns = [];
  int _offStreak = 0;
  LatLng? _lastRaw;
  double? _lastCourse;

  /// High-water mark of how far along the route the rider has genuinely
  /// reached, in meters. Only advances (never rewinds), so passing spatially
  /// near the end early in a loop can't fake progress — the rider has to have
  /// actually travelled there. Drives the arrival gate.
  double _maxAlong = 0;

  /// Most the progress high-water mark may grow per fix, in meters. At ~1 Hz
  /// this caps believable advancement: 250 m/tick tolerates a fast motorcycle
  /// plus a few seconds of GPS gap, while still being far smaller than a typical
  /// loop, so a start-of-loop snap onto the final segment (a multi-km jump) is
  /// rejected instead of faking arrival.
  static const double _maxJumpM = 250.0;

  /// Latches true once the rider has reached the destination. Arrival never
  /// un-fires (see where it's set), which keeps a round-trip finish stable even
  /// though its closing fix is spatially ambiguous with the start.
  bool _arrived = false;

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

    // Advance the progress high-water mark, but reject implausible forward
    // jumps. On a round trip (start ≈ finish) a fix at the *start* can snap onto
    // the route's *final* segment, yielding `along ≈ totalMeters`. Accepting
    // that would arm arrival instantly. A real rider can't teleport: between
    // ~1 Hz fixes they advance at most a vehicle's worth of distance, so we only
    // let the mark grow by a bounded step per update (with a generous cap for
    // GPS gaps / fast travel). The first fix seeds the mark directly so a route
    // that genuinely starts mid-line still tracks correctly.
    if (_maxAlong == 0 && along <= _maxJumpM) {
      _maxAlong = along;
    } else if (along > _maxAlong) {
      _maxAlong = math.min(along, _maxAlong + _maxJumpM);
    }
    // The destination radius is only armed once the rider has progressed through
    // most of the route (so they've actually done the loop, not just started
    // near where it ends). Crossing into the final portion can land just shy of
    // the radius, so also accept being within the radius of the very end vertex.
    final progressedEnough =
        _maxAlong >= totalMeters * arriveProgressFraction ||
            _maxAlong >= totalMeters - arriveRadiusM;
    // Arrival is sticky: once the rider has genuinely reached the destination we
    // stay "arrived". This matters for a round trip whose finish coincides with
    // its start — the closing fix is spatially ambiguous and can snap back onto
    // the route's *first* segment (remaining ≈ total), which would otherwise
    // flip arrival off again right after it fired.
    final arrived = _arrived ||
        (progressedEnough &&
            remaining <= arriveRadiusM &&
            snap.crossTrackMeters <= offRouteThresholdM);
    _arrived = arrived;

    // Next turn ahead: first maneuver more than 8 m past the current position
    // (so we don't keep announcing one we're already on top of).
    Maneuver? nextManeuver;
    double nextManeuverMeters = 0;
    for (final t in _turns) {
      if (t.along > along + 8) {
        nextManeuver = t.m;
        nextManeuverMeters = t.along - along;
        break;
      }
    }

    // Direction of travel for the heading-up map. On the route, the bearing of
    // the current segment is smooth and reliable; off the route, the rider's
    // actual GPS course (or the bearing they're moving along) is what matters.
    final routeCourse = snap.segmentIndex + 1 < geometry.length
        ? bearingDeg(geometry[snap.segmentIndex], geometry[snap.segmentIndex + 1])
        : null;
    double? course;
    if (offRoute) {
      course = fix.headingDeg ?? _bearingFromLastRaw(fix.position) ?? _lastCourse;
    } else {
      course = routeCourse ?? fix.headingDeg ?? _lastCourse;
    }
    if (course != null) _lastCourse = course;
    _lastRaw = fix.position;

    _emit(NavState(
      raw: fix.position,
      snapped: snap.point,
      speedKmh: fix.speedKmh,
      headingDeg: fix.headingDeg,
      remainingMeters: remaining,
      remainingSeconds: remainingSeconds,
      traveledFraction: frac,
      alongMeters: along,
      offRouteMeters: snap.crossTrackMeters,
      offRoute: offRoute,
      arrived: arrived,
      nextManeuver: nextManeuver,
      nextManeuverMeters: nextManeuverMeters,
      courseDeg: course,
    ));
  }

  /// Bearing from the previous raw fix to [p], or null if we haven't moved far
  /// enough for it to be meaningful.
  double? _bearingFromLastRaw(LatLng p) {
    final last = _lastRaw;
    if (last == null || haversineMeters(last, p) < 4) return null;
    return bearingDeg(last, p);
  }

  void _emit(NavState s) {
    _state = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// A maneuver with its precomputed distance from the route start.
class _TurnAt {
  const _TurnAt(this.m, this.along);
  final Maneuver m;
  final double along;
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
