import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/models/fillup.dart';
import 'package:motorider/stats/stats_calculator.dart';

FillUp _fill({
  required DateTime date,
  required int odo,
  double liters = 10,
  double chf = 18,
}) =>
    FillUp(date: date, odometerKm: odo, liters: liters, totalChf: chf);

void main() {
  group('previousPeriodStart', () {
    test('month steps back one month, rolling over the year', () {
      expect(
        StatsCalculator.previousPeriodStart(
            DateTime(2026, 1, 15), PeriodGranularity.month),
        DateTime(2025, 12),
      );
      expect(
        StatsCalculator.previousPeriodStart(
            DateTime(2026, 6, 30), PeriodGranularity.month),
        DateTime(2026, 5),
      );
    });

    test('year steps back one year', () {
      expect(
        StatsCalculator.previousPeriodStart(
            DateTime(2026, 6, 1), PeriodGranularity.year),
        DateTime(2025),
      );
    });

    test('week steps back to the previous Monday', () {
      // 2026-06-17 is a Wednesday; its week starts Mon 2026-06-15, the previous
      // week starts Mon 2026-06-08.
      expect(
        StatsCalculator.previousPeriodStart(
            DateTime(2026, 6, 17), PeriodGranularity.week),
        DateTime(2026, 6, 8),
      );
    });
  });

  group('currentVsPrevious (month)', () {
    final fills = [
      _fill(date: DateTime(2026, 4, 1), odo: 900, liters: 9, chf: 16), // baseline
      _fill(date: DateTime(2026, 5, 10), odo: 1100, liters: 10, chf: 18), // May
      _fill(date: DateTime(2026, 6, 12), odo: 1400, liters: 15, chf: 27), // June
    ];

    test('books spend, litres and km into the right months', () {
      final cmp = StatsCalculator.currentVsPrevious(
        fills,
        PeriodGranularity.month,
        now: DateTime(2026, 6, 15),
      );
      expect(cmp.current.chf, 27);
      expect(cmp.current.km, 300); // 1400 - 1100
      expect(cmp.current.liters, 15);
      expect(cmp.previous.chf, 18);
      expect(cmp.previous.km, 200); // 1100 - 900
      expect(cmp.chfDeltaPct, closeTo(50, 1e-9)); // (27-18)/18
      expect(cmp.kmDeltaPct, closeTo(50, 1e-9)); // (300-200)/200
    });

    test('an empty previous month yields null deltas (UI shows "neu")', () {
      final sparse = [
        _fill(date: DateTime(2026, 4, 1), odo: 900, liters: 9, chf: 16),
        _fill(date: DateTime(2026, 6, 12), odo: 1400, liters: 15, chf: 27),
      ];
      final cmp = StatsCalculator.currentVsPrevious(
        sparse,
        PeriodGranularity.month,
        now: DateTime(2026, 6, 15),
      );
      expect(cmp.current.km, 500); // 1400 - 900, booked to June
      expect(cmp.previous.chf, 0);
      expect(cmp.chfDeltaPct, isNull);
      expect(cmp.kmDeltaPct, isNull);
    });
  });

  group('computeFuelInsights', () {
    test('litre-weighted average, cheapest, priciest and latest', () {
      final fills = [
        _fill(date: DateTime(2026, 1, 1), odo: 100, liters: 10, chf: 20), // 2.00
        _fill(date: DateTime(2026, 2, 1), odo: 300, liters: 20, chf: 30), // 1.50
        _fill(date: DateTime(2026, 3, 1), odo: 500, liters: 10, chf: 25), // 2.50
      ];
      final i = StatsCalculator.computeFuelInsights(fills);
      expect(i.fillCount, 3);
      // (20 + 30 + 25) / (10 + 20 + 10) = 75 / 40 = 1.875
      expect(i.avgPricePerLiter, closeTo(1.875, 1e-9));
      expect(i.cheapest!.pricePerLiter, closeTo(1.5, 1e-9));
      expect(i.priciest!.pricePerLiter, closeTo(2.5, 1e-9));
      expect(i.last!.date, DateTime(2026, 3, 1));
      expect(i.lastVsAvg, closeTo(2.5 - 1.875, 1e-9));
    });

    test('empty list reports no data', () {
      final i = StatsCalculator.computeFuelInsights(const []);
      expect(i.hasData, isFalse);
      expect(i.cheapest, isNull);
      expect(i.lastVsAvg, isNull);
    });

    test('rows without litres are ignored', () {
      final fills = [
        _fill(date: DateTime(2026, 1, 1), odo: 100, liters: 0, chf: 0),
        _fill(date: DateTime(2026, 2, 1), odo: 300, liters: 10, chf: 19),
      ];
      final i = StatsCalculator.computeFuelInsights(fills);
      expect(i.fillCount, 1);
      expect(i.avgPricePerLiter, closeTo(1.9, 1e-9));
    });
  });
}
