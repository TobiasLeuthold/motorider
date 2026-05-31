import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/fillup.dart';
import '../stats/stats_calculator.dart';
import '../theme.dart';

/// Overview-tab section that breaks riding distance and fuel spend down by
/// calendar period. The user picks the granularity (week / month / year) and
/// whether the bar chart plots kilometres or money; both numbers are always
/// shown in the per-period list below.
class PeriodBreakdown extends StatefulWidget {
  const PeriodBreakdown({super.key, required this.fillups});

  final List<FillUp> fillups;

  @override
  State<PeriodBreakdown> createState() => _PeriodBreakdownState();
}

enum _Metric { km, chf }

class _PeriodBreakdownState extends State<PeriodBreakdown> {
  PeriodGranularity _granularity = PeriodGranularity.month;
  _Metric _metric = _Metric.km;

  static const _maxBars = 12;

  final _chf = NumberFormat.currency(
    locale: 'de_CH',
    symbol: 'CHF',
    decimalDigits: 2,
    customPattern: '¤ #,##0.00',
  );
  final _decimal = NumberFormat.decimalPattern('de_CH');

  @override
  Widget build(BuildContext context) {
    final all = StatsCalculator.periodSummaries(widget.fillups, _granularity);
    // Show only the most recent window so the chart stays readable; the list
    // mirrors the same window, newest first.
    final window = all.length > _maxBars ? all.sublist(all.length - _maxBars) : all;

    final avgKm = window.isEmpty
        ? 0
        : window.map((s) => s.km).reduce((a, b) => a + b) / window.length;
    final avgChf = window.isEmpty
        ? 0.0
        : window.map((s) => s.chf).reduce((a, b) => a + b) / window.length;

    final unit = _granularityNoun(_granularity);
    final avgText = _metric == _Metric.km
        ? 'Ø ${_decimal.format(avgKm.round())} km / $unit'
        : 'Ø ${_chf.format(avgChf)} / $unit';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Fahrleistung & Kosten',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            window.isEmpty ? 'Noch keine Daten' : avgText,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(height: 14),
          _SegToggle<PeriodGranularity>(
            value: _granularity,
            options: const [
              (PeriodGranularity.week, 'Woche'),
              (PeriodGranularity.month, 'Monat'),
              (PeriodGranularity.year, 'Jahr'),
            ],
            onChanged: (g) => setState(() => _granularity = g),
          ),
          const SizedBox(height: 8),
          _SegToggle<_Metric>(
            value: _metric,
            options: const [
              (_Metric.km, 'Kilometer'),
              (_Metric.chf, 'Kosten'),
            ],
            onChanged: (m) => setState(() => _metric = m),
          ),
          const SizedBox(height: 16),
          if (window.isEmpty)
            const SizedBox(
              height: 180,
              child: Center(
                child: Text(
                  'Zu wenig Daten',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
            )
          else ...[
            SizedBox(height: 200, child: _buildChart(window)),
            const SizedBox(height: 8),
            ...window.reversed.map(_buildRow),
          ],
        ],
      ),
    );
  }

  Widget _buildChart(List<PeriodSummary> window) {
    double valueOf(PeriodSummary s) =>
        _metric == _Metric.km ? s.km.toDouble() : s.chf;

    final maxVal = window.map(valueOf).fold<double>(0, (a, b) => a > b ? a : b);
    final maxY = maxVal <= 0 ? 1.0 : maxVal * 1.2;
    final step = (window.length / 6).ceil().clamp(1, window.length);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY,
        minY: 0,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.gridLine, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              interval: maxY / 4,
              getTitlesWidget: (v, _) => Text(
                _axisLabel(v),
                style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= window.length) return const SizedBox.shrink();
                // Always show the last bar, then thin the rest out.
                if (i != window.length - 1 && i % step != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _shortLabel(window[i]),
                    style:
                        const TextStyle(color: AppColors.textMuted, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppColors.surfaceHi,
            getTooltipItem: (group, _, rod, _) {
              final s = window[group.x];
              final value = _metric == _Metric.km
                  ? '${_decimal.format(s.km)} km'
                  : _chf.format(s.chf);
              return BarTooltipItem(
                '${_longLabel(s)}\n',
                const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                children: [
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < window.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: valueOf(window[i]),
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(5),
                  ),
                  gradient: const LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [AppColors.accent, AppColors.accentSoft],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRow(PeriodSummary s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _longLabel(s),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${_decimal.format(s.liters.round())} L getankt',
                  style:
                      const TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            '${_decimal.format(s.km)} km',
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 90,
            child: Text(
              _chf.format(s.chf),
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _axisLabel(double v) {
    if (_metric == _Metric.km) {
      if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
      return v.round().toString();
    }
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v.round().toString();
  }

  String _granularityNoun(PeriodGranularity g) {
    switch (g) {
      case PeriodGranularity.week:
        return 'Woche';
      case PeriodGranularity.month:
        return 'Monat';
      case PeriodGranularity.year:
        return 'Jahr';
    }
  }

  String _shortLabel(PeriodSummary s) {
    switch (s.granularity) {
      case PeriodGranularity.week:
        return 'KW${StatsCalculator.isoWeek(s.start)}';
      case PeriodGranularity.month:
        return DateFormat('MMM', 'de').format(s.start);
      case PeriodGranularity.year:
        return DateFormat('yyyy').format(s.start);
    }
  }

  String _longLabel(PeriodSummary s) {
    switch (s.granularity) {
      case PeriodGranularity.week:
        final end = s.start.add(const Duration(days: 6));
        return 'KW ${StatsCalculator.isoWeek(s.start)} · '
            '${DateFormat('dd.MM.').format(s.start)}–${DateFormat('dd.MM.').format(end)}';
      case PeriodGranularity.month:
        return DateFormat('MMMM yyyy', 'de').format(s.start);
      case PeriodGranularity.year:
        return DateFormat('yyyy').format(s.start);
    }
  }
}

/// Compact pill-style segmented toggle matching the app's dark theme.
class _SegToggle<T> extends StatelessWidget {
  const _SegToggle({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.8)),
      ),
      child: Row(
        children: [
          for (final (key, label) in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: key == value ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: key == value ? Colors.black : AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
