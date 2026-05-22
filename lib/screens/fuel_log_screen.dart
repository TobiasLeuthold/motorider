import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import 'add_fillup_screen.dart';
import 'home_shell.dart';

class FuelLogScreen extends StatelessWidget {
  const FuelLogScreen({super.key, this.stream});

  /// Optional stream override for testing. Defaults to the global repo.
  final Stream<List<FillUp>>? stream;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<FillUp>>(
        stream: stream ?? fillUpRepo.watchAll(),
        builder: (context, snap) {
          final fillups = (snap.data ?? const <FillUp>[]).toList()
            ..sort((a, b) => b.odometerKm.compareTo(a.odometerKm));
          if (fillups.isEmpty) {
            return const Column(
              children: [
                TabHeader(
                  title: 'Tankbuch',
                  subtitle: 'Alle Tankfüllungen, neueste zuerst',
                ),
                Expanded(
                  child: EmptyState(
                    illustrationAsset: 'assets/illustrations/no_fillups.svg',
                    title: 'Noch keine Tankfüllung',
                    subtitle: 'Mit dem +-Knopf erstellst du deinen ersten Eintrag.',
                  ),
                ),
              ],
            );
          }
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: TabHeader(
                  title: 'Tankbuch',
                  subtitle: '${fillups.length} Einträge',
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                sliver: SliverList.separated(
                  itemCount: fillups.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final f = fillups[i];
                    final prev = i + 1 < fillups.length ? fillups[i + 1] : null;
                    final kmSince = prev != null ? f.odometerKm - prev.odometerKm : null;
                    return _FillUpTile(fillup: f, kmSinceLast: kmSince);
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-add-fuel-log',
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
}

class _FillUpTile extends StatelessWidget {
  const _FillUpTile({required this.fillup, required this.kmSinceLast});

  final FillUp fillup;
  final int? kmSinceLast;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final timeFmt = DateFormat('HH:mm');
    final nf = NumberFormat.decimalPattern('de_CH');
    final isBaseline = fillup.liters == 0;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AddFillUpScreen(existing: fillup),
        )),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: (isBaseline ? AppColors.accentSoft : AppColors.accent)
                      .withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isBaseline ? Icons.flag_rounded : Icons.local_gas_station_rounded,
                  color: isBaseline ? AppColors.accentSoft : AppColors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isBaseline)
                      const Text(
                        'Startkilometer',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                        ),
                      )
                    else
                      Row(
                        children: [
                          Text(
                            '${fillup.liters.toStringAsFixed(2)} L',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppColors.text,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '· CHF ${fillup.totalChf.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${nf.format(fillup.odometerKm)} km',
                        if (!isBaseline && kmSinceLast != null && kmSinceLast! > 0)
                          '+${nf.format(kmSinceLast)} km',
                        if (!isBaseline)
                          'CHF ${fillup.pricePerLiter.toStringAsFixed(2)}/L',
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (fillup.station != null && fillup.station!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        fillup.station!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.accentSoft,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    dateFmt.format(fillup.date),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  Text(
                    timeFmt.format(fillup.date),
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
