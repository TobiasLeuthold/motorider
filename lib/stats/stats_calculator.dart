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
}
