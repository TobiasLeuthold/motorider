import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/ride_point.dart';
import '../theme.dart';

/// Map that renders the GPS polyline for a ride.
///
/// When [followLast] is true and points keep arriving, the camera tracks the
/// latest point. The widget owns its own MapController and resets the camera
/// to fit-bounds when [points] becomes non-empty for the first time.
class RidePolylineMap extends StatefulWidget {
  const RidePolylineMap({
    super.key,
    required this.points,
    this.followLast = false,
    this.height,
  });

  final List<RidePoint> points;
  final bool followLast;
  final double? height;

  @override
  State<RidePolylineMap> createState() => _RidePolylineMapState();
}

class _RidePolylineMapState extends State<RidePolylineMap> {
  final _ctrl = MapController();
  bool _didInitialFit = false;

  static const _swissCenter = LatLng(46.8182, 8.2275);

  @override
  void didUpdateWidget(covariant RidePolylineMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.followLast && widget.points.isNotEmpty) {
      final last = widget.points.last;
      _ctrl.move(LatLng(last.lat, last.lon), _ctrl.camera.zoom);
    } else if (!widget.followLast &&
        !_didInitialFit &&
        widget.points.length >= 2) {
      _didInitialFit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
    }
  }

  void _fitAll() {
    if (widget.points.isEmpty) return;
    final pts = widget.points.map((p) => LatLng(p.lat, p.lon)).toList();
    if (pts.length == 1) {
      _ctrl.move(pts.first, 14);
      return;
    }
    _ctrl.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(40),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final polylinePts = widget.points.map((p) => LatLng(p.lat, p.lon)).toList();
    final initialCenter = polylinePts.isNotEmpty ? polylinePts.last : _swissCenter;
    final initialZoom = polylinePts.isNotEmpty ? 14.5 : 8.5;

    return SizedBox(
      height: widget.height,
      child: FlutterMap(
        mapController: _ctrl,
        options: MapOptions(
          initialCenter: initialCenter,
          initialZoom: initialZoom,
          minZoom: 3,
          maxZoom: 18,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'ch.tleuthold.motorider',
            maxNativeZoom: 19,
          ),
          if (polylinePts.length >= 2)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: polylinePts,
                  strokeWidth: 5,
                  color: AppColors.accent,
                  borderStrokeWidth: 1.5,
                  borderColor: Colors.black.withValues(alpha: 0.35),
                ),
              ],
            ),
          if (polylinePts.isNotEmpty)
            MarkerLayer(
              markers: [
                Marker(
                  point: polylinePts.last,
                  width: 24,
                  height: 24,
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
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}
