import 'package:flutter/painting.dart' show Color;
import 'package:latlong2/latlong.dart';

import '../models/ride_point.dart';
import 'ride_filter.dart' show RideColorMetric, MetricRange;
import 'ride_stats.dart';

// Re-export the metric scaffolding so map_screen gets it — and the
// `RideColorMetricLabel` extension's `.label` / `.value(ride)` — from this one
// module rather than importing ride_filter.dart directly.
export 'ride_filter.dart'
    show RideColorMetric, RideColorMetricLabel, MetricRange, metricRange;

/// The shared cheap/cold→pricey/hot colour scale (green → amber → red). Used
/// for fuel-price pins, the uniform ride-metric colouring, and the per-segment
/// speed heatmap so every gradient on the map reads the same way.
const scaleLow = Color(0xFF34D399); // green   (cheap / slow / short)
const scaleMid = Color(0xFFFBBF24); // amber   (mid)
const scaleHigh = Color(0xFFF87171); // red     (pricey / fast / long)

/// Map a normalised value `t` (0 → low/green, 1 → high/red) onto the shared
/// green→amber→red scale. Clamps out-of-range input so callers never have to.
Color colorOnScale(double t) {
  t = t.clamp(0.0, 1.0);
  return t < 0.5
      ? Color.lerp(scaleLow, scaleMid, t * 2)!
      : Color.lerp(scaleMid, scaleHigh, (t - 0.5) * 2)!;
}

/// How the ride tracks on the overview map are coloured.
///
/// The three metric modes ([avgSpeed]/[maxSpeed]/[distance]) paint each whole
/// track one colour by where that ride's metric falls across the shown set.
/// [speedHeatmap] instead colours each track per segment by the instantaneous
/// speed there. [uniform] is the plain single-colour default.
enum RideColorMode { uniform, avgSpeed, maxSpeed, distance, speedHeatmap }

extension RideColorModeLabel on RideColorMode {
  /// Short German label for the mode selector chip.
  String get label => switch (this) {
        RideColorMode.uniform => 'Einfarbig',
        RideColorMode.avgSpeed => 'Ø Tempo',
        RideColorMode.maxSpeed => 'Max Tempo',
        RideColorMode.distance => 'Distanz',
        RideColorMode.speedHeatmap => 'Tempo-Verlauf',
      };

  /// The per-ride metric this mode normalises over, or null for the modes that
  /// don't colour a whole track by a single ride metric ([uniform] and the
  /// per-segment [speedHeatmap]).
  RideColorMetric? get metric => switch (this) {
        RideColorMode.avgSpeed => RideColorMetric.avgSpeed,
        RideColorMode.maxSpeed => RideColorMetric.maxSpeed,
        RideColorMode.distance => RideColorMetric.distance,
        RideColorMode.uniform || RideColorMode.speedHeatmap => null,
      };

  bool get isPerSegment => this == RideColorMode.speedHeatmap;
}

/// A downsampled track point: a position plus the (median-filtered, km/h)
/// effective speed there, or null when no estimate exists for that fix.
class TrackPoint {
  const TrackPoint(this.pt, this.speedKmh);
  final LatLng pt;
  final double? speedKmh;
}

/// Stride-decimate a raw ride trace down to ~[target] points, carrying the
/// effective speed (km/h) at each kept point so the overview can paint a speed
/// heatmap without re-reading the dense trace.
///
/// Speed is derived on the FULL trace first ([effectiveSpeedsKmh] +
/// [medianFilteredSpeeds]) — Doppler-first with a haversine fallback and spike
/// filtering — then sampled at the kept indices. Doing it before decimation
/// keeps the per-segment timing accurate; doing it after would compute speeds
/// across multi-second strides and smear everything together.
///
/// The last point is always kept so the track ends where the ride did.
List<TrackPoint> downsampleTrack(List<RidePoint> pts, {int target = 400}) {
  if (pts.isEmpty) return const [];
  final speeds = medianFilteredSpeeds(effectiveSpeedsKmh(pts), window: 3);
  final stride = (pts.length / target).ceil().clamp(1, 1 << 30);
  final out = <TrackPoint>[
    for (var i = 0; i < pts.length; i += stride)
      TrackPoint(LatLng(pts[i].lat, pts[i].lon), speeds[i]),
  ];
  final lastIdx = pts.length - 1;
  final last = pts[lastIdx];
  if (out.isEmpty ||
      out.last.pt.latitude != last.lat ||
      out.last.pt.longitude != last.lon) {
    out.add(TrackPoint(LatLng(last.lat, last.lon), speeds[lastIdx]));
  }
  return out;
}

/// Position part of a downsampled track (for fitting / midpoint badge / taps).
List<LatLng> trackLatLngs(List<TrackPoint> track) =>
    [for (final t in track) t.pt];

/// Min/max effective speed (km/h) across the segments of every [track] passed
/// in, used to normalise the speed heatmap so the gradient spans the whole
/// shown set rather than each track individually. Segment speed is taken at the
/// segment's end point; null (unknown) speeds are ignored.
///
/// Returns a degenerate [MetricRange] (no spread) when nothing has a known
/// speed, in which case [MetricRange.normalize] paints everything mid-scale.
MetricRange heatmapSpeedRange(Iterable<List<TrackPoint>> tracks) {
  double? min, max;
  for (final track in tracks) {
    for (var i = 1; i < track.length; i++) {
      final v = track[i].speedKmh;
      if (v == null) continue;
      if (min == null || v < min) min = v;
      if (max == null || v > max) max = v;
    }
  }
  if (min == null || max == null) return const MetricRange(0, 0);
  return MetricRange(min, max);
}

/// Per-segment colours for a single track's speed heatmap, normalised over
/// [range]. Segment _s_ runs from point _s-1_ to point _s_ and is coloured by
/// the speed at its end point _s_; the result has length `track.length - 1`
/// (empty for a track of fewer than two points).
///
/// A segment whose end speed is unknown falls back to mid-scale (amber) so the
/// track stays gap-free and visually continuous.
List<Color> segmentSpeedColors(List<TrackPoint> track, MetricRange range) {
  if (track.length < 2) return const [];
  return [
    for (var i = 1; i < track.length; i++)
      colorOnScale(range.normalize(track[i].speedKmh ?? range.midValue)),
  ];
}

extension on MetricRange {
  /// The value that normalises to 0.5 — used as the neutral fallback for
  /// unknown segment speeds so they paint amber rather than green/red.
  double get midValue => (min + max) / 2;
}
