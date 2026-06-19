import '../models/ride.dart';

/// Which metric a sort order ranks rides by, and in which direction.
///
/// `newest` is the default and matches the old plain history list
/// (descending [Ride.startedAt]). The remaining orders rank a numeric ride
/// metric descending — "longest / fastest first".
enum RideSort {
  newest,
  longestDistance,
  fastestAvg,
  fastestMax,
  longestDuration,
}

extension RideSortLabel on RideSort {
  /// German label for the sort chip / menu.
  String get label => switch (this) {
        RideSort.newest => 'Neueste',
        RideSort.longestDistance => 'Distanz',
        RideSort.fastestAvg => 'Ø Tempo',
        RideSort.fastestMax => 'Max Tempo',
        RideSort.longestDuration => 'Dauer',
      };
}

/// A value describing how the past-rides list is filtered. Every field is
/// optional; a `null` bound means "don't constrain this dimension". The empty
/// filter ([RideFilter.none]) matches every ride.
///
/// Ranges are inclusive on both ends. Bounds are expressed in the same units
/// the [Ride] model exposes (km, km/h, and a [Duration] for ride length).
class RideFilter {
  const RideFilter({
    this.minDistanceKm,
    this.maxDistanceKm,
    this.minAvgSpeedKmh,
    this.maxAvgSpeedKmh,
    this.minMaxSpeedKmh,
    this.maxMaxSpeedKmh,
    this.minDuration,
    this.maxDuration,
    this.from,
    this.to,
    this.sort = RideSort.newest,
  });

  final double? minDistanceKm;
  final double? maxDistanceKm;

  final double? minAvgSpeedKmh;
  final double? maxAvgSpeedKmh;

  final double? minMaxSpeedKmh;
  final double? maxMaxSpeedKmh;

  /// Filters on [Ride.totalDuration] (wall-clock length of the ride).
  final Duration? minDuration;
  final Duration? maxDuration;

  /// Date window on [Ride.startedAt]. `from` is the inclusive start of the
  /// window, `to` the inclusive end (callers typically pass the end of the
  /// chosen day).
  final DateTime? from;
  final DateTime? to;

  final RideSort sort;

  /// The neutral filter: no constraints, newest-first.
  static const none = RideFilter();

  /// True when no range/date dimension constrains the list (sort is ignored —
  /// it never hides rides). Used to decide whether to show a "filter active"
  /// affordance and the reset button.
  bool get hasActiveConstraints =>
      minDistanceKm != null ||
      maxDistanceKm != null ||
      minAvgSpeedKmh != null ||
      maxAvgSpeedKmh != null ||
      minMaxSpeedKmh != null ||
      maxMaxSpeedKmh != null ||
      minDuration != null ||
      maxDuration != null ||
      from != null ||
      to != null;

  /// Number of constrained dimensions (distance / avg / max / duration / date
  /// each count once, regardless of whether one or both bounds are set). Drives
  /// the little "n" badge on the filter button.
  int get activeDimensionCount {
    var n = 0;
    if (minDistanceKm != null || maxDistanceKm != null) n++;
    if (minAvgSpeedKmh != null || maxAvgSpeedKmh != null) n++;
    if (minMaxSpeedKmh != null || maxMaxSpeedKmh != null) n++;
    if (minDuration != null || maxDuration != null) n++;
    if (from != null || to != null) n++;
    return n;
  }

  /// Does a single ride pass every active constraint? (Sort-independent.)
  bool matches(Ride ride) {
    if (minDistanceKm != null && ride.distanceKm < minDistanceKm!) return false;
    if (maxDistanceKm != null && ride.distanceKm > maxDistanceKm!) return false;

    if (minAvgSpeedKmh != null && ride.avgMovingSpeedKmh < minAvgSpeedKmh!) {
      return false;
    }
    if (maxAvgSpeedKmh != null && ride.avgMovingSpeedKmh > maxAvgSpeedKmh!) {
      return false;
    }

    if (minMaxSpeedKmh != null && ride.maxSpeedKmh < minMaxSpeedKmh!) {
      return false;
    }
    if (maxMaxSpeedKmh != null && ride.maxSpeedKmh > maxMaxSpeedKmh!) {
      return false;
    }

    if (minDuration != null && ride.totalDuration < minDuration!) return false;
    if (maxDuration != null && ride.totalDuration > maxDuration!) return false;

    if (from != null && ride.startedAt.isBefore(from!)) return false;
    if (to != null && ride.startedAt.isAfter(to!)) return false;

    return true;
  }

  RideFilter copyWith({
    Object? minDistanceKm = _sentinel,
    Object? maxDistanceKm = _sentinel,
    Object? minAvgSpeedKmh = _sentinel,
    Object? maxAvgSpeedKmh = _sentinel,
    Object? minMaxSpeedKmh = _sentinel,
    Object? maxMaxSpeedKmh = _sentinel,
    Object? minDuration = _sentinel,
    Object? maxDuration = _sentinel,
    Object? from = _sentinel,
    Object? to = _sentinel,
    RideSort? sort,
  }) {
    return RideFilter(
      minDistanceKm: identical(minDistanceKm, _sentinel)
          ? this.minDistanceKm
          : minDistanceKm as double?,
      maxDistanceKm: identical(maxDistanceKm, _sentinel)
          ? this.maxDistanceKm
          : maxDistanceKm as double?,
      minAvgSpeedKmh: identical(minAvgSpeedKmh, _sentinel)
          ? this.minAvgSpeedKmh
          : minAvgSpeedKmh as double?,
      maxAvgSpeedKmh: identical(maxAvgSpeedKmh, _sentinel)
          ? this.maxAvgSpeedKmh
          : maxAvgSpeedKmh as double?,
      minMaxSpeedKmh: identical(minMaxSpeedKmh, _sentinel)
          ? this.minMaxSpeedKmh
          : minMaxSpeedKmh as double?,
      maxMaxSpeedKmh: identical(maxMaxSpeedKmh, _sentinel)
          ? this.maxMaxSpeedKmh
          : maxMaxSpeedKmh as double?,
      minDuration: identical(minDuration, _sentinel)
          ? this.minDuration
          : minDuration as Duration?,
      maxDuration: identical(maxDuration, _sentinel)
          ? this.maxDuration
          : maxDuration as Duration?,
      from: identical(from, _sentinel) ? this.from : from as DateTime?,
      to: identical(to, _sentinel) ? this.to : to as DateTime?,
      sort: sort ?? this.sort,
    );
  }

  /// Drop every range/date constraint but keep the current [sort].
  RideFilter clearedConstraints() => RideFilter(sort: sort);
}

/// Filter then sort [rides] according to [filter]. Pure: returns a new list and
/// never mutates the input. Always sorts (even the "newest" default) so the
/// caller can hand us any-ordered input and get a deterministic result.
///
/// All numeric sorts are descending ("most first") with [Ride.startedAt]
/// (newest first) as the tie-breaker so equal-metric rides stay stably ordered.
List<Ride> applyRideFilter(List<Ride> rides, RideFilter filter) {
  final out = [
    for (final r in rides)
      if (filter.matches(r)) r,
  ];

  int byDateDesc(Ride a, Ride b) => b.startedAt.compareTo(a.startedAt);

  int withDateTieBreak(int primary, Ride a, Ride b) =>
      primary != 0 ? primary : byDateDesc(a, b);

  switch (filter.sort) {
    case RideSort.newest:
      out.sort(byDateDesc);
    case RideSort.longestDistance:
      out.sort((a, b) =>
          withDateTieBreak(b.distanceKm.compareTo(a.distanceKm), a, b));
    case RideSort.fastestAvg:
      out.sort((a, b) => withDateTieBreak(
          b.avgMovingSpeedKmh.compareTo(a.avgMovingSpeedKmh), a, b));
    case RideSort.fastestMax:
      out.sort((a, b) =>
          withDateTieBreak(b.maxSpeedKmh.compareTo(a.maxSpeedKmh), a, b));
    case RideSort.longestDuration:
      out.sort((a, b) => withDateTieBreak(
          b.totalDuration.compareTo(a.totalDuration), a, b));
  }
  return out;
}

/// Aggregate numbers shown in the summary header. Always reflects the rides
/// passed in (i.e. the *filtered* set, so the header tracks the active filter).
class RideSummary {
  const RideSummary({
    required this.count,
    required this.totalDistanceKm,
    required this.totalDuration,
    required this.totalMovingDuration,
    required this.longestRideKm,
    required this.topSpeedKmh,
    required this.avgSpeedKmh,
  });

  final int count;
  final double totalDistanceKm;
  final Duration totalDuration;
  final Duration totalMovingDuration;
  final double longestRideKm;
  final double topSpeedKmh;

  /// Distance-weighted-ish overall average: total distance over total moving
  /// time. Falls back to 0 when nothing is moving.
  final double avgSpeedKmh;

  static const empty = RideSummary(
    count: 0,
    totalDistanceKm: 0,
    totalDuration: Duration.zero,
    totalMovingDuration: Duration.zero,
    longestRideKm: 0,
    topSpeedKmh: 0,
    avgSpeedKmh: 0,
  );

  bool get isEmpty => count == 0;
}

/// Compute the [RideSummary] over an already-filtered list. Pure.
RideSummary rideSummary(List<Ride> rides) {
  if (rides.isEmpty) return RideSummary.empty;

  var totalKm = 0.0;
  var total = Duration.zero;
  var moving = Duration.zero;
  var longest = 0.0;
  var topSpeed = 0.0;

  for (final r in rides) {
    totalKm += r.distanceKm;
    total += r.totalDuration;
    moving += r.movingDuration;
    if (r.distanceKm > longest) longest = r.distanceKm;
    if (r.maxSpeedKmh > topSpeed) topSpeed = r.maxSpeedKmh;
  }

  final movingHours = moving.inMilliseconds / 3_600_000.0;
  final avg = movingHours > 0 ? totalKm / movingHours : 0.0;

  return RideSummary(
    count: rides.length,
    totalDistanceKm: totalKm,
    totalDuration: total,
    totalMovingDuration: moving,
    longestRideKm: longest,
    topSpeedKmh: topSpeed,
    avgSpeedKmh: avg,
  );
}

/// Which ride metric the per-row colour cue maps onto the green→red scale.
enum RideColorMetric { avgSpeed, maxSpeed, distance }

extension RideColorMetricLabel on RideColorMetric {
  String get label => switch (this) {
        RideColorMetric.avgSpeed => 'Ø Tempo',
        RideColorMetric.maxSpeed => 'Max Tempo',
        RideColorMetric.distance => 'Distanz',
      };

  double value(Ride r) => switch (this) {
        RideColorMetric.avgSpeed => r.avgMovingSpeedKmh,
        RideColorMetric.maxSpeed => r.maxSpeedKmh,
        RideColorMetric.distance => r.distanceKm,
      };
}

/// Min/max of [metric] across [rides], used to normalise the colour cue. Both
/// values are equal when the list is empty or every ride shares one value (the
/// UI treats a zero spread as "everything mid-scale").
class MetricRange {
  const MetricRange(this.min, this.max);
  final double min;
  final double max;

  bool get hasSpread => max > min;

  /// Position of [v] within [min, max], clamped to 0..1. Returns 0.5 when there
  /// is no spread so a single-value (or single-ride) list paints neutrally
  /// rather than slamming to one end of the scale.
  double normalize(double v) {
    if (!hasSpread) return 0.5;
    final t = (v - min) / (max - min);
    return t < 0
        ? 0
        : t > 1
            ? 1
            : t;
  }
}

/// Compute the [MetricRange] of [metric] over [rides] for the colour scale.
MetricRange metricRange(List<Ride> rides, RideColorMetric metric) {
  if (rides.isEmpty) return const MetricRange(0, 0);
  var min = metric.value(rides.first);
  var max = min;
  for (final r in rides) {
    final v = metric.value(r);
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return MetricRange(min, max);
}

const Object _sentinel = Object();
