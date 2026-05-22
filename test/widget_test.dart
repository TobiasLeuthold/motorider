import 'package:flutter_test/flutter_test.dart';

import 'package:motorider/models/fillup.dart';
import 'package:motorider/stats/stats_calculator.dart';

void main() {
  test('empty list yields empty stats', () {
    final s = StatsCalculator.computeStats(const []);
    expect(s.fillUpCount, 0);
    expect(s.trackedKm, 0);
  });

  test('two fill-ups: tracked km and L/100km computed correctly', () {
    final base = DateTime(2026, 4, 1, 9);
    final fillups = [
      FillUp(date: base, odometerKm: 1000, liters: 10, totalChf: 20),
      FillUp(date: base.add(const Duration(days: 7)), odometerKm: 1500, liters: 25, totalChf: 50),
    ];
    final stats = StatsCalculator.computeStats(fillups);
    expect(stats.trackedKm, 500);
    expect(stats.totalLiters, 25);
    expect(stats.totalChf, 50);
    expect(stats.avgLPer100Km, closeTo(5.0, 0.001));
    expect(stats.avgChfPerKm, closeTo(0.10, 0.001));
  });

  test('consumption series uses full-tank-to-full-tank windows', () {
    final base = DateTime(2026, 4, 1, 9);
    final series = StatsCalculator.consumptionSeries([
      FillUp(date: base, odometerKm: 1000, liters: 10, totalChf: 20),
      FillUp(date: base.add(const Duration(days: 3)), odometerKm: 1300, liters: 15, totalChf: 30),
    ]);
    expect(series.length, 1);
    expect(series.first.lPer100Km, closeTo(5.0, 0.001));
    expect(series.first.chfPerLiter, closeTo(2.0, 0.001));
  });
}
