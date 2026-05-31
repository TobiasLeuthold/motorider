import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/location_service.dart';
import '../theme.dart';

/// Full-screen map picker. The user pans/zooms the map under a fixed centre
/// pin; whatever sits under the pin on "Bestätigen" is returned as a [LatLng].
///
/// Returns the chosen [LatLng] via `Navigator.pop`, or `null` if cancelled.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.initial});

  /// Where to centre the map initially. If null we try the current GPS
  /// position, falling back to the geographic centre of Switzerland.
  final LatLng? initial;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final _controller = MapController();

  // Geographic centre of Switzerland — same fallback the Karte tab uses.
  static const _swissCenter = LatLng(46.8182, 8.2275);

  late LatLng _center;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _center = widget.initial ?? _swissCenter;
    // No explicit location yet → try to start on the user's position.
    if (widget.initial == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goToCurrent(silent: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasInitial = widget.initial != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Ort wählen')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: hasInitial ? 15 : 8.5,
              minZoom: 3,
              maxZoom: 18,
              // Pan + zoom only — rotating a pick-a-point map just disorients.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, _) {
                // Track the live centre so "Bestätigen" returns what's under
                // the pin without reading the controller mid-gesture.
                setState(() => _center = camera.center);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ch.tleuthold.motorider',
                maxNativeZoom: 19,
              ),
              const RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                showFlutterMapAttribution: false,
                attributions: [TextSourceAttribution('© OpenStreetMap')],
              ),
            ],
          ),
          // Fixed centre pin. IgnorePointer so it never eats map gestures;
          // the translate lifts it so the pin's tip rests on the map centre.
          const Center(
            child: IgnorePointer(child: _CenterPin()),
          ),
          // Live coordinate readout.
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.gridLine),
                  ),
                  child: Text(
                    '${_center.latitude.toStringAsFixed(5)}, '
                    '${_center.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton(
              heroTag: 'picker-locate',
              onPressed: _locating ? null : () => _goToCurrent(),
              child: _locating
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                    )
                  : const Icon(Icons.my_location_rounded),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_center),
            icon: const Icon(Icons.check_rounded),
            label: const Text('Standort bestätigen'),
          ),
        ),
      ),
    );
  }

  Future<void> _goToCurrent({bool silent = false}) async {
    setState(() => _locating = true);
    final res = await LocationService.getCurrent();
    if (!mounted) return;
    setState(() => _locating = false);
    if (res.position == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'Standort nicht verfügbar')),
        );
      }
      return;
    }
    final p = LatLng(res.position!.latitude, res.position!.longitude);
    setState(() => _center = p);
    _controller.move(p, 15);
  }
}

/// Pin whose tip points downward; wrapped so the tip lands on the map centre.
class _CenterPin extends StatelessWidget {
  const _CenterPin();

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      // Lift by half the icon height so the pointed tip sits on the centre.
      offset: const Offset(0, -22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.place_rounded,
            size: 44,
            color: AppColors.accent,
            shadows: [Shadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2))],
          ),
          // Small ground shadow at the exact centre point.
          Container(
            width: 8,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}
