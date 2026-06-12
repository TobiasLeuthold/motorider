import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../stats/ride_detail_stats.dart';
import '../theme.dart';

/// Speed-over-time line chart for the ride detail screen.
class RideSpeedChart extends StatelessWidget {
  const RideSpeedChart({
    super.key,
    required this.series,
    required this.avgKmh,
  });

  final List<SpeedSample> series;
  final double avgKmh;

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();

    var peak = 0.0;
    for (final s in series) {
      if (s.kmh > peak) peak = s.kmh;
    }
    final maxY = ((peak / 20).ceil() * 20).toDouble().clamp(20, 300).toDouble();
    final totalSec = series.last.elapsedSec;

    return SizedBox(
      height: 190,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, right: 8),
        child: LineChart(
          LineChartData(
            minY: 0,
            maxY: maxY,
            minX: 0,
            maxX: totalSec,
            backgroundColor: Colors.transparent,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: maxY / 4,
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
                  reservedSize: 34,
                  interval: maxY / 4,
                  getTitlesWidget: (v, _) => Text(
                    v.toStringAsFixed(0),
                    style:
                        const TextStyle(color: AppColors.textMuted, fontSize: 10),
                  ),
                ),
              ),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: _timeInterval(totalSec),
                  getTitlesWidget: (v, meta) {
                    if (v <= 0 || v >= totalSec) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        formatElapsedAxis(v),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => AppColors.surfaceHi.withValues(alpha: 0.95),
                getTooltipItems: (spots) => spots
                    .map((s) => LineTooltipItem(
                          '${s.y.toStringAsFixed(0)} km/h\n${formatElapsedAxis(s.x)}',
                          const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ))
                    .toList(),
              ),
            ),
            extraLinesData: ExtraLinesData(
              horizontalLines: [
                HorizontalLine(
                  y: avgKmh,
                  color: AppColors.accentSoft.withValues(alpha: 0.7),
                  strokeWidth: 1,
                  dashArray: [6, 4],
                ),
              ],
            ),
            lineBarsData: [
              LineChartBarData(
                spots: [
                  for (final s in series) FlSpot(s.elapsedSec, s.kmh),
                ],
                isCurved: false,
                color: AppColors.accent,
                barWidth: 2,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.accent.withValues(alpha: 0.25),
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

/// Elevation-over-distance profile for the ride detail screen.
class RideElevationChart extends StatelessWidget {
  const RideElevationChart({super.key, required this.series});

  final List<ElevationSample> series;

  static const _color = Color(0xFF4DA3FF);

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();

    var minY = series.first.altitudeM;
    var maxY = minY;
    for (final s in series) {
      if (s.altitudeM < minY) minY = s.altitudeM;
      if (s.altitudeM > maxY) maxY = s.altitudeM;
    }
    final pad = ((maxY - minY) * 0.15).clamp(10.0, 200.0);
    minY -= pad;
    maxY += pad;
    final totalKm = series.last.distanceKm;
    if (totalKm <= 0) return const SizedBox.shrink();

    return SizedBox(
      height: 160,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, right: 8),
        child: LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
            minX: 0,
            maxX: totalKm,
            backgroundColor: Colors.transparent,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: (maxY - minY) / 4,
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
                  reservedSize: 40,
                  interval: (maxY - minY) / 4,
                  getTitlesWidget: (v, _) => Text(
                    '${v.toStringAsFixed(0)}m',
                    style:
                        const TextStyle(color: AppColors.textMuted, fontSize: 10),
                  ),
                ),
              ),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: (totalKm / 4).clamp(0.1, double.infinity),
                  getTitlesWidget: (v, _) {
                    if (v <= 0 || v >= totalKm) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${v.toStringAsFixed(v < 10 ? 1 : 0)} km',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => AppColors.surfaceHi.withValues(alpha: 0.95),
                getTooltipItems: (spots) => spots
                    .map((s) => LineTooltipItem(
                          '${s.y.toStringAsFixed(0)} m ü. M.\nkm ${s.x.toStringAsFixed(1)}',
                          const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ))
                    .toList(),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: [
                  for (final s in series) FlSpot(s.distanceKm, s.altitudeM),
                ],
                isCurved: false,
                color: _color,
                barWidth: 2,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _color.withValues(alpha: 0.25),
                      _color.withValues(alpha: 0.0),
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

/// Stacked horizontal bar showing the share of moving time per speed band.
class SpeedBandBar extends StatelessWidget {
  const SpeedBandBar({super.key, required this.bands});

  final List<SpeedBand> bands;

  static const _colors = [
    Color(0xFF4DA3FF),
    Color(0xFF3DDC84),
    Color(0xFFFFD54D),
    Color(0xFFFF5A6A),
  ];

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (var i = 0; i < bands.length; i++)
        if (bands[i].fraction > 0.005) (bands[i], _colors[i % _colors.length]),
    ];
    if (visible.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (final (band, color) in visible)
                  Expanded(
                    flex: (band.fraction * 1000).round().clamp(1, 1000),
                    child: ColoredBox(color: color),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final (band, color) in visible)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${band.label} km/h · ${(band.fraction * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Nice round x-axis interval (seconds) aiming for ~4-5 labels.
double _timeInterval(double totalSec) {
  const steps = <double>[60, 120, 300, 600, 900, 1800, 3600, 7200];
  for (final s in steps) {
    if (totalSec / s <= 5) return s;
  }
  return 14400.0;
}

/// "1:05" for >= 1 h, "12'" below.
String formatElapsedAxis(double sec) {
  final m = (sec / 60).round();
  if (m >= 60) return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
  return "$m'";
}
