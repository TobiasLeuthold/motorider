import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/curviness.dart';
import '../services/geo.dart';
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
  });

  final List<LatLng> geometry;
  final int durationS;
  final List<LatLng> waypoints;
  final TileCache tileCache;
  final Curviness curviness;

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
    _nav = _buildNavigator(_geometry, widget.durationS);
    _subscribeNav();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.move(_geometry.first, _navZoom);
    });
    _startGps();
    // Recording the trip as a tour is part of "navigating", so auto-start it —
    // the rider never has to remember to hit "Tour starten".
    _startAutoTracking();
  }

  RouteNavigator _buildNavigator(List<LatLng> geom, int durationS) =>
      RouteNavigator(geometry: geom, totalDurationS: durationS);

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
    if (_follow && s.snapped != null) {
      _controller.move(s.snapped!, _controller.camera.zoom);
    }
    // Reached the destination → automatically end the tour. Fires once, on the
    // transition into "arrived".
    if (s.arrived && !wasArrived) {
      _finishAutoTracking();
    }
  }

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

  Future<void> _toggleSimulate() async {
    if (_simulating) {
      await _stopSim();
      await _startGps();
      return;
    }
    // Switch to simulation.
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
    _nav = _buildNavigator(r.geometry, r.durationS);
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
    final p = _state.snapped ?? _geometry.first;
    _controller.move(p, _navZoom);
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
                ],
              ),
              MarkerLayer(
                markers: [
                  // Destination flag.
                  Marker(
                    point: _geometry.last,
                    width: 34,
                    height: 34,
                    child: const _DestFlag(),
                  ),
                  if (s.snapped != null)
                    Marker(
                      point: s.snapped!,
                      width: 40,
                      height: 40,
                      child: _Chevron(headingDeg: s.headingDeg ?? 0),
                    ),
                ],
              ),
            ],
          ),

          // Top stats card.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: _NavTopCard(
                  remainingKm: s.remainingKm,
                  remainingSeconds: s.remainingSeconds,
                  eta: eta,
                  speedKmh: s.speedKmh,
                  onClose: () => Navigator.of(context).maybePop(),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gridLine),
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
        height: 34,
        color: AppColors.gridLine,
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
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: AppColors.text,
                letterSpacing: -0.5,
              ),
              children: [
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 10)),
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
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.gridLine,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onSimulate,
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        simulating ? AppColors.accent : AppColors.textMuted,
                    side: BorderSide(
                        color: simulating
                            ? AppColors.accent
                            : AppColors.gridLine),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: Icon(simulating
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline_rounded),
                  label: Text(simulating ? 'Simulation stoppen' : 'Simulieren'),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: onExit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.surfaceHi,
                  foregroundColor: AppColors.text,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                ),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Ende'),
              ),
            ],
          ),
        ],
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
        color: AppColors.danger.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Abseits der Route (${meters.round()} m)',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700),
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
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
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
    final fg = dark ? Colors.black : AppColors.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.96 : 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// Direction chevron drawn at the snapped position, rotated to heading.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.headingDeg});
  final double headingDeg;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: headingDeg * 3.1415926535 / 180.0,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accent,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.navigation_rounded, color: Colors.black, size: 22),
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
