import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import '../services/geo.dart' show haversineMeters;

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

/// One Swiss mountain pass loaded from `assets/data/passes_ch.json`.
///
/// [lat]/[lon] are the col node itself (from OpenStreetMap) — crossing
/// detection is anchored to this point, so it has to be the real pass. The
/// optional facts are null when not confidently sourced; they are never
/// fabricated.
class Pass {
  const Pass({
    required this.name,
    required this.lat,
    required this.lon,
    required this.cantons,
    this.ele,
    this.connects,
    this.hairpins,
    this.maxGradientPct,
    this.climbLengthKm,
    this.osmId,
  });

  final String name;
  final double lat;
  final double lon;

  /// Cantons (and bordering countries for border cols, e.g. `IT`) the pass
  /// touches, e.g. `['UR', 'VS']`.
  final List<String> cantons;

  /// Elevation of the col in metres, or null if OSM had none.
  final int? ele;

  /// The two end places the pass road connects, e.g. `['Realp', 'Gletsch']`.
  final List<String>? connects;

  final int? hairpins;
  final double? maxGradientPct;
  final double? climbLengthKm;

  /// OSM node id of the col, for traceability back to the source.
  final int? osmId;

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

    return Pass(
      name: j['name'] as String,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      cantons: strList(j['cantons']) ?? const [],
      ele: toI(j['ele']),
      connects: strList(j['connects']),
      hairpins: toI(j['hairpins']),
      maxGradientPct: toD(j['maxGradientPct']),
      climbLengthKm: toD(j['climbLengthKm']),
      osmId: toI(j['osmId']),
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
class RideTrack {
  RideTrack({required this.rideId, required this.points, required this.times})
      : assert(points.length == times.length);

  final String rideId;
  final List<LatLng> points;
  final List<DateTime> times;

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
class Crossing {
  const Crossing({required this.rideId, required this.at});
  final String rideId;
  final DateTime at;
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
        out.add(Crossing(rideId: track.rideId, at: track.times[i]));
        armed = false;
      }
    } else {
      if (d >= rearmRadiusM) armed = true;
    }
  }
  return out;
}

/// The per-pass roll-up of how often, and when, it has been ridden.
class PassProgress {
  PassProgress({
    required this.pass,
    required this.count,
    required this.firstDate,
    required this.lastDate,
    required this.rideIds,
  });

  final Pass pass;

  /// Number of distinct crossings across all rides.
  final int count;
  final DateTime? firstDate;
  final DateTime? lastDate;

  /// Distinct ride ids that crossed this pass, in first-seen order.
  final List<String> rideIds;

  bool get crossed => count > 0;
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
      }
    }

    progress.add(PassProgress(
      pass: pass,
      count: count,
      firstDate: first,
      lastDate: last,
      rideIds: rideIds,
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
  PassProgress? highestCrossed;
  PassProgress? mostCrossed;
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
  );
}
