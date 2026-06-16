import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/curviness.dart';
import '../models/ride_point.dart';
import '../services/geo.dart';
import '../services/maneuvers.dart';
import '../services/ride_tracker.dart';
import '../services/route_navigator.dart';
import '../services/routing_service.dart';
import '../services/tile_cache.dart';
import '../theme.dart';
import 'plan_screen.dart' show kUserAgent, kOsmTiles;

/// Live-follow navigation along a planned route. Snaps the rider to the line,
/// shows remaining distance + ETA, warns (and offers a reroute) when they leave
/// the route, and can be driven by a [RouteSimulator] for emulator testing.
class NavigationScreen extends StatefulWidget {
  const NavigationScreen({
    super.key,
    required this.geometry,
    required this.durationS,
    required this.waypoints,
    required this.tileCache,
    this.curviness = Curviness.balanced,
    this.maneuvers = const [],
  });

  final List<LatLng> geometry;
  final int durationS;
  final List<LatLng> waypoints;
  final TileCache tileCache;
  final Curviness curviness;
  final List<Maneuver> maneuvers;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final _controller = MapController();
  final _router = RoutingService();

  late List<LatLng> _geometry;
  late RouteNavigator _nav;
  late CachedTileProvider _tileProvider;

  // Destination waypoints still to reach (everything after the start). Used to
  // reroute from the current position when off-route.
  late List<LatLng> _remainingDest;

  StreamSubscription<NavState>? _navSub;
  StreamSubscription<NavFix>? _fixSub;
  // When recording, navigation is driven by the ride tracker's GPS stream
  // (a single shared location source) instead of a second [NavGps].
  StreamSubscription<TrackerState>? _trackerFixSub;
  NavGps? _gps;
  RouteSimulator? _sim;

  NavState _state = const NavState.initial();
  bool _simulating = false;
  bool _follow = true;
  bool _rerouting = false;
  String? _gpsError;
  // True only when THIS screen auto-started the ride tracker. Lets us end the
  // tour exactly once and never stop a tour the rider began manually.
  bool _autoTracking = false;
  static const _navZoom = 15.5;

  // Current (smoothed) follow-zoom — eased toward the speed-adaptive target so
  // it never jumps.
  double _zoom = _navZoom;

  // Current (smoothed) map rotation in degrees. The map is turned so the
  // direction of travel points up (Google-Maps style); 0 = north up.
  double _mapRotation = 0;

  // Off-route: the BRouter path from where the rider actually is back onto the
  // planned route (to the nearest point on it). Null while on-route.
  List<LatLng>? _backToRoute;
  bool _backComputing = false;
  DateTime? _lastBackAt;
  LatLng? _lastBackFrom;

  @override
  void initState() {
    super.initState();
    _geometry = widget.geometry;
    _remainingDest = widget.waypoints.length > 1
        ? widget.waypoints.sublist(1)
        : [widget.geometry.last];
    _tileProvider = CachedTileProvider(
      cache: widget.tileCache,
      // Mutable on purpose: TileLayer injects a User-Agent into this map.
      headers: {'User-Agent': kUserAgent},
    );
    _nav = _buildNavigator(_geometry, widget.durationS, widget.maneuvers);
    _subscribeNav();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.move(_geometry.first, _navZoom);
    });
    _startSession();
  }

  RouteNavigator _buildNavigator(
    List<LatLng> geom,
    int durationS,
    List<Maneuver> maneuvers,
  ) =>
      RouteNavigator(
        geometry: geom,
        totalDurationS: durationS,
        maneuvers: maneuvers,
        // A rider parks *near* the destination, not exactly on the end node;
        // 35 m was too tight and often never latched "arrived" (so the tour
        // never auto-ended). 60 m reliably detects arrival without false
        // positives mid-route.
        arriveRadiusM: 60,
      );

  void _subscribeNav() {
    _navSub = _nav.changes.listen(_onNavState);
  }

  void _onNavState(NavState s) {
    if (!mounted) return;
    final wasArrived = _state.arrived;
    // Consume vias as we pass them, so a reroute targets only what's ahead.
    final raw = s.raw;
    if (raw != null && _remainingDest.length > 1) {
      if (haversineMeters(raw, _remainingDest.first) < 60) {
        _remainingDest.removeAt(0);
      }
    }
    setState(() => _state = s);
    // Where to centre: the real position when off-route (so the rider sees they
    // left the line), the snapped point when on it (smooth).
    final displayPos = (s.offRoute ? s.raw : s.snapped) ?? s.snapped ?? s.raw;
    if (_follow && displayPos != null) {
      // Ease the zoom toward the speed-adaptive target so it changes smoothly.
      final targetZoom = navZoomForSpeed(s.speedKmh ?? 0);
      _zoom += (targetZoom - _zoom) * 0.2;
      // Heading-up: rotate the map so the direction of travel points up, eased
      // along the shortest angular path so it never spins.
      if (s.courseDeg != null) {
        _mapRotation = _easeAngleDeg(_mapRotation, -s.courseDeg!, 0.25);
      }
      _controller.moveAndRotate(displayPos, _zoom, _mapRotation);
    }
    // Reached the destination → automatically end the tour. Fires once, on the
    // transition into "arrived".
    if (s.arrived && !wasArrived) {
      _finishAutoTracking();
    }
    // Keep the "way back to the route" path in sync with the off-route state.
    _ensureBackToRoute(s);
  }

  /// Ease an angle (degrees) toward [target] along the shortest path so the
  /// 359°→1° wrap doesn't cause a near-full spin.
  static double _easeAngleDeg(double current, double target, double t) {
    var d = (target - current) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return current + d * t;
  }

  /// While off-route, compute (and keep fresh) a route from where the rider
  /// actually is back to the nearest point on the planned route. Throttled so
  /// we don't hammer BRouter; falls back to a straight line if routing fails.
  Future<void> _ensureBackToRoute(NavState s) async {
    if (!s.offRoute) {
      if (_backToRoute != null && mounted) setState(() => _backToRoute = null);
      return;
    }
    final raw = s.raw;
    final target = s.snapped;
    if (raw == null || target == null || _backComputing) return;
    final now = DateTime.now();
    final fresh = _backToRoute != null &&
        _lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 5) &&
        _lastBackFrom != null &&
        haversineMeters(_lastBackFrom!, raw) < 40;
    if (fresh) return;
    _backComputing = true;
    _lastBackAt = now;
    _lastBackFrom = raw;
    try {
      final r = await _router
          .route(waypoints: [raw, target], curviness: widget.curviness);
      if (mounted && _state.offRoute) setState(() => _backToRoute = r.geometry);
    } on RoutingException {
      // Offline / no road: at least show the direction back as a straight line.
      if (mounted && _state.offRoute) setState(() => _backToRoute = [raw, target]);
    } finally {
      _backComputing = false;
    }
  }

  /// Starts the navigation session. Recording the trip as a tour is part of
  /// "navigating", so we auto-start it — and, to avoid running two GPS streams
  /// (and two foreground-service notifications), the navigator is driven by the
  /// recorder's fixes whenever recording is active. A standalone [NavGps] is
  /// used only as a fallback when recording can't start.
  Future<void> _startSession() async {
    await _startAutoTracking();
    if (!mounted) return;
    if (rideTracker.state.isTracking) {
      _useTrackerFixes();
    } else {
      await _startGps();
    }
  }

  /// Feed the navigator from the ride tracker's GPS stream — the single shared
  /// location source while recording. Survives a reroute: the closure reads the
  /// current [_nav] field, so it keeps driving the rebuilt navigator.
  void _useTrackerFixes() {
    final last = rideTracker.state.lastPoint;
    if (last != null) _nav.update(_fixFromPoint(last));
    _trackerFixSub = rideTracker.changes.listen((s) {
      final p = s.lastPoint;
      if (p != null) _nav.update(_fixFromPoint(p));
    });
  }

  NavFix _fixFromPoint(RidePoint p) => NavFix(
        position: LatLng(p.lat, p.lon),
        speedKmh: p.speedMs == null ? null : p.speedMs! * 3.6,
        headingDeg: p.heading,
      );

  Future<void> _startGps() async {
    await _sim?.dispose();
    _sim = null;
    _simulating = false;
    final gps = NavGps();
    final ok = await gps.start();
    if (!mounted) return;
    if (!ok) {
      setState(() => _gpsError =
          'Kein GPS — tippe auf „Simulieren", um die Navigation zu testen.');
      await gps.dispose();
      return;
    }
    _gps = gps;
    setState(() => _gpsError = null);
    _fixSub = gps.stream.listen(_nav.update);
  }

  // ─────────────────────── Auto ride tracking ────────────────────────────

  /// Records this navigation as a tour, unless the rider already has one
  /// running (then theirs is left untouched). Best-effort: navigation still
  /// works if tracking can't start (e.g. location permission denied).
  Future<void> _startAutoTracking() async {
    if (rideTracker.state.isTracking) return;
    try {
      await rideTracker.startRide();
      if (!mounted) {
        // Screen was popped while the tracker was still starting — stop it so
        // it doesn't keep recording with no one left to end it.
        await rideTracker.stopRide();
        return;
      }
      _autoTracking = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tour wird nicht aufgezeichnet: $e')),
      );
    }
  }

  /// Stops and saves the auto-started tour. Idempotent — the [_autoTracking]
  /// guard plus RideTracker.stopRide()'s own guard make extra calls no-ops.
  Future<void> _finishAutoTracking() async {
    if (!_autoTracking) return;
    _autoTracking = false;
    final messenger = ScaffoldMessenger.of(context);
    await _trackerFixSub?.cancel();
    _trackerFixSub = null;
    final ride = await rideTracker.stopRide();
    if (ride == null || !mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Tour gespeichert: ${ride.distanceKm.toStringAsFixed(1)} km',
        ),
      ),
    );
  }

  /// Discards (does NOT save) the auto-started tour — used when the rider
  /// switches to simulation, so a junk ride recorded from the stationary real
  /// GPS isn't persisted. A manually-started tour is left untouched.
  Future<void> _discardAutoTracking() async {
    if (!_autoTracking) return;
    _autoTracking = false;
    await rideTracker.discardRide();
  }

  Future<void> _toggleSimulate() async {
    if (_simulating) {
      await _stopSim();
      // Resume the real fix source. The auto-tour was discarded on entering
      // simulation, so if nothing is recording, guidance falls back to GPS.
      if (rideTracker.state.isTracking) {
        _useTrackerFixes();
      } else {
        await _startGps();
      }
      return;
    }
    // Switch to simulation. Entering it is a test action, so stop feeding the
    // navigator from the tracker and discard the auto-started tour rather than
    // saving a junk (stationary) ride.
    await _trackerFixSub?.cancel();
    _trackerFixSub = null;
    await _discardAutoTracking();
    await _fixSub?.cancel();
    _fixSub = null;
    await _gps?.dispose();
    _gps = null;
    final sim = RouteSimulator(route: _geometry, speedKmh: 60);
    _sim = sim;
    setState(() {
      _simulating = true;
      _gpsError = null;
    });
    _fixSub = sim.stream.listen(_nav.update);
    sim.start();
  }

  Future<void> _stopSim() async {
    _sim?.stop();
    await _fixSub?.cancel();
    _fixSub = null;
    await _sim?.dispose();
    _sim = null;
    if (mounted) setState(() => _simulating = false);
  }

  Future<void> _reroute() async {
    final pos = _state.raw ?? _state.snapped;
    if (pos == null || _rerouting) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _rerouting = true);
    try {
      final wps = <LatLng>[pos, ..._remainingDest];
      final r = await _router.route(waypoints: wps, curviness: widget.curviness);
      if (!mounted) return;
      await _swapRoute(r);
      messenger.showSnackBar(
        const SnackBar(content: Text('Route neu berechnet')),
      );
    } on RoutingException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _rerouting = false);
    }
  }

  Future<void> _swapRoute(RouteResult r) async {
    final wasSimulating = _simulating;
    await _fixSub?.cancel();
    _fixSub = null;
    await _nav.dispose();
    await _sim?.dispose();
    _sim = null;

    setState(() => _geometry = r.geometry);
    _nav = _buildNavigator(r.geometry, r.durationS, r.maneuvers);
    _subscribeNav();

    if (wasSimulating) {
      final sim = RouteSimulator(route: _geometry, speedKmh: 60);
      _sim = sim;
      _fixSub = sim.stream.listen(_nav.update);
      sim.start();
    } else if (_gps != null) {
      _fixSub = _gps!.stream.listen(_nav.update);
    }
  }

  void _recenter() {
    setState(() => _follow = true);
    final s = _state;
    final p = (s.offRoute ? s.raw : s.snapped) ?? s.snapped ?? _geometry.first;
    _zoom = navZoomForSpeed(s.speedKmh ?? 0);
    if (s.courseDeg != null) _mapRotation = -s.courseDeg!;
    _controller.moveAndRotate(p, _zoom, _mapRotation);
  }

  @override
  void dispose() {
    // Left navigation before arriving → stop the auto-started tour so it
    // doesn't keep recording in the background. Fire-and-forget (the screen is
    // going away); stopRide() still persists the ride. No-op if arrival already
    // ended it.
    if (_autoTracking) {
      _autoTracking = false;
      rideTracker.stopRide();
    }
    _navSub?.cancel();
    _fixSub?.cancel();
    _trackerFixSub?.cancel();
    _gps?.dispose();
    _sim?.dispose();
    _nav.dispose();
    _router.dispose();
    _tileProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final eta = DateTime.now().add(Duration(seconds: s.remainingSeconds));
    final puckPos = (s.offRoute ? s.raw : s.snapped) ?? s.snapped ?? s.raw;
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _geometry.first,
              initialZoom: _navZoom,
              minZoom: 3,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              // Any manual gesture drops follow-mode until the user recenters.
              onPointerDown: (_, __) {
                if (_follow) setState(() => _follow = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: kOsmTiles,
                userAgentPackageName: 'ch.tleuthold.motorider',
                maxNativeZoom: 19,
                tileProvider: _tileProvider,
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _geometry,
                    strokeWidth: 7,
                    color: AppColors.accent,
                    borderStrokeWidth: 2.5,
                    borderColor: Colors.black.withValues(alpha: 0.4),
                  ),
                  // Off-route: the quickest way back onto the planned route.
                  if (s.offRoute &&
                      _backToRoute != null &&
                      _backToRoute!.length >= 2)
                    Polyline(
                      points: _backToRoute!,
                      strokeWidth: 6,
                      color: _backColor,
                      borderStrokeWidth: 2,
                      borderColor: Colors.black.withValues(alpha: 0.45),
                      pattern: StrokePattern.dotted(spacingFactor: 1.5),
                    ),
                ],
              ),
              MarkerLayer(
                // Counter-rotate markers against the heading-up map so they stay
                // screen-upright. Without this, flutter_map rotates each marker
                // *with* the map canvas, double-applying the rotation to the
                // puck (its angle already bakes in [_mapRotation]) — which left
                // the navigation arrow pointing at geographic north instead of
                // the direction of travel. It also keeps the destination flag
                // upright rather than tilting as the map turns.
                rotate: true,
                markers: [
                  // Destination flag.
                  Marker(
                    point: _geometry.last,
                    width: 34,
                    height: 34,
                    child: const _DestFlag(),
                  ),
                  // Where to rejoin the route, while off it.
                  if (s.offRoute && s.snapped != null)
                    Marker(
                      point: s.snapped!,
                      width: 20,
                      height: 20,
                      child: const _RejoinDot(),
                    ),
                  // The rider's position puck. Off-route it sits at the real GPS
                  // position so the rider can see they left the line.
                  if (puckPos != null)
                    Marker(
                      point: puckPos,
                      width: 46,
                      height: 46,
                      child: _NavPuck(
                        angleDeg: (s.courseDeg ?? 0) + _mapRotation,
                        offRoute: s.offRoute,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // Top: next-turn banner (Google-Maps style) + compact stats card.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Column(
                  children: [
                    if (s.nextManeuver != null && !s.offRoute && !s.arrived) ...[
                      _ManeuverBanner(
                        maneuver: s.nextManeuver!,
                        meters: s.nextManeuverMeters,
                      ),
                      const SizedBox(height: 8),
                    ],
                    _NavTopCard(
                      remainingKm: s.remainingKm,
                      remainingSeconds: s.remainingSeconds,
                      eta: eta,
                      speedKmh: s.speedKmh,
                      onClose: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_gpsError != null)
            Positioned(
              left: 16,
              right: 16,
              top: 120,
              child: _InfoBanner(
                color: AppColors.surfaceHi,
                icon: Icons.gps_off_rounded,
                text: _gpsError!,
              ),
            ),

          if (s.offRoute && !s.arrived)
            Positioned(
              left: 16,
              right: 16,
              bottom: 180,
              child: _OffRouteBanner(
                meters: s.offRouteMeters,
                rerouting: _rerouting,
                onReroute: _reroute,
              ),
            ),

          if (s.arrived)
            Positioned(
              left: 16,
              right: 16,
              bottom: 180,
              child: _InfoBanner(
                color: const Color(0xFF34D399),
                icon: Icons.flag_rounded,
                text: 'Ziel erreicht 🎉',
                dark: true,
              ),
            ),

          // Bottom controls.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_follow)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: FloatingActionButton.extended(
                            heroTag: 'recenter',
                            onPressed: _recenter,
                            backgroundColor: AppColors.surface,
                            foregroundColor: AppColors.accent,
                            icon: const Icon(Icons.my_location_rounded),
                            label: const Text('Zentrieren'),
                          ),
                        ),
                      ),
                    _NavBottomBar(
                      progress: s.traveledFraction,
                      simulating: _simulating,
                      onSimulate: _toggleSimulate,
                      onExit: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTopCard extends StatelessWidget {
  const _NavTopCard({
    required this.remainingKm,
    required this.remainingSeconds,
    required this.eta,
    required this.speedKmh,
    required this.onClose,
  });
  final double remainingKm;
  final int remainingSeconds;
  final DateTime eta;
  final double? speedKmh;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: _navPanel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _navBorder, width: 1.5),
      ),
      child: Row(
        children: [
          _NavStat(
            value: remainingKm >= 10
                ? remainingKm.toStringAsFixed(0)
                : remainingKm.toStringAsFixed(1),
            unit: 'km',
            label: 'Rest',
          ),
          _divider(),
          _NavStat(
            value: _fmtMin(remainingSeconds),
            unit: 'min',
            label: 'Fahrzeit',
          ),
          _divider(),
          _NavStat(
            value: DateFormat('HH:mm').format(eta),
            unit: '',
            label: 'Ankunft',
          ),
          _divider(),
          _NavStat(
            value: (speedKmh ?? 0).round().toString(),
            unit: 'km/h',
            label: 'Tempo',
          ),
          IconButton(
            tooltip: 'Beenden',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 38,
        color: _navBorder,
        margin: const EdgeInsets.symmetric(horizontal: 6),
      );

  static String _fmtMin(int seconds) {
    final m = (seconds / 60).round();
    if (m >= 60) {
      final h = m ~/ 60;
      return '${h}h${(m % 60).toString().padLeft(2, '0')}';
    }
    return '$m';
  }
}

class _NavStat extends StatelessWidget {
  const _NavStat({required this.value, required this.unit, required this.label});
  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            text: TextSpan(
              text: value,
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
              children: [
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFB9C4DC)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: Color(0xFFB9C4DC),
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _NavBottomBar extends StatelessWidget {
  const _NavBottomBar({
    required this.progress,
    required this.simulating,
    required this.onSimulate,
    required this.onExit,
  });
  final double progress;
  final bool simulating;
  final VoidCallback onSimulate;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: _navPanel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _navBorder, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: _navBorder,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Simulation is a testing aid — kept as a small, unobtrusive
              // icon rather than a prominent button you'd hit while riding.
              _SimToggleMini(simulating: simulating, onTap: onSimulate),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onExit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.surfaceHi,
                    foregroundColor: AppColors.text,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Navigation beenden'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small, low-key toggle for the GPS simulator. It's a developer/testing aid,
/// so it reads as a tiny icon (bug glyph) instead of a big button.
class _SimToggleMini extends StatelessWidget {
  const _SimToggleMini({required this.simulating, required this.onTap});
  final bool simulating;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = simulating ? AppColors.accent : AppColors.textMuted;
    return Tooltip(
      message: simulating ? 'Simulation stoppen' : 'Fahrt simulieren (Test)',
      child: Material(
        color: simulating
            ? AppColors.accent.withValues(alpha: 0.15)
            : AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: simulating ? AppColors.accent : AppColors.gridLine),
            ),
            child: Icon(
              simulating ? Icons.stop_rounded : Icons.bug_report_rounded,
              color: color,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

class _OffRouteBanner extends StatelessWidget {
  const _OffRouteBanner({
    required this.meters,
    required this.rerouting,
    required this.onReroute,
  });
  final double meters;
  final bool rerouting;
  final VoidCallback onReroute;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE0352B), // opaque, high-contrast red
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Abseits der Route (${meters.round()} m)',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15),
                ),
                const Text(
                  'Weg zurück ist eingezeichnet',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          rerouting
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                )
              : TextButton(
                  onPressed: onReroute,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    textStyle:
                        const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                  child: const Text('Neu berechnen'),
                ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.color,
    required this.icon,
    required this.text,
    this.dark = false,
  });
  final Color color;
  final IconData icon;
  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dark ? Colors.black26 : _navBorder, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: fg, fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ],
      ),
    );
  }
}

/// Colour of the "way back to the route" path + its rejoin dot.
const _backColor = Color(0xFF22D3EE);

// High-contrast, fully opaque panel colours for navigation: translucent panels
// wash out over a bright map in direct sun, so these are solid and near-black
// with a brighter border for separation.
const _navPanel = Color(0xFF0A0E1A);
const _navBorder = Color(0xFF3A4E78);

/// The rider's position puck. The navigation arrow points in the direction of
/// travel — [angleDeg] is the on-screen angle (already accounting for the map
/// rotation), so on a heading-up map it points straight up. Turns red when
/// off-route to flag the deviation.
class _NavPuck extends StatelessWidget {
  const _NavPuck({required this.angleDeg, required this.offRoute});
  final double angleDeg;
  final bool offRoute;

  @override
  Widget build(BuildContext context) {
    final color = offRoute ? const Color(0xFFFF3B30) : AppColors.accent;
    return Transform.rotate(
      angle: angleDeg * 3.1415926535 / 180.0,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Colors.white, width: 3.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 26),
      ),
    );
  }
}

/// Small marker at the nearest point on the route — where to rejoin it.
class _RejoinDot extends StatelessWidget {
  const _RejoinDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _backColor,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 4,
          ),
        ],
      ),
    );
  }
}

class _DestFlag extends StatelessWidget {
  const _DestFlag();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: AppColors.accent, width: 3),
      ),
      child: const Icon(Icons.flag_rounded, color: AppColors.accent, size: 18),
    );
  }
}

/// Google-Maps-style next-turn banner: a big direction arrow, the distance to
/// the turn, and the instruction.
class _ManeuverBanner extends StatelessWidget {
  const _ManeuverBanner({required this.maneuver, required this.meters});
  final Maneuver maneuver;
  final double meters;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.25), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(_maneuverIcon(maneuver), color: Colors.black, size: 54),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmtDist(meters),
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  maneuver.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _maneuverIcon(Maneuver m) {
  switch (m.command) {
    case 2:
      return Icons.turn_left;
    case 3:
      return Icons.turn_slight_left;
    case 4:
      return Icons.turn_sharp_left;
    case 5:
      return Icons.turn_right;
    case 6:
      return Icons.turn_slight_right;
    case 7:
      return Icons.turn_sharp_right;
    case 8:
      return Icons.turn_slight_left;
    case 9:
      return Icons.turn_slight_right;
    case 10:
      return Icons.u_turn_left;
    case 11:
      return Icons.u_turn_right;
    case 13:
    case 14:
      return Icons.roundabout_right;
    default:
      return Icons.straight;
  }
}

/// Round the distance-to-turn to a readable value ("Jetzt", "120 m", "1.3 km").
String _fmtDist(double m) {
  if (m < 30) return 'Jetzt';
  if (m < 1000) {
    final r = m < 100 ? (m / 10).round() * 10 : (m / 50).round() * 50;
    return '$r m';
  }
  return '${(m / 1000).toStringAsFixed(1)} km';
}
