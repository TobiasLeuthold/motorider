import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../services/location_service.dart';
import '../theme.dart';
import 'add_fillup_screen.dart';
import 'ride_detail_screen.dart';

/// Time windows offered by the date filter.
enum _DatePreset { all, d30, m3, y1 }

extension on _DatePreset {
  String get label => switch (this) {
        _DatePreset.all => 'Alle',
        _DatePreset.d30 => '30 Tage',
        _DatePreset.m3 => '3 Monate',
        _DatePreset.y1 => 'Jahr',
      };

  /// How far back the window reaches, or null for "all time".
  Duration? get window => switch (this) {
        _DatePreset.all => null,
        _DatePreset.d30 => const Duration(days: 30),
        _DatePreset.m3 => const Duration(days: 90),
        _DatePreset.y1 => const Duration(days: 365),
      };
}

// Price-per-litre colour scale: cheap (green) → mid (amber) → pricey (red).
const _cheapColor = Color(0xFF34D399);
const _midColor = Color(0xFFFBBF24);
const _priceyColor = Color(0xFFF87171);

// Cool, distinct colour for ride tracks so they read clearly against the
// warm orange fuel pins.
const _rideColor = Color(0xFF38BDF8);

/// Maps a normalised price `t` (0 = cheapest, 1 = priciest) to a marker colour.
Color priceColor(double t) {
  t = t.clamp(0.0, 1.0);
  return t < 0.5
      ? Color.lerp(_cheapColor, _midColor, t * 2)!
      : Color.lerp(_midColor, _priceyColor, (t - 0.5) * 2)!;
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.stream});

  /// Optional stream override for testing. Defaults to the global repo.
  final Stream<List<FillUp>>? stream;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final _controller = MapController();
  LatLng? _userPos;
  bool _locating = false;
  AnimationController? _rotationReset;

  _DatePreset _datePreset = _DatePreset.all;
  RangeValues? _priceFilter; // null = no price filter
  double _rotation = 0;
  bool _didInitialFit = false;

  // Layer visibility — keeps the map uncluttered by letting the user pick
  // what to see.
  bool _showFuel = true;
  bool _showRides = true;

  // Ride id → simplified track. Loaded lazily from the points table (rides can
  // hold thousands of points; we downsample for the overview).
  final Map<String, List<LatLng>> _ridePaths = {};
  final Set<String> _ridePathLoading = {};

  // Default to Switzerland's geographic center.
  static const _swissCenter = LatLng(46.8182, 8.2275);

  @override
  Widget build(BuildContext context) {
    final initial = widget.stream == null ? fillUpRepo.latest : const <FillUp>[];
    return Scaffold(
      body: StreamBuilder<List<FillUp>>(
        initialData: initial,
        stream: widget.stream ?? fillUpRepo.watchAll(),
        builder: (context, fuelSnap) {
          final allFuel = fuelSnap.data ?? const <FillUp>[];
          // Only real fill-ups with coordinates land on the map.
          final located = allFuel
              .where((f) =>
                  f.latitude != null && f.longitude != null && f.liters > 0)
              .toList();

          // Price bounds across all located fill-ups (drives colour + slider).
          double? pMin, pMax;
          for (final f in located) {
            final p = f.pricePerLiter;
            pMin = (pMin == null || p < pMin) ? p : pMin;
            pMax = (pMax == null || p > pMax) ? p : pMax;
          }
          final hasPriceSpread =
              pMin != null && pMax != null && (pMax - pMin) > 0.001;

          final filteredFuel = _applyFuelFilters(located);

          return StreamBuilder<List<Ride>>(
            initialData: rideRepo.latest,
            stream: rideRepo.watchAll(),
            builder: (context, rideSnap) {
              final rides = _filteredRides(rideSnap.data ?? const <Ride>[]);

              // Lazily load tracks for any visible ride we haven't cached yet.
              if (_showRides &&
                  rides.any((r) =>
                      !_ridePaths.containsKey(r.id) &&
                      !_ridePathLoading.contains(r.id))) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _ensureRidePaths(rides));
              }

              // Frame the fuel points the first time they arrive.
              if (!_didInitialFit && _showFuel && filteredFuel.isNotEmpty) {
                _didInitialFit = true;
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _fitToPoints(
                    [for (final f in filteredFuel) _fuelLatLng(f)],
                  ),
                );
              }

              final nothingShown = (!_showFuel || located.isEmpty) &&
                  (!_showRides || rides.isEmpty);

              return Stack(
                children: [
                  FlutterMap(
                    mapController: _controller,
                    options: MapOptions(
                      initialCenter: _swissCenter,
                      initialZoom: 8.5,
                      minZoom: 3,
                      maxZoom: 18,
                      // Google-Maps-style gestures: let the dominant multi-finger
                      // gesture win instead of zooming and rotating at once, and
                      // require a deliberate twist before rotation kicks in.
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all,
                        enableMultiFingerGestureRace: true,
                        rotationThreshold: 30,
                        pinchZoomThreshold: 0.3,
                      ),
                      onPositionChanged: (camera, _) {
                        if (camera.rotation != _rotation) {
                          setState(() => _rotation = camera.rotation);
                        }
                      },
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'ch.tleuthold.motorider',
                        maxNativeZoom: 19,
                      ),
                      if (_showRides)
                        PolylineLayer(
                          polylines: [
                            for (final r in rides)
                              if ((_ridePaths[r.id]?.length ?? 0) >= 2)
                                Polyline(
                                  points: _ridePaths[r.id]!,
                                  strokeWidth: 4,
                                  color: _rideColor,
                                  borderStrokeWidth: 1.5,
                                  borderColor:
                                      Colors.black.withValues(alpha: 0.3),
                                ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          if (_showFuel)
                            for (final f in filteredFuel)
                              Marker(
                                point: _fuelLatLng(f),
                                width: 34,
                                height: 34,
                                child: Builder(
                                  builder: (_) {
                                    final color = hasPriceSpread
                                        ? priceColor(
                                            (f.pricePerLiter - pMin!) /
                                                (pMax! - pMin))
                                        : AppColors.accent;
                                    return GestureDetector(
                                      onTap: () => _showFuelDetails(f, color),
                                      child: _FuelMarker(color: color),
                                    );
                                  },
                                ),
                              ),
                          if (_showRides)
                            for (final r in rides)
                              if ((_ridePaths[r.id]?.length ?? 0) >= 2)
                                Marker(
                                  point: _ridePaths[r.id]![
                                      _ridePaths[r.id]!.length ~/ 2],
                                  width: 30,
                                  height: 30,
                                  child: GestureDetector(
                                    onTap: () => _showRideDetails(r),
                                    child: const _RideBadge(),
                                  ),
                                ),
                          if (_userPos != null)
                            Marker(
                              point: _userPos!,
                              width: 36,
                              height: 36,
                              child: const _UserDot(),
                            ),
                        ],
                      ),
                      const RichAttributionWidget(
                        alignment: AttributionAlignment.bottomLeft,
                        showFlutterMapAttribution: false,
                        attributions: [
                          TextSourceAttribution('© OpenStreetMap')
                        ],
                      ),
                    ],
                  ),

                  // Top filter / legend card.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: _FilterCard(
                          showFuel: _showFuel,
                          showRides: _showRides,
                          onToggleFuel: () =>
                              setState(() => _showFuel = !_showFuel),
                          onToggleRides: () =>
                              setState(() => _showRides = !_showRides),
                          fuelCount: filteredFuel.length,
                          rideCount: rides.length,
                          datePreset: _datePreset,
                          onDatePreset: (p) => setState(() => _datePreset = p),
                          priceActive: _priceFilter != null,
                          onPriceTap: (_showFuel && hasPriceSpread)
                              ? () => _openPriceFilter(pMin!, pMax!)
                              : null,
                          showLegend: _showFuel && hasPriceSpread,
                          priceMin: pMin,
                          priceMax: pMax,
                        ),
                      ),
                    ),
                  ),

                  if (nothingShown) const Center(child: _NothingHint()),

                  // Map controls (compass / zoom / fit) + locate FAB.
                  Positioned(
                    right: 16,
                    bottom: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_rotation.abs() > 0.5) ...[
                          _CompassButton(
                            rotationDeg: _rotation,
                            onTap: _resetNorth,
                          ),
                          const SizedBox(height: 10),
                        ],
                        _MapButton(
                          icon: Icons.add_rounded,
                          tooltip: 'Reinzoomen',
                          onTap: () => _zoom(1),
                        ),
                        const SizedBox(height: 8),
                        _MapButton(
                          icon: Icons.remove_rounded,
                          tooltip: 'Rauszoomen',
                          onTap: () => _zoom(-1),
                        ),
                        const SizedBox(height: 8),
                        _MapButton(
                          icon: Icons.fit_screen_rounded,
                          tooltip: 'Alle anzeigen',
                          onTap: () {
                            final pts = _visiblePoints(filteredFuel, rides);
                            if (pts.isNotEmpty) _fitToPoints(pts);
                          },
                        ),
                        const SizedBox(height: 10),
                        FloatingActionButton(
                          heroTag: 'locate-me',
                          onPressed: _locating ? null : _locateMe,
                          child: _locating
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: Colors.black),
                                )
                              : const Icon(Icons.my_location_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  LatLng _fuelLatLng(FillUp f) => LatLng(f.latitude!, f.longitude!);

  List<FillUp> _applyFuelFilters(List<FillUp> located) {
    final window = _datePreset.window;
    final cutoff = window == null ? null : DateTime.now().subtract(window);
    return located.where((f) {
      if (cutoff != null && f.date.isBefore(cutoff)) return false;
      if (_priceFilter != null) {
        final p = f.pricePerLiter;
        if (p < _priceFilter!.start - 1e-9 || p > _priceFilter!.end + 1e-9) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Completed rides within the current date window.
  List<Ride> _filteredRides(List<Ride> rides) {
    final window = _datePreset.window;
    final cutoff = window == null ? null : DateTime.now().subtract(window);
    return rides
        .where((r) =>
            r.endedAt != null &&
            (cutoff == null || !r.startedAt.isBefore(cutoff)))
        .toList();
  }

  Future<void> _ensureRidePaths(List<Ride> rides) async {
    final toLoad = rides
        .where((r) =>
            !_ridePaths.containsKey(r.id) && !_ridePathLoading.contains(r.id))
        .toList();
    if (toLoad.isEmpty) return;
    _ridePathLoading.addAll(toLoad.map((r) => r.id));
    for (final r in toLoad) {
      final pts = await rideRepo.getPoints(r.id);
      if (!mounted) return;
      _ridePaths[r.id] = _downsample(pts);
      _ridePathLoading.remove(r.id);
    }
    if (mounted) setState(() {});
  }

  /// Stride-decimate a track down to ~400 points (always keeping the last one)
  /// so the overview stays smooth even for multi-thousand-point rides.
  List<LatLng> _downsample(List<RidePoint> pts) {
    if (pts.isEmpty) return const [];
    const target = 400;
    final stride = (pts.length / target).ceil().clamp(1, 1 << 30);
    final out = <LatLng>[
      for (var i = 0; i < pts.length; i += stride) LatLng(pts[i].lat, pts[i].lon)
    ];
    final last = pts.last;
    if (out.isEmpty ||
        out.last.latitude != last.lat ||
        out.last.longitude != last.lon) {
      out.add(LatLng(last.lat, last.lon));
    }
    return out;
  }

  List<LatLng> _visiblePoints(List<FillUp> fuel, List<Ride> rides) {
    final pts = <LatLng>[];
    if (_showFuel) pts.addAll(fuel.map(_fuelLatLng));
    if (_showRides) {
      for (final r in rides) {
        final path = _ridePaths[r.id];
        if (path != null) pts.addAll(path);
      }
    }
    return pts;
  }

  void _zoom(double delta) {
    final cam = _controller.camera;
    _controller.move(cam.center, (cam.zoom + delta).clamp(3.0, 18.0));
  }

  /// Smoothly animate the bearing back to north (compass tap), taking the
  /// shortest way round (e.g. 350° rotates +10°, not −350°).
  void _resetNorth() {
    _rotationReset?.dispose();
    var start = _controller.camera.rotation % 360;
    if (start > 180) start -= 360;
    if (start < -180) start += 360;
    if (start.abs() < 0.01) return;
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _rotationReset = ctrl;
    final anim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: ctrl, curve: Curves.easeOut),
    );
    anim.addListener(() => _controller.rotate(anim.value));
    ctrl.forward().whenComplete(() {
      _controller.rotate(0);
      ctrl.dispose();
      if (identical(_rotationReset, ctrl)) _rotationReset = null;
    });
  }

  void _fitToPoints(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _controller.move(pts.first, 14);
      return;
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.fromLTRB(50, 150, 50, 110),
      ),
    );
  }

  Future<void> _openPriceFilter(double min, double max) async {
    // Seed with the active filter (clamped into bounds) or the full range.
    final seed = _priceFilter ?? RangeValues(min, max);
    var current = RangeValues(
      seed.start.clamp(min, max),
      seed.end.clamp(min, max),
    );
    final nf = NumberFormat('0.00');
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Preis pro Liter',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'CHF ${nf.format(current.start)} – ${nf.format(current.end)}',
                    style: const TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w700),
                  ),
                  RangeSlider(
                    values: current,
                    min: min,
                    max: max,
                    divisions: ((max - min) * 100).round().clamp(1, 200),
                    activeColor: AppColors.accent,
                    inactiveColor: AppColors.gridLine,
                    labels: RangeLabels(
                      nf.format(current.start),
                      nf.format(current.end),
                    ),
                    onChanged: (v) => setSheet(() => current = v),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() => _priceFilter = null);
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Zurücksetzen'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () {
                          setState(() => _priceFilter = current);
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Anwenden'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showFuelDetails(FillUp f, Color color) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _FuelSheet(
        fillup: f,
        color: color,
        onEdit: () {
          Navigator.of(ctx).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AddFillUpScreen(existing: f)),
          );
        },
      ),
    );
  }

  void _showRideDetails(Ride r) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _RideSheet(
        ride: r,
        onOpen: () {
          Navigator.of(ctx).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RideDetailScreen(rideId: r.id)),
          );
        },
      ),
    );
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
    _controller.move(p, 14);
  }

  @override
  void dispose() {
    _rotationReset?.dispose();
    super.dispose();
  }
}

/// Top card: layer toggles, count, date presets, price filter, colour legend.
class _FilterCard extends StatelessWidget {
  const _FilterCard({
    required this.showFuel,
    required this.showRides,
    required this.onToggleFuel,
    required this.onToggleRides,
    required this.fuelCount,
    required this.rideCount,
    required this.datePreset,
    required this.onDatePreset,
    required this.priceActive,
    required this.onPriceTap,
    required this.showLegend,
    required this.priceMin,
    required this.priceMax,
  });

  final bool showFuel;
  final bool showRides;
  final VoidCallback onToggleFuel;
  final VoidCallback onToggleRides;
  final int fuelCount;
  final int rideCount;
  final _DatePreset datePreset;
  final ValueChanged<_DatePreset> onDatePreset;
  final bool priceActive;
  final VoidCallback? onPriceTap;
  final bool showLegend;
  final double? priceMin;
  final double? priceMax;

  @override
  Widget build(BuildContext context) {
    final summary = <String>[
      if (showFuel) '$fuelCount Tankstopps',
      if (showRides) '$rideCount Touren',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              const Text(
                'Karte',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              _LayerToggle(
                icon: Icons.local_gas_station_rounded,
                active: showFuel,
                onTap: onToggleFuel,
                tooltip: 'Tankstopps',
                activeColor: AppColors.accent,
              ),
              const SizedBox(width: 8),
              _LayerToggle(
                icon: Icons.route_rounded,
                active: showRides,
                onTap: onToggleRides,
                tooltip: 'Touren',
                activeColor: _rideColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary.isEmpty ? 'Keine Ebene aktiv' : summary,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in _DatePreset.values) ...[
                  _Chip(
                    label: p.label,
                    selected: p == datePreset,
                    onTap: () => onDatePreset(p),
                  ),
                  const SizedBox(width: 8),
                ],
                if (onPriceTap != null)
                  _Chip(
                    label: 'Preis',
                    icon: Icons.tune_rounded,
                    selected: priceActive,
                    onTap: onPriceTap!,
                  ),
              ],
            ),
          ),
          if (showLegend && priceMin != null && priceMax != null) ...[
            const SizedBox(height: 12),
            _PriceLegend(min: priceMin!, max: priceMax!),
          ],
        ],
      ),
    );
  }
}

/// Small square toggle for a map layer (fuel / rides).
class _LayerToggle extends StatelessWidget {
  const _LayerToggle({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.tooltip,
    required this.activeColor,
  });
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tooltip;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$tooltip ${active ? 'ausblenden' : 'einblenden'}',
      child: Material(
        color: active ? activeColor : AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active ? activeColor : AppColors.gridLine,
              ),
            ),
            child: Icon(
              icon,
              size: 18,
              color: active ? Colors.black : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : AppColors.surfaceHi,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.gridLine,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 14,
                    color: selected ? Colors.black : AppColors.textMuted),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.black : AppColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriceLegend extends StatelessWidget {
  const _PriceLegend({required this.min, required this.max});
  final double min;
  final double max;

  @override
  Widget build(BuildContext context) {
    final nf = NumberFormat('0.00');
    return Row(
      children: [
        Text('CHF ${nf.format(min)}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: const LinearGradient(
                colors: [_cheapColor, _midColor, _priceyColor],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('CHF ${nf.format(max)}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
      ],
    );
  }
}

class _FuelSheet extends StatelessWidget {
  const _FuelSheet({
    required this.fillup,
    required this.color,
    required this.onEdit,
  });
  final FillUp fillup;
  final Color color;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final timeFmt = DateFormat('HH:mm');
    final nf = NumberFormat.decimalPattern('de_CH');
    final f = fillup;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color, width: 2),
                  ),
                  child: const Icon(Icons.local_gas_station_rounded,
                      color: AppColors.text, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.station?.isNotEmpty == true ? f.station! : 'Tankstopp',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                        ),
                      ),
                      Text(
                        '${dateFmt.format(f.date)} · ${timeFmt.format(f.date)}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Metric(
                    label: 'Liter', value: '${f.liters.toStringAsFixed(2)} L'),
                _Metric(
                    label: 'Total',
                    value: 'CHF ${f.totalChf.toStringAsFixed(2)}'),
                _Metric(
                    label: 'pro Liter',
                    value: 'CHF ${f.pricePerLiter.toStringAsFixed(2)}'),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Metric(
                    label: 'Kilometerstand',
                    value: '${nf.format(f.odometerKm)} km'),
                _Metric(
                    label: 'Vollgetankt', value: f.fullTank ? 'Ja' : 'Nein'),
              ],
            ),
            if (f.notes?.isNotEmpty == true) ...[
              const SizedBox(height: 14),
              Text(f.notes!,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 13)),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Bearbeiten'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RideSheet extends StatelessWidget {
  const _RideSheet({required this.ride, required this.onOpen});
  final Ride ride;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final timeFmt = DateFormat('HH:mm');
    final r = ride;
    final title = r.title?.isNotEmpty == true
        ? r.title!
        : '${dateFmt.format(r.startedAt)} · ${timeFmt.format(r.startedAt)}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _rideColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _rideColor, width: 2),
                  ),
                  child: const Icon(Icons.route_rounded,
                      color: AppColors.text, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                        ),
                      ),
                      Text(
                        '${dateFmt.format(r.startedAt)} · '
                        '${timeFmt.format(r.startedAt)}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Metric(
                    label: 'Distanz',
                    value: '${r.distanceKm.toStringAsFixed(1)} km'),
                _Metric(label: 'Dauer', value: _fmtDuration(r.totalDuration)),
                _Metric(
                    label: 'Ø km/h',
                    value: r.avgMovingSpeedKmh.toStringAsFixed(0)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Metric(
                    label: 'Max km/h',
                    value: r.maxSpeedKmh.toStringAsFixed(0)),
                _Metric(
                  label: 'Höhenmeter',
                  value: r.elevationGainM == null
                      ? '–'
                      : '${r.elevationGainM!.toStringAsFixed(0)} m',
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              label: const Text('Tour-Details'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text)),
        ],
      ),
    );
  }
}

/// Colour-coded fuel-pump pin.
class _FuelMarker extends StatelessWidget {
  const _FuelMarker({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.local_gas_station_rounded,
          size: 17, color: AppColors.bg),
    );
  }
}

/// Tappable badge sitting on a ride's track midpoint.
class _RideBadge extends StatelessWidget {
  const _RideBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _rideColor,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.route_rounded, size: 15, color: AppColors.bg),
    );
  }
}

/// A small square button used for the map controls (zoom / fit / compass).
class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
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
            child: Icon(icon,
                color: enabled ? AppColors.text : AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Button that reflects the map's rotation and snaps back to north on tap.
class _CompassButton extends StatelessWidget {
  const _CompassButton({required this.rotationDeg, required this.onTap});
  final double rotationDeg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Nach Norden ausrichten',
      child: Material(
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
            child: Transform.rotate(
              angle: rotationDeg * 3.1415926535 / 180,
              child:
                  const Icon(Icons.navigation_rounded, color: AppColors.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _NothingHint extends StatelessWidget {
  const _NothingHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_clear_rounded, color: AppColors.textMuted),
          SizedBox(width: 12),
          Flexible(
            child: Text(
              'Nichts anzuzeigen. Erfasse einen Ort bei einer Tankfüllung '
              'oder zeichne eine Tour auf.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
        ],
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
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.6),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
