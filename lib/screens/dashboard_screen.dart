import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../stats/stats_calculator.dart';
import '../theme.dart';
import '../widgets/consumption_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/stat_card.dart';
import 'add_fillup_screen.dart';
import 'home_shell.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, this.stream});

  /// Optional stream override for testing. Defaults to the global repo.
  final Stream<List<FillUp>>? stream;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final chf = NumberFormat.currency(
      locale: 'de_CH',
      symbol: 'CHF',
      decimalDigits: 2,
      customPattern: '¤ #,##0.00',
    );

    return Scaffold(
      body: StreamBuilder<List<FillUp>>(
        stream: stream ?? fillUpRepo.watchAll(),
        builder: (context, snap) {
          final fillups = snap.data ?? const <FillUp>[];
          final stats = StatsCalculator.computeStats(fillups);
          final series = StatsCalculator.consumptionSeries(fillups);

          if (fillups.isEmpty) {
            return const Column(
              children: [
                TabHeader(
                  title: 'Übersicht',
                  subtitle: 'Honda CB 750 Hornet',
                ),
                Expanded(
                  child: EmptyState(
                    illustrationAsset: 'assets/illustrations/no_fillups.svg',
                    title: 'Bereit für die erste Ausfahrt?',
                    subtitle:
                        'Tippe auf + um deine erste Tankfüllung einzutragen — Verbrauch und Kosten werden automatisch berechnet.',
                  ),
                ),
              ],
            );
          }

          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: TabHeader(
                  title: 'Übersicht',
                  subtitle: 'Honda CB 750 Hornet',
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 124,
                  ),
                  delegate: SliverChildListDelegate.fixed([
                    StatCard(
                      icon: Icons.speed_rounded,
                      label: 'Kilometerstand',
                      value: '${NumberFormat.decimalPattern('de_CH').format(stats.currentOdometerKm)} km',
                      sub: stats.trackedKm > 0
                          ? '+${NumberFormat.decimalPattern('de_CH').format(stats.trackedKm)} km erfasst'
                          : 'Basis-Eintrag',
                    ),
                    StatCard(
                      icon: Icons.local_fire_department_rounded,
                      label: 'Ø Verbrauch',
                      value: stats.avgLPer100Km != null
                          ? '${stats.avgLPer100Km!.toStringAsFixed(2)} L'
                          : '–',
                      sub: stats.avgLPer100Km != null ? 'pro 100 km' : 'noch keine Daten',
                      tint: AppColors.accentSoft,
                    ),
                    StatCard(
                      icon: Icons.payments_rounded,
                      label: 'Total ausgegeben',
                      value: chf.format(stats.totalChf),
                      sub: stats.firstFillDate != null
                          ? 'seit ${dateFmt.format(stats.firstFillDate!)}'
                          : null,
                    ),
                    StatCard(
                      icon: Icons.route_rounded,
                      label: 'Ø Kosten/km',
                      value: stats.avgChfPerKm != null
                          ? 'CHF ${stats.avgChfPerKm!.toStringAsFixed(3)}'
                          : '–',
                      sub: stats.avgChfPerKm != null ? 'inkl. Spritkosten' : null,
                      tint: AppColors.accentSoft,
                    ),
                    StatCard(
                      icon: Icons.water_drop_rounded,
                      label: 'Getankt total',
                      value: '${stats.totalLiters.toStringAsFixed(1)} L',
                      sub: '${stats.fillUpCount} Tankfüllungen',
                    ),
                    StatCard(
                      icon: Icons.event_rounded,
                      label: 'Letzte Tankung',
                      value: stats.lastFillDate != null
                          ? dateFmt.format(stats.lastFillDate!)
                          : '–',
                      sub: stats.lastFillDate != null
                          ? _relativeDate(stats.lastFillDate!)
                          : null,
                      tint: AppColors.accentSoft,
                    ),
                  ]),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverList.list(children: [
                  _ChartSection(
                    title: ChartMetric.lPer100Km.title,
                    subtitle: ChartMetric.lPer100Km.subtitle,
                    chart: ConsumptionChart(points: series, metric: ChartMetric.lPer100Km),
                  ),
                  const SizedBox(height: 16),
                  _ChartSection(
                    title: ChartMetric.chfPerLiter.title,
                    subtitle: ChartMetric.chfPerLiter.subtitle,
                    chart: ConsumptionChart(points: series, metric: ChartMetric.chfPerLiter),
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-add-dashboard',
        onPressed: () => _openAdd(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Tankfüllung'),
      ),
    );
  }

  void _openAdd(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddFillUpScreen()),
    );
  }

  String _relativeDate(DateTime d) {
    final diff = DateTime.now().difference(d).inDays;
    if (diff <= 0) return 'heute';
    if (diff == 1) return 'gestern';
    if (diff < 7) return 'vor $diff Tagen';
    if (diff < 30) return 'vor ${(diff / 7).floor()} Wochen';
    return 'vor ${(diff / 30).floor()} Monaten';
  }
}

class _ChartSection extends StatelessWidget {
  const _ChartSection({
    required this.title,
    required this.subtitle,
    required this.chart,
  });

  final String title;
  final String subtitle;
  final Widget chart;

  @override
  Widget build(BuildContext context) {
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          chart,
        ],
      ),
    );
  }
}
