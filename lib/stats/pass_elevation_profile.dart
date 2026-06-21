import '../services/geo.dart' show cumulativeMeters, haversineMeters;
import 'pass_explorer.dart' show Pass;

/// One sample of a pass's height profile: distance along the road from the foot
/// drawn on the left (km) paired with elevation (m).
class PassElevationPoint {
  const PassElevationPoint({required this.km, required this.ele});

  /// Distance along the pass road, in kilometres, from the left-hand foot.
  final double km;

  /// Elevation in metres.
  final double ele;
}

/// Distance below which two profile anchors are merged into one (km). Keeps a
/// col that sits right at a foot (e.g. a pass approached from a high plateau)
/// from drawing as a vertical spike at the same x.
const double _mergeKm = 0.05;

/// Build a **distance-correct, asymmetric** height profile for [pass] from the
/// data the dataset actually carries: the two surveyed foot elevations
/// ([Pass.start]/[Pass.end] `ele`), the summit ([Pass.summitEle]), and the road
/// [Pass.geometry] — which preserves the col vertex. The col is placed at its
/// *real* distance along the road, so the two flanks get their true (usually
/// unequal) widths, and the feet keep their true (usually unequal) heights.
///
/// This is deliberately NOT a metre-by-metre survey — the bundled dataset has no
/// per-vertex elevation, so heights between the three surveyed anchors are
/// linearly interpolated by the chart. The function is honest about what's
/// known (three real heights at real distances) and never fabricates terrain.
///
/// Geometry orientation is detected from the feet, so the left-hand foot is
/// always the one [Pass.geometry] starts at. Returns fewer than two points
/// (which callers treat as "nothing to draw") when there isn't enough data: no
/// summit, neither foot elevation, or degenerate geometry/length.
List<PassElevationPoint> passElevationProfile(Pass pass) {
  final summit = (pass.summitEle ?? pass.ele)?.toDouble();
  final startEle = pass.start?.ele?.toDouble();
  final endEle = pass.end?.ele?.toDouble();
  if (summit == null) return const [];
  if (startEle == null && endEle == null) return const [];

  final geom = pass.geometry;

  double totalKm;
  double colKm;
  // Which foot's elevation sits at km 0 vs. the far end. Defaults assume the
  // geometry is oriented start → end (as the dataset documents).
  var leftEle = startEle ?? summit;
  var rightEle = endEle ?? summit;

  if (geom.length >= 2) {
    final cum = cumulativeMeters(geom);
    totalKm = cum.last / 1000.0;
    if (totalKm <= 0) return const [];

    // The col vertex is the geometry point nearest the col coordinate.
    var colIdx = 0;
    var bestD = double.infinity;
    for (var i = 0; i < geom.length; i++) {
      final d = haversineMeters(geom[i], pass.latLng);
      if (d < bestD) {
        bestD = d;
        colIdx = i;
      }
    }
    colKm = (cum[colIdx] / 1000.0).clamp(0.0, totalKm);

    // Detect a reversed geometry (runs end → start) so the correct foot height
    // lands at km 0.
    final s = pass.start, e = pass.end;
    if (s != null && e != null) {
      final d0Start = haversineMeters(geom.first, s.latLng);
      final d0End = haversineMeters(geom.first, e.latLng);
      if (d0End < d0Start) {
        leftEle = endEle ?? summit;
        rightEle = startEle ?? summit;
      }
    }
  } else if (pass.lengthKm != null && pass.lengthKm! > 0) {
    // No geometry: still show two flanks, with the col mid-road as a best guess.
    totalKm = pass.lengthKm!;
    colKm = totalKm / 2;
  } else {
    return const [];
  }

  final raw = <PassElevationPoint>[
    PassElevationPoint(km: 0, ele: leftEle),
    PassElevationPoint(km: colKm, ele: summit),
    PassElevationPoint(km: totalKm, ele: rightEle),
  ];

  // Merge anchors closer than [_mergeKm] apart, keeping the higher elevation —
  // the summit dominates when it sits right at a foot.
  final out = <PassElevationPoint>[];
  for (final p in raw) {
    if (out.isNotEmpty && (p.km - out.last.km).abs() < _mergeKm) {
      final hi = p.ele > out.last.ele ? p.ele : out.last.ele;
      out[out.length - 1] = PassElevationPoint(km: out.last.km, ele: hi);
    } else {
      out.add(p);
    }
  }
  return out.length >= 2 ? out : const [];
}
