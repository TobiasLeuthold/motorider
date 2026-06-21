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
    this.estimated = false,
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

  /// True when this position was *dead-reckoned* — advanced along the route at
  /// the last known speed because real GPS fixes stopped arriving (a tunnel,
  /// a deep cutting, …) rather than measured from a fresh fix. The UI uses it
  /// to show a "position estimated" hint; everything else treats it like a
  /// normal on-route state so guidance keeps flowing.
  final bool estimated;

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
    this.coastMinSpeedKmh = 8,
    this.coastMaxSeconds = 240,
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

  /// Below this last-known speed (km/h) we do NOT dead-reckon through a GPS
  /// gap. A rider stopped at a tunnel mouth or a red light should keep a
  /// frozen puck, not be coasted forward into a turn they haven't taken.
  final double coastMinSpeedKmh;

  /// Hard ceiling (seconds) on how long a single GPS gap is dead-reckoned.
  /// Position error grows the longer we coast blind; past this we hold the last
  /// estimate instead of drifting indefinitely. Tunnels are usually far shorter,
  /// and a constant-speed line follows them well, so this rarely bites.
  final double coastMaxSeconds;

  final List<double> _cum;
  final List<_TurnAt> _turns = [];
  int _offStreak = 0;
  LatLng? _lastRaw;
  double? _lastCourse;

  /// The rider's current matched progress along the route, in metres from the
  /// start. Maintained by *windowed* snapping (see [update]): each fix is matched
  /// near this value rather than to the globally nearest point on the line, so a
  /// route that revisits a point can't teleport progress to the later occurrence.
  /// Starts at 0; the first fix re-acquires here if navigation begins partway
  /// along the route.
  double _along = 0;

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

  /// How far ahead of / behind the current matched progress the windowed snap
  /// looks. Forward is generous enough to absorb a multi-second GPS gap at speed
  /// yet far shorter than any real loop, so the match can't jump to a point
  /// revisited further along the route; backward only soaks up GPS jitter. A fix
  /// landing well outside this window (a genuine detour / shortcut) triggers a
  /// global re-acquire instead.
  static const double _fwdWindowM = 350.0;
  static const double _backWindowM = 120.0;

  /// Max cross-track-equivalent penalty (metres) applied to a windowed match
  /// whose segment points against the rider's direction of travel. It
  /// disambiguates an exact retrace (out-and-back on the same road) toward the
  /// leg actually being travelled, without overriding a genuinely closer match
  /// elsewhere. See [snapToPathWindowed].
  static const double _headingPenaltyM = 80.0;

  /// The global re-acquire only overrides the windowed match when it is at least
  /// this much closer (cross-track). At a revisited point both matches sit on
  /// top of the rider (≈ equal cross-track), so the windowed — sequentially
  /// correct — one is kept; only a real displacement past the window makes the
  /// global match decisively closer.
  static const double _reacquireMarginM = 20.0;

  /// Latches true once the rider has reached the destination. Arrival never
  /// un-fires (see where it's set), which keeps a round-trip finish stable even
  /// though its closing fix is spatially ambiguous with the start.
  bool _arrived = false;

  // ── Dead reckoning through GPS gaps (tunnels) ──
  /// Last real on-route speed (km/h); drives how fast we coast through a gap.
  double? _lastSpeedKmh;
  /// Synthetic along-route position while coasting; seeded from the last real
  /// fix and advanced by [coast].
  double _coastAlong = 0;
  /// How long the current uninterrupted GPS gap has been dead-reckoned, in
  /// seconds. Reset to zero on every real [update].
  double _coastedSeconds = 0;
  /// True once at least one real fix has been processed — there's nothing to
  /// coast from before that.
  bool _hadFix = false;
  /// Whether the last real fix was off-route. We never coast off-route: the
  /// route line isn't where the rider is, so advancing along it would be wrong.
  bool _lastOffRoute = false;

  final _controller = StreamController<NavState>.broadcast();
  NavState _state = const NavState.initial();
  NavState get state => _state;
  Stream<NavState> get changes => _controller.stream;

  double get totalMeters => _cum.isEmpty ? 0 : _cum.last;

  void update(NavFix fix) {
    if (geometry.length < 2) return;

    // Map-match the fix to the route. Crucially this is *windowed* around the
    // rider's current progress, not a global nearest-point search: on a route
    // that revisits a point (an out-and-back, or a loop that returns to an
    // earlier junction) the global nearest can latch onto that point's *later*
    // pass, teleporting progress forward and skipping the loop. Matching near
    // where the rider actually is keeps them on the leg they're on.
    //
    // A global snap is kept as a fallback, used when the rider has clearly moved
    // beyond the window and it is decisively closer — a genuine detour, or the
    // first fix when navigation starts partway along the route (the window is
    // anchored at 0 until the first match lands, so a far start re-acquires here).
    // This also defeats the round-trip trap (start ≈ finish): at the start the
    // windowed match near 0 wins over a global snap that may sit on the final
    // segment, so progress anchors at the start, not the end.
    //
    // The rider's travel direction tells apart the two passes of a retraced road:
    // the GPS course if present, else the bearing of movement since the last fix.
    // Null when stationary / on the first move — then the snap is heading-agnostic.
    final riderHeading = fix.headingDeg ?? _bearingFromLastRaw(fix.position);
    final windowed = snapToPathWindowed(
      fix.position,
      geometry,
      _along - _backWindowM,
      _along + _fwdWindowM,
      cumulative: _cum,
      headingDeg: riderHeading,
      headingPenaltyM: _headingPenaltyM,
    );
    final global = snapToPath(fix.position, geometry, cumulative: _cum);
    if (global == null) return;
    final SnapResult snap = (windowed == null ||
            global.crossTrackMeters <
                windowed.crossTrackMeters - _reacquireMarginM)
        ? global
        : windowed;
    _along = snap.alongMeters.clamp(0.0, totalMeters);

    final along = _along;
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

    // A real fix landed: reset the dead-reckoning state so a later GPS gap
    // coasts forward from *here* at *this* speed.
    _hadFix = true;
    _lastOffRoute = offRoute;
    _coastAlong = along;
    _coastedSeconds = 0;
    if (fix.speedKmh != null) _lastSpeedKmh = fix.speedKmh;

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

  /// Advance the rider's *estimated* position along the route while real GPS
  /// fixes are missing — the tunnel case. Instead of letting the puck freeze
  /// (which makes turn-by-turn impossible to follow), we coast forward along the
  /// route at the last known speed and keep emitting [NavState]s, flagged
  /// [NavState.estimated], so distance/ETA/turn cues all keep updating.
  ///
  /// Pure compute: the screen drives this on a ~1 Hz timer once it notices fixes
  /// have stopped. It is a deliberate no-op (the puck simply holds its last
  /// position) when there's nothing safe to extrapolate from:
  ///   - no real fix yet, or the destination is already reached;
  ///   - the last fix was off-route (the line isn't where the rider is);
  ///   - the rider was last seen essentially stopped (< [coastMinSpeedKmh]) —
  ///     a red light or tunnel mouth, where inventing motion would be wrong;
  ///   - we've already coasted past [coastMaxSeconds] (bound the blind drift).
  ///
  /// A returning real fix snaps everything back to truth via [update].
  void coast(Duration elapsed) {
    if (geometry.length < 2 || !_hadFix || _arrived || _lastOffRoute) return;
    final v = _lastSpeedKmh;
    if (v == null || v < coastMinSpeedKmh) return;

    _coastedSeconds += elapsed.inMilliseconds / 1000.0;
    if (_coastedSeconds <= coastMaxSeconds) {
      final stepM = (v / 3.6) * (elapsed.inMilliseconds / 1000.0);
      _coastAlong = (_coastAlong + stepM).clamp(0.0, totalMeters);
    }

    // Keep the windowed-snap anchor following the dead-reckoned position. The
    // returning real fix after the gap is map-matched within a window around
    // [_along] (see [update]); if [_along] stayed frozen at the gap's *start*, a
    // gap longer than the forward window would land the rider's true position
    // outside it, forcing the occurrence-blind global re-acquire — which on a
    // self-crossing route teleports progress onto the wrong pass (the very loop
    // bug the windowed snap exists to prevent). Advancing [_along] with the coast
    // keeps that window centred on where the rider actually is, so the fix lands
    // inside it and the occurrence-aware snap resolves it. (We deliberately do
    // NOT touch [_maxAlong] — arrival must still come only from a real fix.)
    _along = _coastAlong;

    final along = _coastAlong;
    final remaining = (totalMeters - along).clamp(0.0, totalMeters);
    final frac = totalMeters == 0 ? 1.0 : (along / totalMeters);
    final remainingSeconds = (totalDurationS * (1.0 - frac)).round();

    final at = _onLineAt(along);
    final course = at.seg + 1 < geometry.length
        ? bearingDeg(geometry[at.seg], geometry[at.seg + 1])
        : _lastCourse;
    if (course != null) _lastCourse = course;

    Maneuver? nextManeuver;
    double nextManeuverMeters = 0;
    for (final t in _turns) {
      if (t.along > along + 8) {
        nextManeuver = t.m;
        nextManeuverMeters = t.along - along;
        break;
      }
    }

    // Note: dead reckoning never advances the arrival high-water mark or fires
    // arrival — only a real fix may end the tour, so a long tunnel near the
    // finish can't auto-complete it from an estimate.
    _emit(NavState(
      raw: null,
      snapped: at.point,
      speedKmh: v,
      remainingMeters: remaining,
      remainingSeconds: remainingSeconds,
      traveledFraction: frac,
      alongMeters: along,
      offRouteMeters: 0,
      offRoute: false,
      arrived: _arrived,
      nextManeuver: nextManeuver,
      nextManeuverMeters: nextManeuverMeters,
      courseDeg: course,
      estimated: true,
    ));
  }

  /// The point on the route [along] metres from the start, plus the index of
  /// the segment it falls on (so `geometry[seg]→geometry[seg+1]` gives the
  /// local bearing). Clamped to the route's ends.
  ({LatLng point, int seg}) _onLineAt(double along) {
    final a = along.clamp(0.0, totalMeters);
    var i = 1;
    while (i < _cum.length - 1 && _cum[i] < a) {
      i++;
    }
    final segLen = _cum[i] - _cum[i - 1];
    final t = segLen == 0 ? 0.0 : (a - _cum[i - 1]) / segLen;
    final p0 = geometry[i - 1], p1 = geometry[i];
    final point = LatLng(
      p0.latitude + (p1.latitude - p0.latitude) * t,
      p0.longitude + (p1.longitude - p0.longitude) * t,
    );
    return (point: point, seg: i - 1);
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
