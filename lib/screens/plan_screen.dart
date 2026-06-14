import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/curviness.dart';
import '../models/planned_route.dart';
import '../services/geo.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../services/road_snap_service.dart';
import '../services/routing_service.dart';
import '../services/tile_cache.dart';
import '../theme.dart';
import 'navigation_screen.dart';

/// User-Agent for tile + routing requests (OSM policy asks for an identifiable
/// agent). Kept short and tied to the package id.
const String kUserAgent = 'MotoRider/1.0 (ch.tleuthold.motorider)';
const String kOsmTiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Plan-and-navigate screen. Tap to drop tour points, long-press to bend the
/// route through a spot, drag any point to fine-tune, pick how curvy you want
/// it, then save or start live navigation.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  final _controller = MapController();
  final _router = RoutingService();
  final _geocoder = GeocodingService();
  final _roadSnap = RoadSnapService();

  /// Vias are soft guides: the route only has to pass within this many metres of
  /// a via, taking the best road there, rather than threading exactly through
  /// the dropped pin (which can force a detour onto a tiny lane).
  static const double _viaSnapRadiusM = 500;

  static const _swissCenter = LatLng(46.8182, 8.2275);

  final List<LatLng> _waypoints = [];
  Curviness _curviness = Curviness.balanced;

  RouteResult? _route;
  bool _routing = false;
  String? _error;
  int _reqId = 0;

  // Drag state for waypoint fine-tuning. Driven by a raw pointer Listener
  // (see build) so the gesture can't be stolen by the map's pan recogniser:
  // on pointer-down over a waypoint we capture it AND disable map dragging for
  // the duration, then move it by converting pointer positions through the
  // live camera.
  int? _dragIndex;
  LatLng? _dragLatLng;
  Offset? _downPos;
  bool _moved = false;
  static const double _grabRadiusPx = 40;

  int? _selected; // selected waypoint index (for the action chip)
  bool _didFit = false;

  LatLng? _userPos;
  bool _locating = false;

  Timer? _rerouteTimer;

  // Place search (Photon autocomplete). Picking a result drops a waypoint,
  // same as tapping the map.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<GeoPlace> _searchResults = const [];
  bool _searching = false;
  Timer? _searchDebounce;
  int _searchReqId = 0;

  TileCache? _tileCache;
  CachedTileProvider? _tileProvider;

  @override
  void initState() {
    super.initState();
    _initTileCache();
    _seedStartFromLocation();
  }

  Future<void> _initTileCache() async {
    final cache = await TileCache.instance();
    if (!mounted) return;
    setState(() {
      _tileCache = cache;
      _tileProvider = CachedTileProvider(
        cache: cache,
        // Mutable on purpose: flutter_map's TileLayer injects a User-Agent into
        // this map, so it must not be const/unmodifiable.
        headers: {'User-Agent': kUserAgent},
      );
    });
  }

  @override
  void dispose() {
    _rerouteTimer?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _router.dispose();
    _geocoder.dispose();
    _roadSnap.dispose();
    _tileProvider?.dispose();
    super.dispose();
  }

  // ───────────────────────────── Editing ─────────────────────────────────

  LatLng _wpPos(int i) =>
      (_dragIndex == i && _dragLatLng != null) ? _dragLatLng! : _waypoints[i];

  void _addWaypoint(LatLng p) {
    setState(() {
      _waypoints.add(p);
      _selected = _waypoints.length - 1;
    });
    _scheduleReroute(immediate: true);
  }

  /// Long-press: insert a via at the leg of the existing route nearest to [p],
  /// so the line bends through there. Falls back to append when there are < 2
  /// points yet.
  void _insertVia(LatLng p) {
    if (_waypoints.length < 2) {
      _addWaypoint(p);
      return;
    }
    final snap = snapToPath(p, _waypoints);
    final insertAt = (snap?.segmentIndex ?? _waypoints.length - 2) + 1;
    setState(() {
      _waypoints.insert(insertAt, p);
      _selected = insertAt;
    });
    _scheduleReroute(immediate: true);
  }

  void _deleteSelected() {
    final i = _selected;
    if (i == null || i >= _waypoints.length) return;
    setState(() {
      _waypoints.removeAt(i);
      _selected = null;
      if (_waypoints.length < 2) _route = null;
    });
    _scheduleReroute(immediate: true);
  }

  void _makeSelectedStart() {
    final i = _selected;
    if (i == null || i == 0) return;
    setState(() {
      final wp = _waypoints.removeAt(i);
      _waypoints.insert(0, wp);
      _selected = 0;
    });
    _scheduleReroute(immediate: true);
  }

  void _reverse() {
    setState(() {
      final r = _waypoints.reversed.toList();
      _waypoints
        ..clear()
        ..addAll(r);
      _selected = null;
    });
    _scheduleReroute(immediate: true);
  }

  void _clearAll() {
    setState(() {
      _waypoints.clear();
      _route = null;
      _error = null;
      _selected = null;
      _didFit = false;
    });
  }

  /// Reset the planning canvas to a blank tour: drops the current waypoints,
  /// route and search so the rider can plan a fresh one (e.g. after loading a
  /// saved tour). Does NOT delete any saved tours — those live in [routeRepo].
  void _newTour() {
    _clearAll();
    _clearSearch();
  }

  /// Nearest waypoint to a screen point, if within [_grabRadiusPx].
  int? _waypointAt(Offset localPx) {
    final cam = _controller.camera;
    int? best;
    var bestD2 = _grabRadiusPx * _grabRadiusPx;
    for (var i = 0; i < _waypoints.length; i++) {
      final sp = cam.latLngToScreenPoint(_waypoints[i]);
      final dx = sp.x - localPx.dx;
      final dy = sp.y - localPx.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = i;
      }
    }
    return best;
  }

  void _onPointerDown(PointerDownEvent e) {
    final i = _waypointAt(e.localPosition);
    if (i == null) return; // let the map handle pans / taps on empty space
    setState(() {
      _dragIndex = i;
      _dragLatLng = _waypoints[i];
      _downPos = e.localPosition;
      _moved = false;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_dragIndex == null) return;
    final from = _downPos;
    if (from != null && (e.localPosition - from).distance > 6) _moved = true;
    final cam = _controller.camera;
    setState(() => _dragLatLng = cam.pointToLatLng(
        math.Point<double>(e.localPosition.dx, e.localPosition.dy)));
  }

  void _cancelDrag() {
    if (_dragIndex == null) return;
    setState(() {
      _dragIndex = null;
      _dragLatLng = null;
      _downPos = null;
    });
  }

  void _onPointerUp(PointerUpEvent e) {
    final i = _dragIndex;
    if (i == null) return;
    if (_moved && _dragLatLng != null) {
      setState(() {
        _waypoints[i] = _dragLatLng!;
        _selected = i;
        _dragIndex = null;
        _dragLatLng = null;
        _downPos = null;
      });
      _scheduleReroute(immediate: true);
    } else {
      // No real movement → treat as a tap that selects / deselects the point.
      setState(() {
        _selected = _selected == i ? null : i;
        _dragIndex = null;
        _dragLatLng = null;
        _downPos = null;
      });
    }
  }

  // ──────────────────────────── Routing ──────────────────────────────────

  void _scheduleReroute({bool immediate = false}) {
    _rerouteTimer?.cancel();
    if (_waypoints.length < 2) {
      setState(() {
        _route = null;
        _error = null;
      });
      return;
    }
    _rerouteTimer = Timer(
      Duration(milliseconds: immediate ? 60 : 350),
      _reroute,
    );
  }

  Future<void> _reroute() async {
    if (_waypoints.length < 2) return;
    final req = ++_reqId;
    setState(() {
      _routing = true;
      _error = null;
    });
    try {
      final routingWps = await _routingWaypoints();
      if (!mounted || req != _reqId) return;
      final r = await _router.route(
        waypoints: routingWps,
        curviness: _curviness,
      );
      if (!mounted || req != _reqId) return;
      setState(() {
        _route = r;
        _routing = false;
      });
      if (!_didFit) {
        _didFit = true;
        _fit(r.geometry);
      }
    } on RoutingException catch (e) {
      if (!mounted || req != _reqId) return;
      setState(() {
        _routing = false;
        _error = e.message;
      });
    }
  }

  /// The waypoint list actually sent to the router. Start and end stay exactly
  /// where the rider dropped them, but each intermediate via is softened: it's
  /// snapped to the nearest proper road within [_viaSnapRadiusM] so the route
  /// passes *near* it on a sensible road instead of being forced through
  /// whatever lane the pin sits on. The on-screen pins are untouched — only the
  /// routing coordinate moves. Snap misses (offline, no road in range) fall back
  /// to the raw pin, so routing always proceeds.
  Future<List<LatLng>> _routingWaypoints() async {
    final wps = List.of(_waypoints);
    if (wps.length <= 2) return wps; // no vias to soften
    return Future.wait([
      for (var i = 0; i < wps.length; i++)
        (i == 0 || i == wps.length - 1)
            ? Future.value(wps[i])
            : _roadSnap
                .nearestRoad(wps[i], radiusMeters: _viaSnapRadiusM)
                .then((snapped) => snapped ?? wps[i])
                .catchError((Object _) => wps[i]),
    ]);
  }

  void _setCurviness(Curviness c) {
    if (c == _curviness) return;
    setState(() => _curviness = c);
    _scheduleReroute(immediate: true);
  }

  // ──────────────────────────── Search ───────────────────────────────────

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final q = value.trim();
    if (q.length < GeocodingService.minQueryLength) {
      setState(() {
        _searchResults = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce =
        Timer(const Duration(milliseconds: 320), () => _runSearch(q));
  }

  Future<void> _runSearch(String query) async {
    final req = ++_searchReqId;
    LatLng? bias;
    try {
      bias = _controller.camera.center;
    } catch (_) {
      bias = null; // map not laid out yet
    }
    try {
      final results = await _geocoder.search(query, bias: bias);
      if (!mounted || req != _searchReqId) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } on GeocodingException catch (e) {
      debugPrint('[motorider] search FAILED for "$query": ${e.message}');
      if (!mounted || req != _searchReqId) return;
      setState(() {
        _searchResults = const [];
        _searching = false;
      });
    }
  }

  void _pickSearchResult(GeoPlace place) {
    FocusScope.of(context).unfocus();
    _searchDebounce?.cancel();
    _searchReqId++; // drop any in-flight response
    setState(() {
      _searchCtrl.clear();
      _searchResults = const [];
      _searching = false;
    });
    _addWaypoint(place.position); // adds + selects + schedules a reroute
    if (_waypoints.length >= 2) {
      _fit(_waypoints);
    } else {
      _controller.move(place.position, 13);
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchReqId++;
    setState(() {
      _searchCtrl.clear();
      _searchResults = const [];
      _searching = false;
    });
    FocusScope.of(context).unfocus();
  }

  // ──────────────────────────── Camera ───────────────────────────────────

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _controller.move(pts.first, 13);
      return;
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.fromLTRB(60, 130, 60, 260),
      ),
    );
  }

  void _zoom(double d) {
    final cam = _controller.camera;
    _controller.move(cam.center, (cam.zoom + d).clamp(3.0, 18.0));
  }

  /// On open, drop the rider's current location as the start waypoint so a tour
  /// defaults to "from here". Silent if location is unavailable (no permission /
  /// no fix) — the manual tap-to-set-start flow still works. Skips seeding if a
  /// waypoint was already placed (e.g. the rider tapped before the fix arrived).
  Future<void> _seedStartFromLocation() async {
    // Runs from initState before the first build, so set the flag directly -
    // setState is neither needed nor allowed here.
    _locating = true;
    LocationResult? res;
    try {
      res = await LocationService.getCurrent();
    } catch (_) {
      res = null; // location stack unavailable (e.g. no plugin under test)
    }
    if (!mounted) return;
    var seeded = false;
    setState(() {
      _locating = false;
      final pos = res?.position;
      if (pos != null) {
        final p = LatLng(pos.latitude, pos.longitude);
        _userPos = p;
        if (_waypoints.isEmpty) {
          _waypoints.add(p);
          seeded = true;
        }
      }
    });
    if (seeded) {
      try {
        _controller.move(_userPos!, 12);
      } catch (_) {
        // Map not laid out yet — initialCenter holds until the rider pans.
      }
    }
  }

  Future<void> _locateMe() async {
    setState(() => _locating = true);
    final res = await LocationService.getCurrent();
    if (!mounted) return;
    setState(() => _locating = false);
    if (res.position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.error ?? 'Standort nicht verfügbar')),
      );
      return;
    }
    final p = LatLng(res.position!.latitude, res.position!.longitude);
    setState(() => _userPos = p);
    _controller.move(p, 13);
  }

  // ──────────────────────────── Persistence ──────────────────────────────

  Future<void> _save() async {
    final route = _route;
    if (route == null) return;
    final defaultName = 'Tour ${DateFormat('dd.MM.').format(DateTime.now())}';
    final name = await _promptName(defaultName);
    if (name == null) return;
    final pr = PlannedRoute(
      name: name.trim().isEmpty ? defaultName : name.trim(),
      waypoints: List.of(_waypoints),
      geometry: route.geometry,
      curviness: _curviness,
      distanceM: route.distanceM,
      durationS: route.durationS,
      ascentM: route.ascentM,
      curvinessScore: route.curviness,
    );
    await routeRepo.upsert(pr);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('„${pr.name}" gespeichert')),
    );
  }

  Future<String?> _promptName(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tour speichern'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  void _loadRoute(PlannedRoute pr) {
    setState(() {
      _waypoints
        ..clear()
        ..addAll(pr.waypoints);
      _curviness = pr.curviness;
      _route = pr.geometry.length >= 2
          ? RouteResult(
              geometry: pr.geometry,
              distanceM: pr.distanceM,
              durationS: pr.durationS,
              ascentM: pr.ascentM,
              curviness: pr.curvinessScore,
              profile: pr.curviness.profile,
            )
          : null;
      _selected = null;
      _error = null;
      _didFit = true;
    });
    if (pr.geometry.isNotEmpty) _fit(pr.geometry);
  }

  Future<void> _openSavedRoutes() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SavedRoutesSheet(
        onOpen: (pr) {
          Navigator.of(ctx).pop();
          _loadRoute(pr);
        },
      ),
    );
  }

  // ──────────────────────────── Navigation ───────────────────────────────

  void _navigate() {
    final route = _route;
    if (route == null || _tileCache == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NavigationScreen(
        geometry: route.geometry,
        durationS: route.durationS,
        waypoints: List.of(_waypoints),
        tileCache: _tileCache!,
        curviness: _curviness,
        maneuvers: route.maneuvers,
      ),
    ));
  }

  // ──────────────────────────── Offline tiles ────────────────────────────

  Future<void> _downloadOffline() async {
    final route = _route;
    final cache = _tileCache;
    if (route == null || cache == null) return;
    const zooms = [11, 12, 13, 14];
    const buffer = 550.0;
    final count = cache.estimateTileCount(route.geometry, zooms, buffer);
    final approxMb = (count * 16 / 1024).toStringAsFixed(0);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Offline speichern'),
        content: Text(
          'Lädt rund $count Kartenkacheln entlang der Route (~$approxMb MB), '
          'damit die Karte auch ohne Empfang funktioniert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Laden'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _runDownload(cache, route.geometry, zooms, buffer);
  }

  Future<void> _runDownload(
    TileCache cache,
    List<LatLng> geometry,
    List<int> zooms,
    double buffer,
  ) async {
    var cancelled = false;
    final progress = ValueNotifier<TileDownloadProgress>(
      const TileDownloadProgress(done: 0, total: 1),
    );
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Karte wird geladen'),
        content: ValueListenableBuilder<TileDownloadProgress>(
          valueListenable: progress,
          builder: (_, p, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: p.total == 0 ? 1 : p.fraction,
                backgroundColor: AppColors.gridLine,
              ),
              const SizedBox(height: 12),
              Text('${p.done} / ${p.total} Kacheln',
                  style: const TextStyle(color: AppColors.textMuted)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(ctx).pop();
            },
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );

    final sub = cache
        .downloadCorridor(
          route: geometry,
          urlTemplate: kOsmTiles,
          headers: const {'User-Agent': kUserAgent},
          zooms: zooms,
          bufferMeters: buffer,
          shouldCancel: () => cancelled,
        )
        .listen((p) => progress.value = p);
    await sub.asFuture<void>().catchError((_) {});
    await sub.cancel();
    if (mounted && !cancelled) {
      Navigator.of(context, rootNavigator: true).pop(); // close progress dialog
      final p = progress.value;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(p.failed > 0
              ? '${p.done - p.failed} Kacheln gespeichert (${p.failed} fehlgeschlagen)'
              : '${p.done} Kacheln offline gespeichert'),
        ),
      );
    }
    await dialog; // ensure dialog future completes
    progress.dispose();
  }

  // ─────────────────────────────── Build ─────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasRoute = _route != null;
    return Scaffold(
      body: Stack(
        children: [
          Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) => _cancelDrag(),
            child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _swissCenter,
              initialZoom: 8,
              minZoom: 3,
              maxZoom: 18,
              onTap: (_, p) {
                if (_searchResults.isNotEmpty || _searchCtrl.text.isNotEmpty) {
                  _clearSearch();
                }
                _addWaypoint(p);
              },
              onLongPress: (_, p) => _insertVia(p),
              // While dragging a waypoint, map panning is off so the gesture
              // can't be hijacked into a map pan.
              interactionOptions: InteractionOptions(
                flags: _dragIndex == null
                    ? InteractiveFlag.all & ~InteractiveFlag.rotate
                    : InteractiveFlag.none,
                enableMultiFingerGestureRace: true,
                pinchZoomThreshold: 0.3,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: kOsmTiles,
                userAgentPackageName: 'ch.tleuthold.motorider',
                maxNativeZoom: 19,
                tileProvider: _tileProvider,
              ),
              // Faint straight guide between waypoints before/while routing.
              if (_waypoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [for (var i = 0; i < _waypoints.length; i++) _wpPos(i)],
                      strokeWidth: 2,
                      color: AppColors.textMuted.withValues(alpha: 0.45),
                      pattern: StrokePattern.dotted(),
                    ),
                  ],
                ),
              if (hasRoute)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _route!.geometry,
                      strokeWidth: 6,
                      color: _curvinessColor(_curviness),
                      borderStrokeWidth: 2,
                      borderColor: Colors.black.withValues(alpha: 0.35),
                    ),
                  ],
                ),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          ),

          // Top bar + place search.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(
                      routing: _routing,
                      onSaved: _openSavedRoutes,
                      onNewTour: _newTour,
                      onReverse: _waypoints.length >= 2 ? _reverse : null,
                    ),
                    const SizedBox(height: 8),
                    _SearchBar(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      searching: _searching,
                      hasText: _searchCtrl.text.isNotEmpty,
                      onChanged: _onSearchChanged,
                      onClear: _clearSearch,
                    ),
                    if (_searchResults.isNotEmpty) _buildSearchResults(),
                  ],
                ),
              ),
            ),
          ),

          if (_error != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 76),
                  child: _ErrorBanner(message: _error!),
                ),
              ),
            ),

          // Right-side map controls.
          Positioned(
            right: 16,
            bottom: hasRoute || _waypoints.isNotEmpty ? 268 : 120,
            child: Column(
              children: [
                _MapBtn(icon: Icons.add_rounded, onTap: () => _zoom(1)),
                const SizedBox(height: 8),
                _MapBtn(icon: Icons.remove_rounded, onTap: () => _zoom(-1)),
                const SizedBox(height: 8),
                _MapBtn(
                  icon: Icons.my_location_rounded,
                  busy: _locating,
                  onTap: _locating ? null : _locateMe,
                ),
              ],
            ),
          ),

          // Bottom panel: hint, selection chip, curviness, summary.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _BottomPanel(
                  waypointCount: _waypoints.length,
                  selectedIndex: _selected,
                  selectedIsStart: _selected == 0,
                  onDeleteSelected: _deleteSelected,
                  onMakeStart: _makeSelectedStart,
                  onDeselect: () => setState(() => _selected = null),
                  curviness: _curviness,
                  onCurviness: _setCurviness,
                  route: _route,
                  routing: _routing,
                  onSave: hasRoute ? _save : null,
                  onNavigate: hasRoute ? _navigate : null,
                  onOffline: hasRoute ? _downloadOffline : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    if (_userPos != null) {
      markers.add(Marker(
        point: _userPos!,
        width: 26,
        height: 26,
        child: const _UserDot(),
      ));
    }
    for (var i = 0; i < _waypoints.length; i++) {
      final isStart = i == 0;
      final isEnd = i == _waypoints.length - 1 && _waypoints.length >= 2;
      final selected = _selected == i;
      markers.add(Marker(
        point: _wpPos(i),
        width: 44,
        height: 44,
        // Centred on the coordinate so the pointer hit-test (in _waypointAt)
        // lines up with what the rider grabs.
        child: _WaypointPin(
          index: i,
          isStart: isStart,
          isEnd: isEnd,
          selected: selected,
          dragging: _dragIndex == i,
        ),
      ));
    }
    return markers;
  }

  Widget _buildSearchResults() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _searchResults.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: AppColors.gridLine),
          itemBuilder: (context, i) {
            final r = _searchResults[i];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.place_rounded,
                  color: AppColors.accent, size: 20),
              title: Text(
                r.primary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.text, fontWeight: FontWeight.w700),
              ),
              subtitle: (r.secondary == null || r.secondary!.isEmpty)
                  ? null
                  : Text(
                      r.secondary!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12),
                    ),
              onTap: () => _pickSearchResult(r),
            );
          },
        ),
      ),
    );
  }
}

Color _curvinessColor(Curviness c) => switch (c) {
      Curviness.fast => const Color(0xFF38BDF8),
      Curviness.balanced => const Color(0xFF34D399),
      Curviness.curvy => AppColors.accentSoft,
      Curviness.extra => AppColors.accent,
    };

// ─────────────────────────────── Widgets ─────────────────────────────────

/// Place-search field (Photon autocomplete). Results are rendered separately
/// by the screen so taps land in its state.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.hasText,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.search_rounded, size: 20, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(
                  color: AppColors.text, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Ort suchen — Start oder Ziel',
                hintStyle: TextStyle(color: AppColors.textMuted),
              ),
            ),
          ),
          if (searching)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent),
              ),
            )
          else if (hasText)
            IconButton(
              tooltip: 'Leeren',
              onPressed: onClear,
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.routing,
    required this.onSaved,
    required this.onNewTour,
    required this.onReverse,
  });
  final bool routing;
  final VoidCallback onSaved;
  final VoidCallback onNewTour;
  final VoidCallback? onReverse;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        children: [
          const Icon(Icons.alt_route_rounded, color: AppColors.accent, size: 20),
          const SizedBox(width: 8),
          const Text(
            'Planen',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
              letterSpacing: -0.2,
            ),
          ),
          if (routing) ...[
            const SizedBox(width: 10),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accent),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Route umkehren',
            onPressed: onReverse,
            icon: const Icon(Icons.swap_vert_rounded),
            color: AppColors.textMuted,
          ),
          IconButton(
            tooltip: 'Gespeicherte Touren',
            onPressed: onSaved,
            icon: const Icon(Icons.folder_open_rounded),
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 2),
          // Explicit "start over" action — wipes the current waypoints/route so
          // a fresh tour can be planned (e.g. after loading a saved one).
          // Doesn't delete saved tours.
          TextButton.icon(
            onPressed: onNewTour,
            icon: const Icon(Icons.add_road_rounded, size: 18),
            label: const Text('Neue Tour'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.waypointCount,
    required this.selectedIndex,
    required this.selectedIsStart,
    required this.onDeleteSelected,
    required this.onMakeStart,
    required this.onDeselect,
    required this.curviness,
    required this.onCurviness,
    required this.route,
    required this.routing,
    required this.onSave,
    required this.onNavigate,
    required this.onOffline,
  });

  final int waypointCount;
  final int? selectedIndex;
  final bool selectedIsStart;
  final VoidCallback onDeleteSelected;
  final VoidCallback onMakeStart;
  final VoidCallback onDeselect;
  final Curviness curviness;
  final ValueChanged<Curviness> onCurviness;
  final RouteResult? route;
  final bool routing;
  final VoidCallback? onSave;
  final VoidCallback? onNavigate;
  final VoidCallback? onOffline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (waypointCount == 0)
            const _Hint(
              icon: Icons.touch_app_rounded,
              text: 'Tippe auf die Karte, um Start und Ziel zu setzen. '
                  'Langes Drücken biegt die Route über einen Punkt.',
            )
          else if (selectedIndex != null) ...[
            _SelectionRow(
              index: selectedIndex!,
              isStart: selectedIsStart,
              onDelete: onDeleteSelected,
              onMakeStart: onMakeStart,
              onClose: onDeselect,
            ),
            const SizedBox(height: 12),
          ] else if (waypointCount == 1)
            const _Hint(
              icon: Icons.add_location_alt_rounded,
              text: 'Tippe das Ziel — danach kannst du Punkte ziehen oder die '
                  'Kurvigkeit wählen.',
            ),

          // Curviness selector.
          Row(
            children: [
              const Icon(Icons.turn_sharp_right_rounded,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              const Text('Kurvigkeit',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.text)),
              const Spacer(),
              Text(curviness.label,
                  style: const TextStyle(
                      color: AppColors.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.gridLine,
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: curviness.index.toDouble(),
              min: 0,
              max: 3,
              divisions: 3,
              label: curviness.label,
              onChanged: (v) => onCurviness(Curviness.fromIndex(v.round())),
            ),
          ),

          if (route != null) ...[
            const SizedBox(height: 2),
            _SummaryRow(route: route!),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onNavigate,
                    icon: const Icon(Icons.navigation_rounded, size: 18),
                    label: const Text('Navigieren'),
                  ),
                ),
                const SizedBox(width: 10),
                _SquareAction(
                  icon: Icons.save_outlined,
                  tooltip: 'Speichern',
                  onTap: onSave,
                ),
                const SizedBox(width: 8),
                _SquareAction(
                  icon: Icons.download_for_offline_outlined,
                  tooltip: 'Offline-Karte',
                  onTap: onOffline,
                ),
              ],
            ),
          ] else if (waypointCount >= 2 && routing) ...[
            const SizedBox(height: 4),
            const Text('Route wird berechnet …',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

class _SelectionRow extends StatelessWidget {
  const _SelectionRow({
    required this.index,
    required this.isStart,
    required this.onDelete,
    required this.onMakeStart,
    required this.onClose,
  });
  final int index;
  final bool isStart;
  final VoidCallback onDelete;
  final VoidCallback onMakeStart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.place_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text('Punkt ${index + 1}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: AppColors.text)),
          const Spacer(),
          if (!isStart)
            TextButton(
                onPressed: onMakeStart, child: const Text('Als Start')),
          IconButton(
            tooltip: 'Punkt löschen',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: AppColors.danger,
          ),
          IconButton(
            tooltip: 'Schliessen',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
            color: AppColors.textMuted,
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.route});
  final RouteResult route;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Stat(
          icon: Icons.straighten_rounded,
          value: '${route.distanceKm.toStringAsFixed(1)} km',
          label: 'Strecke',
        ),
        _Stat(
          icon: Icons.schedule_rounded,
          value: _fmtDuration(route.duration),
          label: 'Fahrzeit',
        ),
        if (route.ascentM != null)
          _Stat(
            icon: Icons.terrain_rounded,
            value: '${route.ascentM!.round()} m',
            label: 'Anstieg',
          ),
        _Stat(
          icon: Icons.turn_slight_right_rounded,
          value: route.curviness.round().toString(),
          label: '°/km',
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.label});
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.textMuted),
              const SizedBox(width: 4),
              Flexible(
                child: Text(value,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                        fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

class _SquareAction extends StatelessWidget {
  const _SquareAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.gridLine),
            ),
            child: Icon(icon,
                color: enabled ? AppColors.text : AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.accentSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 13, height: 1.3)),
          ),
        ],
      ),
    );
  }
}

class _MapBtn extends StatelessWidget {
  const _MapBtn({required this.icon, this.onTap, this.busy = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gridLine),
          ),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accent),
                )
              : Icon(icon, color: AppColors.text),
        ),
      ),
    );
  }
}

/// Pin used for tour waypoints. Start is a flag, end a checkered flag, vias are
/// numbered dots. Tip is at the bottom-centre (marker anchored topCenter).
class _WaypointPin extends StatelessWidget {
  const _WaypointPin({
    required this.index,
    required this.isStart,
    required this.isEnd,
    required this.selected,
    required this.dragging,
  });
  final int index;
  final bool isStart;
  final bool isEnd;
  final bool selected;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final color = isStart
        ? const Color(0xFF34D399)
        : isEnd
            ? AppColors.accent
            : AppColors.accentSoft;
    final icon = isStart
        ? Icons.play_arrow_rounded
        : isEnd
            ? Icons.flag_rounded
            : null;
    return Center(
      child: AnimatedScale(
        scale: dragging ? 1.35 : (selected ? 1.15 : 1.0),
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: selected ? Colors.white : Colors.black26, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: icon != null
              ? Icon(icon, size: 18, color: Colors.black)
              : Center(
                  child: Text('${index + 1}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          fontSize: 13)),
                ),
        ),
      ),
    );
  }
}

class _UserDot extends StatelessWidget {
  const _UserDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.accent.withValues(alpha: 0.25),
      ),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            border: Border.all(color: Colors.white, width: 2.5),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet listing saved tours, with open + delete.
class _SavedRoutesSheet extends StatelessWidget {
  const _SavedRoutesSheet({required this.onOpen});
  final ValueChanged<PlannedRoute> onOpen;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PlannedRoute>>(
      initialData: routeRepo.latest,
      stream: routeRepo.watchAll(),
      builder: (context, snap) {
        final routes = snap.data ?? const <PlannedRoute>[];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Gespeicherte Touren',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text)),
                const SizedBox(height: 12),
                if (routes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('Noch keine Tour gespeichert.',
                        style: TextStyle(color: AppColors.textMuted)),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: routes.length,
                      separatorBuilder: (_, __) => const Divider(
                          height: 1, color: AppColors.gridLine),
                      itemBuilder: (context, i) {
                        final r = routes[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor:
                                _curvinessColor(r.curviness).withValues(alpha: 0.2),
                            child: Icon(Icons.route_rounded,
                                color: _curvinessColor(r.curviness), size: 20),
                          ),
                          title: Text(r.name,
                              style: const TextStyle(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            '${r.distanceKm.toStringAsFixed(1)} km · '
                            '${_fmtDuration(r.duration)} · ${r.curviness.label}',
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline_rounded,
                                color: AppColors.textMuted),
                            onPressed: () => routeRepo.delete(r.id),
                          ),
                          onTap: () => onOpen(r),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
