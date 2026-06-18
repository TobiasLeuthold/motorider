import '../models/fillup.dart';

class Stats {
  const Stats({
    required this.fillUpCount,
    required this.currentOdometerKm,
    required this.trackedKm,
    required this.totalLiters,
    required this.totalChf,
    required this.avgChfPerKm,
    required this.avgLPer100Km,
    required this.lastFillDate,
    required this.firstFillDate,
  });

  final int fillUpCount;
  final int currentOdometerKm;
  final int trackedKm;
  final double totalLiters;
  final double totalChf;
  final double? avgChfPerKm;
  final double? avgLPer100Km;
  final DateTime? lastFillDate;
  final DateTime? firstFillDate;

  static const empty = Stats(
    fillUpCount: 0,
    currentOdometerKm: 0,
    trackedKm: 0,
    totalLiters: 0,
    totalChf: 0,
    avgChfPerKm: null,
    avgLPer100Km: null,
    lastFillDate: null,
    firstFillDate: null,
  );
}

class ConsumptionPoint {
  const ConsumptionPoint({
    required this.date,
    required this.odometerKm,
    required this.lPer100Km,
    required this.chfPerLiter,
  });

  final DateTime date;
  final int odometerKm;
  final double lPer100Km;
  final double chfPerLiter;
}

/// Time granularity for the period breakdown on the overview tab.
enum PeriodGranularity { week, month, year }

/// Aggregated riding distance and fuel spend for a single calendar period
/// (one ISO week, one month, or one year).
class PeriodSummary {
  const PeriodSummary({
    required this.start,
    required this.granularity,
    required this.km,
    required this.chf,
    required this.liters,
  });

  /// Inclusive start of the period (Monday for weeks, the 1st for months,
  /// Jan 1st for years). Used as the bucket key and for sorting/labelling.
  final DateTime start;
  final PeriodGranularity granularity;

  /// Kilometres ridden whose ending fill-up falls in this period.
  final int km;

  /// Money spent on fuel in this period (all fill-ups, baseline included).
  final double chf;

  /// Litres tanked in this period.
  final double liters;
}

/// A calendar period next to the one immediately before it, for the overview's
/// "this month / this year" headline. An empty period is reported as all-zero;
/// the percentage deltas are null when the previous period had nothing to
/// compare against (so the UI can show "neu" instead of a bogus ∞%).
class PeriodComparison {
  const PeriodComparison({required this.current, required this.previous});

  final PeriodSummary current;
  final PeriodSummary previous;

  double? _pct(num now, num before) =>
      before == 0 ? null : (now - before) / before * 100;

  double? get kmDeltaPct => _pct(current.km, previous.km);
  double? get chfDeltaPct => _pct(current.chf, previous.chf);
  double? get litersDeltaPct => _pct(current.liters, previous.liters);
}

/// Fuel-price summary across every real fill-up (litres > 0), for the overview
/// price card. [avgPricePerLiter] is litre-weighted — i.e. what was actually
/// paid per litre on average, not the mean of the per-fill prices.
class FuelInsights {
  const FuelInsights({
    required this.fillCount,
    required this.avgPricePerLiter,
    required this.cheapest,
    required this.priciest,
    required this.last,
  });

  final int fillCount;
  final double avgPricePerLiter;
  final FillUp? cheapest;
  final FillUp? priciest;
  final FillUp? last;

  bool get hasData => fillCount > 0;

  /// Latest fill's price minus the running average (negative = below average).
  double? get lastVsAvg =>
      last == null ? null : last!.pricePerLiter - avgPricePerLiter;

  static const empty = FuelInsights(
    fillCount: 0,
    avgPricePerLiter: 0,
    cheapest: null,
    priciest: null,
    last: null,
  );
}

/// Pure stats calculator over a list of fill-ups sorted by odometer ASC.
class StatsCalculator {
  static Stats computeStats(List<FillUp> fillups) {
    if (fillups.isEmpty) return Stats.empty;
    final sorted = [...fillups]..sort((a, b) => a.odometerKm.compareTo(b.odometerKm));
    final first = sorted.first;
    final last = sorted.last;
    final tracked = last.odometerKm - first.odometerKm;

    // Liters & CHF: count fuel bought AFTER the baseline entry,
    // i.e. the fuel that powered the tracked km.
    double totalLiters = 0;
    double totalChf = 0;
    for (var i = 1; i < sorted.length; i++) {
      totalLiters += sorted[i].liters;
      totalChf += sorted[i].totalChf;
    }

    return Stats(
      fillUpCount: sorted.length,
      currentOdometerKm: last.odometerKm,
      trackedKm: tracked,
      totalLiters: totalLiters,
      totalChf: totalChf,
      avgChfPerKm: tracked > 0 ? totalChf / tracked : null,
      avgLPer100Km: tracked > 0 ? (totalLiters / tracked) * 100 : null,
      lastFillDate: sorted.map((f) => f.date).reduce((a, b) => a.isAfter(b) ? a : b),
      firstFillDate: sorted.map((f) => f.date).reduce((a, b) => a.isBefore(b) ? a : b),
    );
  }

  /// Per-fill consumption (L/100km) computed full-tank to full-tank.
  /// Returns one point per non-baseline fill where both endpoints are full.
  static List<ConsumptionPoint> consumptionSeries(List<FillUp> fillups) {
    if (fillups.length < 2) return const [];
    final sorted = [...fillups]..sort((a, b) => a.odometerKm.compareTo(b.odometerKm));
    final out = <ConsumptionPoint>[];
    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1];
      final cur = sorted[i];
      if (!prev.fullTank || !cur.fullTank) continue;
      final km = cur.odometerKm - prev.odometerKm;
      if (km <= 0) continue;
      out.add(ConsumptionPoint(
        date: cur.date,
        odometerKm: cur.odometerKm,
        lPer100Km: (cur.liters / km) * 100,
        chfPerLiter: cur.pricePerLiter,
      ));
    }
    return out;
  }

  /// Buckets fill-ups into calendar periods, summing kilometres ridden and
  /// money/litres spent in each. Returns periods sorted by start ascending.
  ///
  /// Kilometres are attributed to the period of the *later* fill-up in each
  /// consecutive odometer pair (i.e. the distance is booked when it's logged).
  /// Spend and litres are attributed to the period each fill-up was bought in,
  /// including the very first ("baseline") fill — it's real money spent.
  static List<PeriodSummary> periodSummaries(
    List<FillUp> fillups,
    PeriodGranularity granularity,
  ) {
    if (fillups.isEmpty) return const [];

    final km = <DateTime, int>{};
    final chf = <DateTime, double>{};
    final liters = <DateTime, double>{};

    DateTime keyFor(DateTime d) => periodStart(d, granularity);

    // Spend + litres: every fill-up counts toward its own purchase period.
    for (final f in fillups) {
      final k = keyFor(f.date);
      chf[k] = (chf[k] ?? 0) + f.totalChf;
      liters[k] = (liters[k] ?? 0) + f.liters;
      km.putIfAbsent(k, () => 0);
    }

    // Distance: delta between consecutive odometer readings, booked to the
    // period of the reading that closes the interval.
    final sorted = [...fillups]..sort((a, b) => a.odometerKm.compareTo(b.odometerKm));
    for (var i = 1; i < sorted.length; i++) {
      final delta = sorted[i].odometerKm - sorted[i - 1].odometerKm;
      if (delta <= 0) continue;
      final k = keyFor(sorted[i].date);
      km[k] = (km[k] ?? 0) + delta;
    }

    final keys = chf.keys.toList()..sort();
    return [
      for (final k in keys)
        PeriodSummary(
          start: k,
          granularity: granularity,
          km: km[k] ?? 0,
          chf: chf[k] ?? 0,
          liters: liters[k] ?? 0,
        ),
    ];
  }

  /// Inclusive start of the calendar period that [d] falls into.
  static DateTime periodStart(DateTime d, PeriodGranularity g) {
    switch (g) {
      case PeriodGranularity.week:
        final monday = d.subtract(Duration(days: d.weekday - 1));
        return DateTime(monday.year, monday.month, monday.day);
      case PeriodGranularity.month:
        return DateTime(d.year, d.month);
      case PeriodGranularity.year:
        return DateTime(d.year);
    }
  }

  /// Inclusive start of the period immediately *before* the one [d] falls in.
  static DateTime previousPeriodStart(DateTime d, PeriodGranularity g) {
    final start = periodStart(d, g);
    switch (g) {
      case PeriodGranularity.week:
        return start.subtract(const Duration(days: 7));
      case PeriodGranularity.month:
        // DateTime(y, 0) normalises to December of the previous year.
        return DateTime(start.year, start.month - 1);
      case PeriodGranularity.year:
        return DateTime(start.year - 1);
    }
  }

  /// The period containing [now] next to the one before it, at [granularity].
  /// Periods with no fill-ups come back as all-zero summaries.
  static PeriodComparison currentVsPrevious(
    List<FillUp> fillups,
    PeriodGranularity granularity, {
    required DateTime now,
  }) {
    final byStart = {
      for (final s in periodSummaries(fillups, granularity)) s.start: s,
    };
    PeriodSummary at(DateTime key) =>
        byStart[key] ??
        PeriodSummary(
            start: key, granularity: granularity, km: 0, chf: 0, liters: 0);
    return PeriodComparison(
      current: at(periodStart(now, granularity)),
      previous: at(previousPeriodStart(now, granularity)),
    );
  }

  /// Litre-weighted average price, plus the cheapest / priciest / latest fills.
  static FuelInsights computeFuelInsights(List<FillUp> fillups) {
    final fills = fillups.where((f) => f.liters > 0).toList();
    if (fills.isEmpty) return FuelInsights.empty;
    var totalChf = 0.0;
    var totalLiters = 0.0;
    var cheapest = fills.first;
    var priciest = fills.first;
    var last = fills.first;
    for (final f in fills) {
      totalChf += f.totalChf;
      totalLiters += f.liters;
      if (f.pricePerLiter < cheapest.pricePerLiter) cheapest = f;
      if (f.pricePerLiter > priciest.pricePerLiter) priciest = f;
      if (f.date.isAfter(last.date)) last = f;
    }
    return FuelInsights(
      fillCount: fills.length,
      avgPricePerLiter: totalLiters > 0 ? totalChf / totalLiters : 0,
      cheapest: cheapest,
      priciest: priciest,
      last: last,
    );
  }

  /// ISO-8601 week number (1–53) for [date].
  static int isoWeek(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    // Thursday of the current week decides which year/week the date belongs to.
    final thursday = d.add(Duration(days: 4 - d.weekday));
    final firstThursday = DateTime(thursday.year, 1, 1);
    final diffDays = thursday.difference(firstThursday).inDays;
    return 1 + (diffDays ~/ 7);
  }
}
