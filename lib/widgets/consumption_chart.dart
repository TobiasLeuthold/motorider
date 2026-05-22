import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../stats/stats_calculator.dart';
import '../theme.dart';

class ConsumptionChart extends StatelessWidget {
  const ConsumptionChart({
    super.key,
    required this.points,
    required this.metric,
  });

  final List<ConsumptionPoint> points;
  final ChartMetric metric;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            'Zu wenig Daten für Diagramm',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    final values = points.map(metric.extract).toList();
    final minY = (values.reduce((a, b) => a < b ? a : b) * 0.9);
    final maxY = (values.reduce((a, b) => a > b ? a : b) * 1.1);

    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), values[i]),
    ];

    return SizedBox(
      height: 220,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, right: 16, bottom: 8),
        child: LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
            backgroundColor: Colors.transparent,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: ((maxY - minY) / 4).clamp(0.5, double.infinity),
              getDrawingHorizontalLine: (_) => FlLine(
                color: AppColors.gridLine,
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36,
                  interval: ((maxY - minY) / 4).clamp(0.5, double.infinity),
                  getTitlesWidget: (v, _) => Text(
                    metric.formatAxis(v),
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                ),
              ),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: (points.length / 5).ceilToDouble().clamp(1, double.infinity),
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= points.length) return const SizedBox.shrink();
                    final d = points[i].date;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        DateFormat('dd.MM').format(d),
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => AppColors.surface.withValues(alpha: 0.92),
                getTooltipItems: (spots) => spots.map((s) {
                  final p = points[s.x.toInt()];
                  return LineTooltipItem(
                    '${metric.formatTooltip(metric.extract(p))}\n${DateFormat('dd.MM.yyyy').format(p.date)}',
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  );
                }).toList(),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.25,
                color: AppColors.accent,
                barWidth: 3,
                isStrokeCapRound: true,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                    radius: 4,
                    color: AppColors.accent,
                    strokeWidth: 2,
                    strokeColor: AppColors.bg,
                  ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.accent.withValues(alpha: 0.30),
                      AppColors.accent.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum ChartMetric { lPer100Km, chfPerLiter }

extension ChartMetricX on ChartMetric {
  double extract(ConsumptionPoint p) {
    switch (this) {
      case ChartMetric.lPer100Km:
        return p.lPer100Km;
      case ChartMetric.chfPerLiter:
        return p.chfPerLiter;
    }
  }

  String formatAxis(double v) {
    switch (this) {
      case ChartMetric.lPer100Km:
        return v.toStringAsFixed(1);
      case ChartMetric.chfPerLiter:
        return v.toStringAsFixed(2);
    }
  }

  String formatTooltip(double v) {
    switch (this) {
      case ChartMetric.lPer100Km:
        return '${v.toStringAsFixed(2)} L/100 km';
      case ChartMetric.chfPerLiter:
        return 'CHF ${v.toStringAsFixed(2)} / L';
    }
  }

  String get title {
    switch (this) {
      case ChartMetric.lPer100Km:
        return 'Verbrauch';
      case ChartMetric.chfPerLiter:
        return 'Spritpreis';
    }
  }

  String get subtitle {
    switch (this) {
      case ChartMetric.lPer100Km:
        return 'L/100 km pro Tankfüllung';
      case ChartMetric.chfPerLiter:
        return 'CHF pro Liter';
    }
  }
}
