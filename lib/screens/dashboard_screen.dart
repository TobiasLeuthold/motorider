import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../stats/pass_exploration_loader.dart';
import '../stats/pass_explorer.dart';
import '../stats/stats_calculator.dart';
import '../theme.dart';
import '../widgets/consumption_chart.dart';
import '../widgets/empty_state.dart';
import '../widgets/period_breakdown.dart';
import '../widgets/seg_toggle.dart';
import '../widgets/stat_card.dart';
import 'add_fillup_screen.dart';
import 'home_shell.dart';
import 'passes_screen.dart';

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

    final initial = stream == null ? fillUpRepo.latest : const <FillUp>[];
    return Scaffold(
      body: StreamBuilder<List<FillUp>>(
        initialData: initial,
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
                  const PassesTeaserCard(),
                  const SizedBox(height: 16),
                  _SpendOverviewCard(fillups: fillups),
                  const SizedBox(height: 16),
                  _FuelPriceCard(
                    insights: StatsCalculator.computeFuelInsights(fillups),
                  ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 16),
                  PeriodBreakdown(fillups: fillups),
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

/// Spend + distance for the current week / month / year, each with a change
/// chip against the previous period. Owns its own granularity toggle so the
/// dashboard can stay stateless (mirrors [PeriodBreakdown]).
class _SpendOverviewCard extends StatefulWidget {
  const _SpendOverviewCard({required this.fillups});

  final List<FillUp> fillups;

  @override
  State<_SpendOverviewCard> createState() => _SpendOverviewCardState();
}

class _SpendOverviewCardState extends State<_SpendOverviewCard> {
  PeriodGranularity _scope = PeriodGranularity.month;

  final _chf = NumberFormat.currency(
    locale: 'de_CH',
    symbol: 'CHF',
    decimalDigits: 2,
    customPattern: '¤ #,##0.00',
  );
  final _dec = NumberFormat.decimalPattern('de_CH');

  String get _scopeLabel => switch (_scope) {
        PeriodGranularity.week => 'Diese Woche',
        PeriodGranularity.month => 'Dieser Monat',
        PeriodGranularity.year => 'Dieses Jahr',
      };

  @override
  Widget build(BuildContext context) {
    final cmp = StatsCalculator.currentVsPrevious(
      widget.fillups,
      _scope,
      now: DateTime.now(),
    );
    final cur = cmp.current;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ausgaben & Fahrleistung',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 12),
          SegToggle<PeriodGranularity>(
            value: _scope,
            options: const [
              (PeriodGranularity.week, 'Woche'),
              (PeriodGranularity.month, 'Monat'),
              (PeriodGranularity.year, 'Jahr'),
            ],
            onChanged: (g) => setState(() => _scope = g),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Flexible(
                child: Text(
                  _chf.format(cur.chf),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Spending more is "bad" → ↑ shows red, ↓ green.
              _DeltaChip(pct: cmp.chfDeltaPct, higherIsGood: false),
            ],
          ),
          Text(
            '$_scopeLabel · Sprit',
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.gridLine),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _SpendMetric(
                  label: 'Gefahren',
                  value: '${_dec.format(cur.km)} km',
                  delta: _DeltaChip(pct: cmp.kmDeltaPct, higherIsGood: true),
                ),
              ),
              Expanded(
                child: _SpendMetric(
                  label: 'Getankt',
                  value: '${_dec.format(cur.liters.round())} L',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpendMetric extends StatelessWidget {
  const _SpendMetric({required this.label, required this.value, this.delta});
  final String label;
  final String value;
  final Widget? delta;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Row(
          children: [
            Flexible(
              child: Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                ),
              ),
            ),
            if (delta != null) ...[const SizedBox(width: 8), delta!],
          ],
        ),
      ],
    );
  }
}

/// Percentage-change pill. [higherIsGood] flips the colour semantics so a drop
/// in spend reads green while a drop in distance reads muted/red.
class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.pct, required this.higherIsGood});
  final double? pct;
  final bool higherIsGood;

  static const _good = Color(0xFF34D399);

  @override
  Widget build(BuildContext context) {
    final (text, color) = _content();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }

  (String, Color) _content() {
    final p = pct;
    if (p == null) return ('neu', AppColors.textMuted);
    if (p.abs() < 0.5) return ('±0%', AppColors.textMuted);
    final up = p > 0;
    final good = up == higherIsGood;
    return (
      '${up ? '▲' : '▼'} ${p.abs().toStringAsFixed(0)}%',
      good ? _good : AppColors.danger,
    );
  }
}

/// Fuel-price card: litre-weighted average paid, plus the cheapest and priciest
/// fills (with date and station). Hidden until there's at least one fill-up.
class _FuelPriceCard extends StatelessWidget {
  const _FuelPriceCard({required this.insights});
  final FuelInsights insights;

  @override
  Widget build(BuildContext context) {
    final i = insights;
    if (!i.hasData) return const SizedBox.shrink();
    final price = NumberFormat('0.00');
    final dateFmt = DateFormat('dd.MM.yy');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_gas_station_rounded,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              const Text(
                'Spritpreis',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const Spacer(),
              Text(
                'Ø CHF ${price.format(i.avgPricePerLiter)}/L',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
          if (i.lastVsAvg != null) ...[
            const SizedBox(height: 4),
            Text(
              _lastVsText(i.lastVsAvg!, price),
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _PriceExtreme(
                  label: 'Günstigste',
                  fill: i.cheapest!,
                  color: const Color(0xFF34D399),
                  price: price,
                  dateFmt: dateFmt,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PriceExtreme(
                  label: 'Teuerste',
                  fill: i.priciest!,
                  color: AppColors.danger,
                  price: price,
                  dateFmt: dateFmt,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _lastVsText(double diff, NumberFormat price) {
    if (diff.abs() < 0.005) return 'Letzte Tankung: im Schnitt';
    final abs = price.format(diff.abs());
    return diff < 0
        ? 'Letzte Tankung: CHF $abs unter dem Schnitt'
        : 'Letzte Tankung: CHF $abs über dem Schnitt';
  }
}

class _PriceExtreme extends StatelessWidget {
  const _PriceExtreme({
    required this.label,
    required this.fill,
    required this.color,
    required this.price,
    required this.dateFmt,
  });
  final String label;
  final FillUp fill;
  final Color color;
  final NumberFormat price;
  final DateFormat dateFmt;

  @override
  Widget build(BuildContext context) {
    final station = fill.station?.trim();
    final sub = (station != null && station.isNotEmpty)
        ? '${dateFmt.format(fill.date)} · $station'
        : dateFmt.format(fill.date);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            'CHF ${price.format(fill.pricePerLiter)}',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Übersicht teaser for the Pässe feature: "Pässe erkundet · X / 99 (Z %)"
/// with a slim progress bar. Computes crossings off the build thread and opens
/// the full [PassesScreen] on tap. Runs its own future so it doesn't disturb
/// the dashboard's fuel stream.
class PassesTeaserCard extends StatefulWidget {
  const PassesTeaserCard({super.key, this.loader});

  /// Injectable for tests; defaults to the global ride repo.
  final PassExplorationLoader? loader;

  @override
  State<PassesTeaserCard> createState() => _PassesTeaserCardState();
}

class _PassesTeaserCardState extends State<PassesTeaserCard> {
  late final Future<PassExplorationResult> _future;

  @override
  void initState() {
    super.initState();
    final loader = widget.loader ?? PassExplorationLoader(rideRepo);
    _future = loader.compute();
  }

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PassesScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PassExplorationResult>(
      future: _future,
      builder: (context, snap) {
        final stats = snap.data?.stats;
        final explored = stats?.explored ?? 0;
        final total = stats?.total ?? 99;
        final pct = stats?.percent ?? 0;
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _open,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.terrain_rounded,
                            color: AppColors.accent, size: 16),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Pässe erkundet',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const Spacer(),
                      if (snap.connectionState != ConnectionState.done)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textMuted),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$explored',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        ' / $total',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${pct.toStringAsFixed(0)} %',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        Container(height: 8, color: AppColors.surfaceHi),
                        FractionallySizedBox(
                          widthFactor:
                              (total == 0 ? 0.0 : explored / total).clamp(0.0, 1.0),
                          child: Container(
                            height: 8,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [AppColors.accentSoft, AppColors.accent],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
