import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../services/location_service.dart';
import '../theme.dart';
import 'add_fillup_screen.dart';

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

class _MapScreenState extends State<MapScreen> {
  final _controller = MapController();
  LatLng? _userPos;
  bool _locating = false;

  _DatePreset _datePreset = _DatePreset.all;
  RangeValues? _priceFilter; // null = no price filter
  double _rotation = 0;
  bool _didInitialFit = false;

  // Default to Switzerland's geographic center.
  static const _swissCenter = LatLng(46.8182, 8.2275);

  @override
  Widget build(BuildContext context) {
    final initial = widget.stream == null ? fillUpRepo.latest : const <FillUp>[];
    return Scaffold(
      body: StreamBuilder<List<FillUp>>(
        initialData: initial,
        stream: widget.stream ?? fillUpRepo.watchAll(),
        builder: (context, snap) {
          final all = snap.data ?? const <FillUp>[];
          // Only real fill-ups with coordinates land on the map.
          final located = all
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

          final filtered = _applyFilters(located);

          // Frame all points the first time data with locations arrives.
          if (!_didInitialFit && filtered.isNotEmpty) {
            _didInitialFit = true;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _fitTo(filtered));
          }

          return Stack(
            children: [
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  initialCenter: _swissCenter,
                  initialZoom: 8.5,
                  minZoom: 3,
                  maxZoom: 18,
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
                  MarkerLayer(
                    markers: [
                      for (final f in filtered)
                        Marker(
                          point: LatLng(f.latitude!, f.longitude!),
                          width: 34,
                          height: 34,
                          child: Builder(
                            builder: (_) {
                              final color = hasPriceSpread
                                  ? priceColor((f.pricePerLiter - pMin!) /
                                      (pMax! - pMin))
                                  : AppColors.accent;
                              return GestureDetector(
                                onTap: () => _showDetails(f, color),
                                child: _FuelMarker(color: color),
                              );
                            },
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
                    attributions: [TextSourceAttribution('© OpenStreetMap')],
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
                      shown: filtered.length,
                      total: located.length,
                      datePreset: _datePreset,
                      onDatePreset: (p) => setState(() => _datePreset = p),
                      priceActive: _priceFilter != null,
                      onPriceTap: hasPriceSpread
                          ? () => _openPriceFilter(pMin!, pMax!)
                          : null,
                      showLegend: hasPriceSpread,
                      priceMin: pMin,
                      priceMax: pMax,
                    ),
                  ),
                ),
              ),

              if (located.isEmpty) const Center(child: _NoLocationsHint()),

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
                        onTap: () => _controller.rotate(0),
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
                      onTap: filtered.isEmpty ? null : () => _fitTo(filtered),
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
      ),
    );
  }

  List<FillUp> _applyFilters(List<FillUp> located) {
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

  void _zoom(double delta) {
    final cam = _controller.camera;
    _controller.move(cam.center, (cam.zoom + delta).clamp(3.0, 18.0));
  }

  void _fitTo(List<FillUp> list) {
    if (list.isEmpty) return;
    final pts = [for (final f in list) LatLng(f.latitude!, f.longitude!)];
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

  void _showDetails(FillUp f, Color color) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _DetailSheet(
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
}

/// Top card: count, date presets, price filter toggle, colour legend.
class _FilterCard extends StatelessWidget {
  const _FilterCard({
    required this.shown,
    required this.total,
    required this.datePreset,
    required this.onDatePreset,
    required this.priceActive,
    required this.onPriceTap,
    required this.showLegend,
    required this.priceMin,
    required this.priceMax,
  });

  final int shown;
  final int total;
  final _DatePreset datePreset;
  final ValueChanged<_DatePreset> onDatePreset;
  final bool priceActive;
  final VoidCallback? onPriceTap;
  final bool showLegend;
  final double? priceMin;
  final double? priceMax;

  @override
  Widget build(BuildContext context) {
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
              Text(
                '$shown von $total',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
            ],
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

class _DetailSheet extends StatelessWidget {
  const _DetailSheet({
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

class _NoLocationsHint extends StatelessWidget {
  const _NoLocationsHint();

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
          Icon(Icons.location_off_rounded, color: AppColors.textMuted),
          SizedBox(width: 12),
          Flexible(
            child: Text(
              'Noch keine Standorte. Füge bei einer Tankfüllung einen Ort hinzu.',
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
