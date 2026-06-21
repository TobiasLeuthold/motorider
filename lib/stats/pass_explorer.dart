import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import '../services/geo.dart'
    show cumulativeMeters, haversineMeters, snapToPath;

/// Pässe (Swiss mountain-pass) exploration: the data model, the crossing
/// detector, and the collection aggregator.
///
/// Everything in this file is **pure** and side-effect free apart from
/// [loadPasses], which reads the bundled asset. Detection and aggregation
/// operate on plain [RideTrack]s (a ride's positions + timestamps) so the
/// logic is exercised headlessly in `test/pass_explorer_test.dart` without a
/// database, a map, or any Flutter binding.

/// Distance from the col within which a point counts as a crossing.
const double kTriggerRadiusM = 250.0;

/// Distance from the col the rider must leave before another crossing of the
/// same pass can be counted (hysteresis / re-arm threshold). Must be > the
/// trigger radius or the detector would never disarm.
const double kRearmRadiusM = 3000.0;

/// One end (a "foot") of a pass road segment: a point with its elevation.
class PassPoint {
  const PassPoint({required this.lat, required this.lon, this.ele});

  final double lat;
  final double lon;

  /// Elevation in metres, or null if not sourced.
  final int? ele;

  LatLng get latLng => LatLng(lat, lon);

  factory PassPoint.fromJson(Map<String, dynamic> j) => PassPoint(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        ele: j['ele'] == null ? null : (j['ele'] as num).toInt(),
      );
}

/// One Swiss mountain pass loaded from `assets/data/passes_ch.json`.
///
/// A pass is a road *segment*: it runs from [start] (the foot of the climb on
/// one side), up over the col, down to [end] (the foot on the other side).
///
/// [lat]/[lon] are the col node itself (from OpenStreetMap) — crossing
/// detection is anchored to this point, so it has to be the real pass. The
/// segment-derived fields ([start]/[end]/[summitEle]/[heightGainM]/[netDiffM]/
/// [lengthKm]/[maxGradientPct]/[geometry]/[hairpins]/[curvinessScore]) come
/// from OSM road geometry + SRTM elevation (see `tools/compute_pass_data.dart`)
/// and are approximate. Optional facts are null when not confidently sourced;
/// they are never fabricated.
class Pass {
  const Pass({
    required this.name,
    required this.lat,
    required this.lon,
    required this.cantons,
    this.ele,
    this.connects,
    this.hairpins,
    this.curvinessScore,
    this.maxGradientPct,
    this.climbLengthKm,
    this.osmId,
    this.start,
    this.end,
    this.summitEle,
    this.heightGainM,
    this.netDiffM,
    this.lengthKm,
    this.geometry = const [],
  });

  final String name;
  final double lat;
  final double lon;

  /// Cantons (and bordering countries for border cols, e.g. `IT`) the pass
  /// touches, e.g. `['UR', 'VS']`.
  final List<String> cantons;

  /// Elevation of the col in metres, or null if unknown. Mirrors [summitEle]
  /// (kept under the historical `ele` name so existing code/stats keep working).
  final int? ele;

  /// The two end places the pass road connects, e.g. `['Realp', 'Gletsch']`.
  final List<String>? connects;

  /// Number of hairpin switchbacks over the whole segment, computed from OSM
  /// road geometry (see `tools/compute_pass_data.dart`). Approximate; null when
  /// the road geometry couldn't be analysed.
  final int? hairpins;

  /// "Kurvigkeit" — degrees of heading change per kilometre along the pass
  /// road (see [curvinessScore] in `services/geo.dart`). ~0 for a dead-straight
  /// road, into the hundreds for a serpentine. Computed over the whole segment;
  /// null when unavailable.
  final double? curvinessScore;

  /// Steepest sustained gradient along the segment, in percent (approximate,
  /// from SRTM); null when not computed.
  final double? maxGradientPct;

  /// Deprecated alias retained for compatibility; prefer [lengthKm]. Always
  /// null in the v2 dataset.
  final double? climbLengthKm;

  /// OSM node id of the col, for traceability back to the source.
  final int? osmId;

  /// The two feet of the pass segment (valley-floor ends of the climb).
  final PassPoint? start;
  final PassPoint? end;

  /// Elevation of the col / summit in metres (same value as [ele]).
  final int? summitEle;

  /// Climb height: the summit minus the LOWER of the two feet, in metres.
  final int? heightGainM;

  /// Net elevation difference end-minus-start, in metres (signed).
  final int? netDiffM;

  /// Road distance start → over the col → end, in kilometres.
  final double? lengthKm;

  /// The segment road polyline (col + both feet preserved), downsampled to a
  /// handful of dozen points for drawing. Empty when not available.
  final List<LatLng> geometry;

  LatLng get latLng => LatLng(lat, lon);

  factory Pass.fromJson(Map<String, dynamic> j) {
    List<String>? strList(Object? v) {
      if (v is List) {
        return v.map((e) => e.toString()).toList(growable: false);
      }
      return null;
    }

    double? toD(Object? v) => v == null ? null : (v as num).toDouble();
    int? toI(Object? v) => v == null ? null : (v as num).toInt();

    PassPoint? toPoint(Object? v) =>
        v is Map ? PassPoint.fromJson(v.cast<String, dynamic>()) : null;

    // geometry is a list of [lat, lon] pairs.
    List<LatLng> toGeom(Object? v) {
      if (v is! List) return const [];
      final out = <LatLng>[];
      for (final e in v) {
        if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
          out.add(LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()));
        }
      }
      return out;
    }

    final ele = toI(j['ele']) ?? toI(j['summitEle']);
    return Pass(
      name: j['name'] as String,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      cantons: strList(j['cantons']) ?? const [],
      ele: ele,
      connects: strList(j['connects']),
      hairpins: toI(j['hairpins']),
      curvinessScore: toD(j['curvinessScore']),
      maxGradientPct: toD(j['maxGradientPct']),
      climbLengthKm: toD(j['climbLengthKm']),
      osmId: toI(j['osmId']),
      start: toPoint(j['start']),
      end: toPoint(j['end']),
      summitEle: toI(j['summitEle']) ?? ele,
      heightGainM: toI(j['heightGainM']),
      netDiffM: toI(j['netDiffM']),
      lengthKm: toD(j['lengthKm']),
      geometry: toGeom(j['geometry']),
    );
  }
}

/// Parse the pass list from the raw JSON document string (pure — used directly
/// by tests so they don't need the asset bundle).
List<Pass> parsePasses(String jsonStr) {
  final doc = jsonDecode(jsonStr);
  final list = (doc is Map) ? doc['passes'] : doc;
  if (list is! List) return const [];
  return [
    for (final e in list)
      if (e is Map) Pass.fromJson(e.cast<String, dynamic>()),
  ];
}

/// Pull the human-readable attribution string out of the document (for the
/// OSM/ODbL footer). Returns a sensible default if the field is absent.
String parseAttribution(String jsonStr) {
  final doc = jsonDecode(jsonStr);
  if (doc is Map && doc['_attribution'] is String) {
    return doc['_attribution'] as String;
  }
  return 'Pass data © OpenStreetMap contributors (ODbL).';
}

const String passesAssetPath = 'assets/data/passes_ch.json';

/// Load + parse the bundled pass dataset. The only impure entry point here.
Future<List<Pass>> loadPasses() async {
  final raw = await rootBundle.loadString(passesAssetPath);
  return parsePasses(raw);
}

/// Load just the attribution string from the bundled dataset.
Future<String> loadPassAttribution() async {
  final raw = await rootBundle.loadString(passesAssetPath);
  return parseAttribution(raw);
}

/// A single ride reduced to what the detector needs: an id and its
/// time-ordered fixes. [points] and [times] are parallel and must be the same
/// length; callers feeding ride points downsample if they like, but not so
/// coarsely that a 250 m approach to a col is stepped over.
///
/// [speedsMs] is an OPTIONAL parallel list of recorded GPS speeds in metres per
/// second (one per point). When present it is the preferred source for a
/// crossing's average speed; when empty (or full of nulls/zeros over a window)
/// the per-crossing stats fall back to corridor distance ÷ elapsed time. It is
/// kept optional so existing callers and unit tests can omit it.
class RideTrack {
  RideTrack({
    required this.rideId,
    required this.points,
    required this.times,
    this.speedsMs = const [],
  })  : assert(points.length == times.length),
        assert(speedsMs.isEmpty || speedsMs.length == points.length);

  final String rideId;
  final List<LatLng> points;
  final List<DateTime> times;

  /// Recorded GPS speeds (m/s), parallel to [points], or empty if unavailable.
  /// Individual entries may be null where a fix had no speed.
  final List<double?> speedsMs;

  bool get isEmpty => points.isEmpty;
}

/// Axis-aligned lat/lon bounding box of a set of points, used to cheaply prune
/// rides that come nowhere near a given col before the per-point scan.
class _BBox {
  _BBox(this.minLat, this.minLon, this.maxLat, this.maxLon);

  final double minLat, minLon, maxLat, maxLon;

  static _BBox? of(List<LatLng> pts) {
    if (pts.isEmpty) return null;
    var minLa = pts.first.latitude, maxLa = pts.first.latitude;
    var minLo = pts.first.longitude, maxLo = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLa) minLa = p.latitude;
      if (p.latitude > maxLa) maxLa = p.latitude;
      if (p.longitude < minLo) minLo = p.longitude;
      if (p.longitude > maxLo) maxLo = p.longitude;
    }
    return _BBox(minLa, minLo, maxLa, maxLo);
  }

  /// Shortest great-circle distance (m) from [c] to this box; 0 when inside.
  double distanceTo(LatLng c) {
    final clampedLat = c.latitude.clamp(minLat, maxLat);
    final clampedLon = c.longitude.clamp(minLon, maxLon);
    return haversineMeters(c, LatLng(clampedLat, clampedLon));
  }
}

/// True when [track]'s bounding box comes within [marginM] of [col]. Used to
/// skip the full per-point scan for rides that can't possibly cross the pass.
bool trackMayReach(RideTrack track, LatLng col,
    {double marginM = kRearmRadiusM}) {
  final box = _BBox.of(track.points);
  if (box == null) return false;
  return box.distanceTo(col) <= marginM;
}

/// One detected crossing of a pass.
///
/// [triggerIndex] is the index, in the originating [RideTrack], of the fix that
/// fired this crossing (the first one inside the trigger radius). It anchors the
/// per-crossing corridor analysis ([crossingStats]).
class Crossing {
  const Crossing({
    required this.rideId,
    required this.at,
    required this.triggerIndex,
  });
  final String rideId;
  final DateTime at;
  final int triggerIndex;
}

/// Walk a single ride's points and count crossings of [col] with hysteresis.
///
/// The rider starts `armed`. While armed, the first fix within
/// [triggerRadiusM] of the col fires a crossing (timestamped at that fix) and
/// disarms. While disarmed, the rider must get at least [rearmRadiusM] away
/// before another crossing can fire. This makes lingering on the col, or GPS
/// jitter dancing in and out of the trigger radius, count exactly once, while a
/// genuine out-and-back that leaves the re-arm radius and returns counts twice.
List<Crossing> detectCrossingsInTrack(
  RideTrack track,
  LatLng col, {
  double triggerRadiusM = kTriggerRadiusM,
  double rearmRadiusM = kRearmRadiusM,
}) {
  final out = <Crossing>[];
  var armed = true;
  for (var i = 0; i < track.points.length; i++) {
    final d = haversineMeters(track.points[i], col);
    if (armed) {
      if (d <= triggerRadiusM) {
        out.add(Crossing(
          rideId: track.rideId,
          at: track.times[i],
          triggerIndex: i,
        ));
        armed = false;
      }
    } else {
      if (d >= rearmRadiusM) armed = true;
    }
  }
  return out;
}

// ───────────────────────── per-crossing corridor stats ─────────────────────
//
// Once the hysteresis detector has decided THAT a crossing happened (and
// anchored it at a trigger fix), these pure helpers measure HOW it was ridden:
// the rider's average speed, the time spent, and the direction of travel over
// the pass. The math is deliberately split out from the detector so it can be
// unit-tested in isolation and never perturbs the crossing count.

/// Half-width of the pass "corridor": a fix counts as on the pass when it is
/// within this perpendicular distance of the segment [Pass.geometry] polyline.
/// Wide enough to absorb GPS noise and a road that is a few metres off the
/// downsampled polyline, tight enough to exclude a parallel valley road.
const double kCorridorHalfWidthM = 120.0;

/// Below this implied leg speed (≈ 5 km/h) the rider is treated as stopped — a
/// red light, a junction, a photo halt — and that leg's time is excluded from
/// the moving time. Genuine slow riding (a tight hairpin) stays well above it.
const double kStoppedSpeedMs = 1.4;

/// To time a crossing as a fixed-distance foot-to-foot traversal, the ride must
/// actually pass within this of BOTH the [Pass.start] and [Pass.end] feet. A
/// ride that started mid-pass, or went up one side and back down the same one,
/// never reaches a foot — it still counts as a crossing but gets no comparable
/// speed (the fixed street distance wasn't actually travelled).
const double kFootReachedM = 250.0;

/// Sanity ceiling for a fixed-distance pass average (km/h). A value above this
/// means the moving time was implausibly short (a GPS artefact), so the speed is
/// dropped rather than shown.
const double kMaxPassAvgSpeedKmh = 130.0;

/// Which way the rider travelled over a pass segment, relative to the dataset's
/// [Pass.start] → [Pass.end] orientation.
enum PassDirection {
  /// From the [Pass.start] foot, over the col, towards the [Pass.end] foot.
  startToEnd,

  /// From the [Pass.end] foot back towards the [Pass.start] foot.
  endToStart,

  /// Direction could not be determined (no usable geometry / too few points).
  unknown,
}

/// The measured profile of one crossing: how fast, how long, which way.
class PassCrossing {
  const PassCrossing({
    required this.rideId,
    required this.at,
    required this.direction,
    this.avgSpeedKmh,
    this.movingTimeS,
    this.durationS,
    this.directionLabel,
  });

  final String rideId;

  /// When the crossing fired (the trigger fix's timestamp).
  final DateTime at;

  final PassDirection direction;

  /// Average speed over the pass, in km/h, from the pass's FIXED street distance
  /// ([Pass.lengthKm]) ÷ [movingTimeS] — never the GPS track length (which
  /// wobbles run to run), and with stopped time excluded. Null when this wasn't
  /// a genuine foot-to-foot traversal or the street length is unknown.
  final double? avgSpeedKmh;

  /// Moving time over the foot-to-foot traversal, in seconds, with stopped legs
  /// (red lights etc.) removed. The denominator of [avgSpeedKmh] and the time
  /// shown to the rider. Null when not a measurable traversal.
  final int? movingTimeS;

  /// Total wall-clock seconds inside the corridor, INCLUDING any stops — kept for
  /// reference (e.g. a "standing N min" readout). Null when unknown.
  final int? durationS;

  /// Human-readable German direction label, e.g. `'Realp → Gletsch'`, or a
  /// `'↑'` / `'↓'` arrow when the connected place names are unavailable. Null
  /// when the direction is [PassDirection.unknown].
  final String? directionLabel;
}

/// Build the German direction label for [dir] over [pass], preferring the
/// connected place names ("Realp → Gletsch") and falling back to arrows.
String? passDirectionLabel(Pass pass, PassDirection dir) {
  if (dir == PassDirection.unknown) return null;
  final names = pass.connects;
  // connects is given in start→end order (same orientation as the segment).
  if (names != null && names.length >= 2) {
    final a = names.first.trim();
    final b = names.last.trim();
    if (a.isNotEmpty && b.isNotEmpty) {
      return dir == PassDirection.startToEnd ? '$a → $b' : '$b → $a';
    }
  }
  return dir == PassDirection.startToEnd ? '↑' : '↓';
}

/// The contiguous run of fixes around a crossing that lie inside the pass
/// corridor — the slice the speed/time/direction are measured over.
class CorridorWindow {
  const CorridorWindow({
    required this.startIndex,
    required this.endIndex,
    required this.entryNearStartFoot,
  });

  /// Inclusive index of the first corridor fix in the ride track.
  final int startIndex;

  /// Inclusive index of the last corridor fix in the ride track.
  final int endIndex;

  /// True when the rider ENTERED the corridor nearer the [Pass.start] foot than
  /// the [Pass.end] foot — i.e. travelling start→end. Null when undecidable.
  final bool? entryNearStartFoot;

  int get length => endIndex - startIndex + 1;
}

/// True when [p] is within [halfWidthM] of the segment polyline [geometry]
/// (or, with no usable polyline, within [halfWidthM] of either foot). Pure.
bool isInCorridor(
  LatLng p,
  List<LatLng> geometry, {
  PassPoint? startFoot,
  PassPoint? endFoot,
  double halfWidthM = kCorridorHalfWidthM,
  List<double>? cumulative,
}) {
  if (geometry.length >= 2) {
    final snap = snapToPath(p, geometry, cumulative: cumulative);
    if (snap != null) return snap.crossTrackMeters <= halfWidthM;
  }
  // Degenerate geometry: fall back to nearness to either foot.
  for (final f in [startFoot, endFoot]) {
    if (f != null && haversineMeters(p, f.latLng) <= halfWidthM) return true;
  }
  return false;
}

/// Find the maximal run of consecutive corridor fixes that contains the
/// [triggerIndex] fix. The crossing's stats are computed over exactly this run,
/// so two distinct crossings (each with its own trigger) get measured
/// independently even within one ride. Returns null when the trigger fix itself
/// isn't in the corridor (e.g. a ride that only clips the corridor edge near
/// the col without ever entering it — not a full crossing to measure).
CorridorWindow? corridorWindow(
  RideTrack track,
  Pass pass, {
  required int triggerIndex,
  double halfWidthM = kCorridorHalfWidthM,
}) {
  final pts = track.points;
  if (triggerIndex < 0 || triggerIndex >= pts.length) return null;
  final geom = pass.geometry;
  final cum = geom.length >= 2 ? cumulativeMeters(geom) : null;

  bool inCorr(int i) => isInCorridor(
        pts[i],
        geom,
        startFoot: pass.start,
        endFoot: pass.end,
        halfWidthM: halfWidthM,
        cumulative: cum,
      );

  if (!inCorr(triggerIndex)) return null;

  var lo = triggerIndex;
  while (lo - 1 >= 0 && inCorr(lo - 1)) {
    lo--;
  }
  var hi = triggerIndex;
  while (hi + 1 < pts.length && inCorr(hi + 1)) {
    hi++;
  }

  // Direction: compare the entry fix's distance to each foot.
  bool? entryNearStart;
  final s = pass.start, e = pass.end;
  if (s != null && e != null) {
    final entry = pts[lo];
    final dStart = haversineMeters(entry, s.latLng);
    final dEnd = haversineMeters(entry, e.latLng);
    if ((dStart - dEnd).abs() > 1e-6) entryNearStart = dStart < dEnd;
  }

  return CorridorWindow(
    startIndex: lo,
    endIndex: hi,
    entryNearStartFoot: entryNearStart,
  );
}

/// Total moving time over the legs `[lo, hi]`, in milliseconds, with stopped
/// legs (implied speed below [kStoppedSpeedMs]) removed — so a red light or a
/// photo halt doesn't inflate it. Pure.
double _movingTimeMs(RideTrack track, int lo, int hi) {
  var ms = 0.0;
  for (var i = lo + 1; i <= hi; i++) {
    final dt =
        track.times[i].difference(track.times[i - 1]).inMilliseconds.toDouble();
    if (dt <= 0) continue;
    final segM = haversineMeters(track.points[i - 1], track.points[i]);
    if (segM / (dt / 1000.0) < kStoppedSpeedMs) continue; // stopped — exclude
    ms += dt;
  }
  return ms;
}

/// The index in `[lo, hi]` whose fix is nearest [foot], plus that distance.
({int index, double distanceM}) _nearestFix(
    RideTrack track, int lo, int hi, PassPoint foot) {
  var bestI = lo;
  var bestD = double.infinity;
  for (var i = lo; i <= hi; i++) {
    final d = haversineMeters(track.points[i], foot.latLng);
    if (d < bestD) {
      bestD = d;
      bestI = i;
    }
  }
  return (index: bestI, distanceM: bestD);
}

/// Measure a single crossing as a fixed-distance, foot-to-foot traversal: the
/// direction, the moving time between the two defined feet (stops removed), and
/// the average speed from the pass's known street distance ÷ that moving time.
/// Pure and fully unit-testable. Returns null when [crossing] doesn't correspond
/// to a real corridor traversal (trigger fix not in the corridor).
///
/// Why fixed distance: integrating the GPS track gives a slightly different
/// length each ride (10 km one time, 11 the next), so dividing it by time isn't
/// comparable. The pass's [Pass.lengthKm] is one fixed number, so between rides
/// only the (stop-free) time varies — exactly what makes two ascents comparable.
/// When the ride didn't actually reach both feet, or the length is unknown, the
/// speed is left null (the fixed street distance wasn't really ridden).
PassCrossing? crossingStats(
  RideTrack track,
  Pass pass,
  Crossing crossing, {
  double halfWidthM = kCorridorHalfWidthM,
}) {
  final win = corridorWindow(
    track,
    pass,
    triggerIndex: crossing.triggerIndex,
    halfWidthM: halfWidthM,
  );
  if (win == null) return null;

  final lo = win.startIndex, hi = win.endIndex;
  // Total wall-clock in the corridor (incl. stops), kept for reference.
  final elapsedS = track.times[hi].difference(track.times[lo]).inSeconds;

  PassDirection direction;
  int? movingTimeS;
  double? avgKmh;

  final s = pass.start, e = pass.end;
  final start = s != null ? _nearestFix(track, lo, hi, s) : null;
  final end = e != null ? _nearestFix(track, lo, hi, e) : null;

  if (start != null &&
      end != null &&
      start.index != end.index &&
      start.distanceM <= kFootReachedM &&
      end.distanceM <= kFootReachedM) {
    // Genuine foot-to-foot traversal: time it between the two feet only.
    direction = start.index < end.index
        ? PassDirection.startToEnd
        : PassDirection.endToStart;
    final a = start.index < end.index ? start.index : end.index;
    final b = start.index < end.index ? end.index : start.index;
    final movingMs = _movingTimeMs(track, a, b);
    if (movingMs > 0) {
      movingTimeS = (movingMs / 1000).round();
      final len = pass.lengthKm;
      if (len != null && len > 0) {
        final kmh = len / (movingMs / 3600000.0);
        if (kmh > 0 && kmh <= kMaxPassAvgSpeedKmh) avgKmh = kmh;
      }
    }
  } else {
    // Not a clean foot-to-foot traversal (started mid-pass, or up-and-back the
    // same side): still a crossing, but no comparable fixed-distance speed.
    final near = win.entryNearStartFoot;
    direction = near == null
        ? PassDirection.unknown
        : (near ? PassDirection.startToEnd : PassDirection.endToStart);
  }

  return PassCrossing(
    rideId: crossing.rideId,
    at: crossing.at,
    direction: direction,
    avgSpeedKmh: avgKmh,
    movingTimeS: movingTimeS,
    durationS: elapsedS > 0 ? elapsedS : null,
    directionLabel: passDirectionLabel(pass, direction),
  );
}

/// The per-pass roll-up of how often, and when, it has been ridden.
class PassProgress {
  PassProgress({
    required this.pass,
    required this.count,
    required this.firstDate,
    required this.lastDate,
    required this.rideIds,
    this.crossings = const [],
  });

  final Pass pass;

  /// Number of distinct crossings across all rides.
  final int count;
  final DateTime? firstDate;
  final DateTime? lastDate;

  /// Distinct ride ids that crossed this pass, in first-seen order.
  final List<String> rideIds;

  /// The measured profile of every crossing (direction, avg speed, duration),
  /// in chronological order. May be shorter than [count] for crossings whose
  /// corridor couldn't be measured; empty when not computed. Additive — older
  /// callers ignore it.
  final List<PassCrossing> crossings;

  bool get crossed => count > 0;

  /// Fastest single-crossing average speed over this pass (km/h), or null when
  /// no crossing had a measurable speed.
  double? get bestSpeedKmh {
    double? best;
    for (final c in crossings) {
      final v = c.avgSpeedKmh;
      if (v == null) continue;
      if (best == null || v > best) best = v;
    }
    return best;
  }

  /// Mean of the per-crossing average speeds (km/h), or null when none are
  /// measurable.
  double? get meanSpeedKmh {
    var sum = 0.0;
    var n = 0;
    for (final c in crossings) {
      final v = c.avgSpeedKmh;
      if (v == null) continue;
      sum += v;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  /// Total moving time on this pass across all measured crossings, in seconds
  /// (stops excluded; falls back to corridor elapsed for any crossing without a
  /// measured moving time).
  int get totalTimeOnPassS {
    var s = 0;
    for (final c in crossings) {
      s += c.movingTimeS ?? c.durationS ?? 0;
    }
    return s;
  }

  /// Per-direction roll-up over the two ways the pass can be ridden. Only
  /// directions with at least one *measured* (foot-to-foot, fixed-distance)
  /// crossing appear. The two ascents differ (one side climbs more), so these
  /// are kept apart rather than pooled.
  List<DirectionStats> get directions {
    final out = <DirectionStats>[];
    for (final d in const [
      PassDirection.startToEnd,
      PassDirection.endToStart,
    ]) {
      final s = _directionStats(d);
      if (s.count > 0) out.add(s);
    }
    return out;
  }

  DirectionStats _directionStats(PassDirection dir) {
    double? best;
    int? bestTimeS;
    var sum = 0.0;
    var n = 0;
    for (final c in crossings) {
      if (c.direction != dir) continue;
      final v = c.avgSpeedKmh;
      if (v == null) continue; // only fixed-distance-measured traversals
      n++;
      sum += v;
      if (best == null || v > best) {
        best = v;
        bestTimeS = c.movingTimeS;
      }
    }
    return DirectionStats(
      direction: dir,
      label: passDirectionLabel(pass, dir),
      count: n,
      bestSpeedKmh: best,
      bestTimeS: bestTimeS,
      meanSpeedKmh: n == 0 ? null : sum / n,
    );
  }
}

/// Per-direction summary for a pass: how many measured crossings this way, the
/// fastest (and its moving time), and the average — all over the FIXED segment
/// distance, so the numbers are directly comparable between rides.
class DirectionStats {
  const DirectionStats({
    required this.direction,
    required this.label,
    required this.count,
    this.bestSpeedKmh,
    this.bestTimeS,
    this.meanSpeedKmh,
  });

  final PassDirection direction;

  /// e.g. `'Realp → Gletsch'`, or an arrow when place names are unavailable.
  final String? label;

  /// Number of measured (fixed-distance) crossings in this direction.
  final int count;

  /// Fastest average speed (km/h) achieved this way, and the moving time of that
  /// fastest run (seconds). Null when nothing measured.
  final double? bestSpeedKmh;
  final int? bestTimeS;

  /// Mean of the per-crossing average speeds (km/h) this way. Null when none.
  final double? meanSpeedKmh;
}

/// The single fastest pass crossing across the whole collection: which pass and
/// how fast (km/h average over the corridor), plus when and which ride.
class FastestCrossing {
  const FastestCrossing({
    required this.pass,
    required this.avgSpeedKmh,
    required this.at,
    required this.rideId,
    this.directionLabel,
    this.movingTimeS,
  });

  final Pass pass;
  final double avgSpeedKmh;
  final DateTime at;
  final String rideId;

  /// Which way this fastest crossing was ridden (e.g. `'Realp → Gletsch'`), or
  /// null when undecidable.
  final String? directionLabel;

  /// Moving time of this fastest crossing, in seconds, or null.
  final int? movingTimeS;
}

/// Collection-wide totals derived from the per-pass progress.
class CollectionStats {
  CollectionStats({
    required this.total,
    required this.explored,
    required this.metresCollected,
    required this.totalHairpins,
    required this.highestCrossed,
    required this.highestUncrossed,
    required this.mostCrossed,
    required this.perCanton,
    this.fastestCrossing,
    this.totalTimeOnPassesS = 0,
  });

  /// Total passes in the dataset.
  final int total;

  /// How many have been crossed at least once.
  final int explored;

  /// Sum of `ele` over crossed passes (metres "collected").
  final int metresCollected;

  /// Sum of known `hairpins` over crossed passes (passes with null hairpins
  /// contribute nothing).
  final int totalHairpins;

  /// Highest crossed / highest not-yet-crossed pass (by `ele`), or null.
  final PassProgress? highestCrossed;
  final PassProgress? highestUncrossed;

  /// The most-crossed pass (max [PassProgress.count]); null if nothing crossed.
  final PassProgress? mostCrossed;

  /// Per-canton progress, keyed by canton code → (done, total). A pass that
  /// touches two cantons counts towards both.
  final Map<String, CantonProgress> perCanton;

  /// Your fastest single pass crossing anywhere in the collection (pass +
  /// average speed), or null when no crossing had a measurable speed.
  final FastestCrossing? fastestCrossing;

  /// Total time spent on passes — the sum of every measured crossing's
  /// duration, in seconds. 0 when nothing has been measured.
  final int totalTimeOnPassesS;

  double get percent => total == 0 ? 0 : explored * 100.0 / total;
}

/// Done/total tally for a single canton.
class CantonProgress {
  const CantonProgress(this.done, this.total);
  final int done;
  final int total;

  double get percent => total == 0 ? 0 : done * 100.0 / total;
}

/// The full result of running detection over the dataset and all rides.
class PassExplorationResult {
  PassExplorationResult({required this.progress, required this.stats});

  /// Per-pass progress, in the same order as the input [passes].
  final List<PassProgress> progress;
  final CollectionStats stats;
}

/// Run crossing detection for every pass against every ride and aggregate the
/// collection stats. Pure: feed it the dataset and the ride tracks, get back
/// per-pass progress + totals. Bbox-prunes each (pass, ride) pair before the
/// per-point scan so unrelated rides are skipped cheaply.
PassExplorationResult explorePasses(
  List<Pass> passes,
  List<RideTrack> rides, {
  double triggerRadiusM = kTriggerRadiusM,
  double rearmRadiusM = kRearmRadiusM,
}) {
  final progress = <PassProgress>[];

  for (final pass in passes) {
    final col = pass.latLng;
    var count = 0;
    DateTime? first;
    DateTime? last;
    final rideIds = <String>[];
    final seenRides = <String>{};
    final measured = <PassCrossing>[];

    for (final ride in rides) {
      if (ride.isEmpty) continue;
      // Cheap reject: ride can't come within re-arm distance of the col.
      if (!trackMayReach(ride, col, marginM: rearmRadiusM)) continue;
      final crossings = detectCrossingsInTrack(
        ride,
        col,
        triggerRadiusM: triggerRadiusM,
        rearmRadiusM: rearmRadiusM,
      );
      if (crossings.isEmpty) continue;
      count += crossings.length;
      if (seenRides.add(ride.rideId)) rideIds.add(ride.rideId);
      for (final c in crossings) {
        if (first == null || c.at.isBefore(first)) first = c.at;
        if (last == null || c.at.isAfter(last)) last = c.at;
        // Measure how this crossing was ridden (speed/time/direction).
        final stats = crossingStats(ride, pass, c);
        if (stats != null) measured.add(stats);
      }
    }

    measured.sort((a, b) => a.at.compareTo(b.at));
    progress.add(PassProgress(
      pass: pass,
      count: count,
      firstDate: first,
      lastDate: last,
      rideIds: rideIds,
      crossings: measured,
    ));
  }

  return PassExplorationResult(
    progress: progress,
    stats: _aggregate(passes, progress),
  );
}

CollectionStats _aggregate(List<Pass> passes, List<PassProgress> progress) {
  final crossed = [for (final p in progress) if (p.crossed) p];

  var metres = 0;
  var hairpins = 0;
  var totalTimeOnPassesS = 0;
  PassProgress? highestCrossed;
  PassProgress? mostCrossed;
  FastestCrossing? fastest;
  for (final p in crossed) {
    final ele = p.pass.ele;
    if (ele != null) metres += ele;
    final h = p.pass.hairpins;
    if (h != null) hairpins += h;
    if (ele != null &&
        (highestCrossed == null ||
            (highestCrossed.pass.ele ?? -1) < ele)) {
      highestCrossed = p;
    }
    if (mostCrossed == null || p.count > mostCrossed.count) {
      mostCrossed = p;
    }
    // Per-crossing roll-ups: total moving time on passes + the single fastest
    // (fixed-distance) crossing anywhere.
    for (final c in p.crossings) {
      totalTimeOnPassesS += c.movingTimeS ?? c.durationS ?? 0;
      final v = c.avgSpeedKmh;
      if (v != null && (fastest == null || v > fastest.avgSpeedKmh)) {
        fastest = FastestCrossing(
          pass: p.pass,
          avgSpeedKmh: v,
          at: c.at,
          rideId: c.rideId,
          directionLabel: c.directionLabel,
          movingTimeS: c.movingTimeS,
        );
      }
    }
  }

  PassProgress? highestUncrossed;
  for (final p in progress) {
    if (p.crossed) continue;
    final ele = p.pass.ele;
    if (ele == null) continue;
    if (highestUncrossed == null || (highestUncrossed.pass.ele ?? -1) < ele) {
      highestUncrossed = p;
    }
  }

  // Per-canton done/total. A multi-canton pass counts for each of its cantons.
  final total = <String, int>{};
  final done = <String, int>{};
  for (final p in progress) {
    for (final c in p.pass.cantons) {
      total[c] = (total[c] ?? 0) + 1;
      if (p.crossed) done[c] = (done[c] ?? 0) + 1;
    }
  }
  final perCanton = <String, CantonProgress>{
    for (final c in total.keys) c: CantonProgress(done[c] ?? 0, total[c]!),
  };

  return CollectionStats(
    total: passes.length,
    explored: crossed.length,
    metresCollected: metres,
    totalHairpins: hairpins,
    highestCrossed: highestCrossed,
    highestUncrossed: highestUncrossed,
    mostCrossed: mostCrossed,
    perCanton: perCanton,
    fastestCrossing: fastest,
    totalTimeOnPassesS: totalTimeOnPassesS,
  );
}
