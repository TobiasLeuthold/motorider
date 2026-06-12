import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/ride_point.dart';
import '../stats/ride_stats.dart';
import '../theme.dart';

/// Map that renders the GPS polyline for a ride.
///
/// When [followLast] is true and points keep arriving, the camera tracks the
/// latest point. The widget owns its own MapController and resets the camera
/// to fit-bounds when [points] becomes non-empty for the first time.
///
/// With [colorBySpeed] the track is split into runs colored by speed bucket
/// (with a small legend), so you can see at a glance where the fast and slow
/// sections were.
class RidePolylineMap extends StatefulWidget {
  const RidePolylineMap({
    super.key,
    required this.points,
    this.followLast = false,
    this.colorBySpeed = false,
    this.height,
  });

  final List<RidePoint> points;
  final bool followLast;
  final bool colorBySpeed;
  final double? height;

  @override
  State<RidePolylineMap> createState() => _RidePolylineMapState();
}

/// Speed buckets for the colored track. Upper bound (km/h) → color.
const _speedBuckets = <(double, Color)>[
  (30, Color(0xFF4DA3FF)),
  (60, Color(0xFF3DDC84)),
  (90, Color(0xFFFFD54D)),
  (120, Color(0xFFFF9A3D)),
  (double.infinity, Color(0xFFFF5A6A)),
];

const _speedBucketLabels = ['<30', '30–60', '60–90', '90–120', '120+'];

int _bucketFor(double kmh) {
  for (var i = 0; i < _speedBuckets.length; i++) {
    if (kmh < _speedBuckets[i].$1) return i;
  }
  return _speedBuckets.length - 1;
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

  /// Group consecutive points of the same speed bucket into single polylines.
  /// Runs share their boundary point so the track stays gap-free; a typical
  /// ride yields a few dozen runs, well within PolylineLayer's comfort zone.
  List<Polyline> _speedColoredPolylines() {
    final pts = widget.points;
    final speeds = medianFilteredSpeeds(effectiveSpeedsKmh(pts), window: 3);
    // Segment s runs from point s-1 to point s and is colored by the speed at
    // its endpoint. Consecutive same-bucket segments merge into one polyline;
    // runs share their boundary point so the track stays gap-free.
    final lines = <Polyline>[];
    var segStart = 1;
    var runBucket = _bucketFor(speeds[1] ?? 0);
    for (var s = 2; s <= pts.length; s++) {
      final bucket = s < pts.length ? _bucketFor(speeds[s] ?? 0) : -1;
      if (bucket == runBucket) continue;
      lines.add(Polyline(
        points: [
          for (var j = segStart - 1; j < s; j++) LatLng(pts[j].lat, pts[j].lon),
        ],
        strokeWidth: 5,
        color: _speedBuckets[runBucket].$2,
        borderStrokeWidth: 1.5,
        borderColor: Colors.black.withValues(alpha: 0.35),
      ));
      segStart = s;
      runBucket = bucket;
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final polylinePts = widget.points.map((p) => LatLng(p.lat, p.lon)).toList();
    final initialCenter = polylinePts.isNotEmpty ? polylinePts.last : _swissCenter;
    final initialZoom = polylinePts.isNotEmpty ? 14.5 : 8.5;
    final useSpeedColors = widget.colorBySpeed && polylinePts.length >= 2;

    final map = FlutterMap(
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
            polylines: useSpeedColors
                ? _speedColoredPolylines()
                : [
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
              if (useSpeedColors)
                Marker(
                  point: polylinePts.first,
                  width: 16,
                  height: 16,
                  child: const _EndpointDot(color: Color(0xFF3DDC84)),
                ),
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
    );

    return SizedBox(
      height: widget.height,
      child: useSpeedColors
          ? Stack(
              children: [
                map,
                const Positioned(right: 8, bottom: 8, child: _SpeedLegend()),
              ],
            )
          : map,
    );
  }
}

class _SpeedLegend extends StatelessWidget {
  const _SpeedLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _speedBuckets.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _speedBuckets[i].$2,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              _speedBucketLabels[i],
              style: const TextStyle(
                fontSize: 9,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EndpointDot extends StatelessWidget {
  const _EndpointDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2),
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
