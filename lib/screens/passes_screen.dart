import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../stats/pass_exploration_loader.dart';
import '../stats/pass_explorer.dart';
import '../theme.dart';
import '../widgets/seg_toggle.dart';
import 'ride_detail_screen.dart';

/// How the Pässe list is ordered.
enum _Sort { explored, ele, name, canton }

extension on _Sort {
  String get label => switch (this) {
        _Sort.explored => 'Erkundet',
        _Sort.ele => 'Höhe',
        _Sort.name => 'Name',
        _Sort.canton => 'Kanton',
      };
}

/// Which subset of passes is shown.
enum _Filter { all, done, open }

/// Pässe — Swiss mountain-pass exploration log. Computes which dataset passes
/// the rider has crossed (over all recorded rides' full GPS tracks) off the
/// build thread and renders progress + a sortable/filterable list.
class PassesScreen extends StatefulWidget {
  const PassesScreen({super.key, this.loader});

  /// Injectable for tests; defaults to the global ride repo.
  final PassExplorationLoader? loader;

  @override
  State<PassesScreen> createState() => _PassesScreenState();
}

class _PassesScreenState extends State<PassesScreen> {
  late final PassExplorationLoader _loader;
  late Future<PassExplorationResult> _future;
  String? _attribution;

  _Sort _sort = _Sort.explored;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _loader = widget.loader ?? PassExplorationLoader(rideRepo);
    _future = _loader.compute();
    loadPassAttribution().then((a) {
      if (mounted) setState(() => _attribution = a);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pässe')),
      body: FutureBuilder<PassExplorationResult>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Pässe konnten nicht geladen werden.\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
            );
          }
          return _content(snap.data!);
        },
      ),
    );
  }

  Widget _content(PassExplorationResult res) {
    final stats = res.stats;
    final items = _sortedFiltered(res.progress);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Headline(stats: stats)),
        SliverToBoxAdapter(child: _StatsStrip(stats: stats)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _Controls(
              sort: _sort,
              filter: _filter,
              onSort: (s) => setState(() => _sort = s),
              onFilter: (f) => setState(() => _filter = f),
            ),
          ),
        ),
        if (items.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 32, 16, 32),
              child: Center(
                child: Text(
                  'Keine Pässe in dieser Ansicht.',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
            ),
          )
        else
          SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final p = items[i];
              return Padding(
                padding: EdgeInsets.fromLTRB(16, i == 0 ? 4 : 0, 16, 0),
                child: _PassTile(
                  progress: p,
                  onTap: p.crossed ? () => _showCrossingRides(p) : null,
                ),
              );
            },
          ),
        SliverToBoxAdapter(child: _AttributionFooter(text: _attribution)),
      ],
    );
  }

  List<PassProgress> _sortedFiltered(List<PassProgress> all) {
    final filtered = all.where((p) => switch (_filter) {
          _Filter.all => true,
          _Filter.done => p.crossed,
          _Filter.open => !p.crossed,
        }).toList();

    int byEleDesc(PassProgress a, PassProgress b) =>
        (b.pass.ele ?? -1).compareTo(a.pass.ele ?? -1);
    int byName(PassProgress a, PassProgress b) =>
        a.pass.name.toLowerCase().compareTo(b.pass.name.toLowerCase());
    String firstCanton(PassProgress p) =>
        p.pass.cantons.isEmpty ? 'ZZ' : p.pass.cantons.first;

    switch (_sort) {
      case _Sort.explored:
        // Crossed first; within each group, highest first.
        filtered.sort((a, b) {
          if (a.crossed != b.crossed) return a.crossed ? -1 : 1;
          return byEleDesc(a, b);
        });
      case _Sort.ele:
        filtered.sort(byEleDesc);
      case _Sort.name:
        filtered.sort(byName);
      case _Sort.canton:
        filtered.sort((a, b) {
          final c = firstCanton(a).compareTo(firstCanton(b));
          return c != 0 ? c : byEleDesc(a, b);
        });
    }
    return filtered;
  }

  void _showCrossingRides(PassProgress p) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CrossingRidesSheet(progress: p),
    );
  }
}

// ───────────────────────────── Headline ──────────────────────────────

class _Headline extends StatelessWidget {
  const _Headline({required this.stats});
  final CollectionStats stats;

  @override
  Widget build(BuildContext context) {
    final pct = stats.percent;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceHi, AppColors.bg],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${stats.explored}',
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                  letterSpacing: -1,
                ),
              ),
              Text(
                ' / ${stats.total} Pässe',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(0)} %',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ProgressBar(value: stats.total == 0 ? 0 : stats.explored / stats.total),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, this.height = 10});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Stack(
        children: [
          Container(height: height, color: AppColors.surfaceHi),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(
              height: height,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.accentSoft, AppColors.accent],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Stats strip ───────────────────────────

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats});
  final CollectionStats stats;

  @override
  Widget build(BuildContext context) {
    final dec = NumberFormat.decimalPattern('de_CH');
    final highest = stats.highestCrossed?.pass;
    final fav = stats.mostCrossed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.terrain_rounded,
                  label: 'Höhenmeter gesammelt',
                  value: '${dec.format(stats.metresCollected)} m',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStat(
                  icon: Icons.u_turn_right_rounded,
                  label: 'Kehren gefahren',
                  value: stats.totalHairpins > 0
                      ? dec.format(stats.totalHairpins)
                      : '–',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.landscape_rounded,
                  label: 'Höchster erkundet',
                  value: highest == null
                      ? '–'
                      : '${highest.ele ?? '?'} m',
                  sub: highest?.name,
                  tint: AppColors.accentSoft,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MiniStat(
                  icon: Icons.favorite_rounded,
                  label: 'Lieblingspass',
                  value: fav == null ? '–' : '${fav.count}×',
                  sub: fav?.pass.name,
                  tint: AppColors.accentSoft,
                ),
              ),
            ],
          ),
          if (stats.perCanton.isNotEmpty) ...[
            const SizedBox(height: 10),
            _CantonStrip(perCanton: stats.perCanton),
          ],
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
    this.tint,
  });
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? AppColors.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          if (sub != null)
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

/// Horizontal scroll of per-canton done/total chips with a tiny progress bar.
class _CantonStrip extends StatelessWidget {
  const _CantonStrip({required this.perCanton});
  final Map<String, CantonProgress> perCanton;

  @override
  Widget build(BuildContext context) {
    // Sort: most-explored cantons first, then alphabetically.
    final entries = perCanton.entries.toList()
      ..sort((a, b) {
        final c = b.value.done.compareTo(a.value.done);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final e = entries[i];
          return _CantonChip(code: e.key, prog: e.value);
        },
      ),
    );
  }
}

class _CantonChip extends StatelessWidget {
  const _CantonChip({required this.code, required this.prog});
  final String code;
  final CantonProgress prog;

  @override
  Widget build(BuildContext context) {
    final done = prog.done > 0;
    return Container(
      width: 78,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: done
              ? AppColors.accent.withValues(alpha: 0.4)
              : AppColors.gridLine.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                code,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: done ? AppColors.text : AppColors.textMuted,
                ),
              ),
              Text(
                '${prog.done}/${prog.total}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          _ProgressBar(value: prog.percent / 100.0, height: 4),
        ],
      ),
    );
  }
}

// ─────────────────────────── Controls ───────────────────────────

class _Controls extends StatelessWidget {
  const _Controls({
    required this.sort,
    required this.filter,
    required this.onSort,
    required this.onFilter,
  });
  final _Sort sort;
  final _Filter filter;
  final ValueChanged<_Sort> onSort;
  final ValueChanged<_Filter> onFilter;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegToggle<_Filter>(
          value: filter,
          options: const [
            (_Filter.all, 'Alle'),
            (_Filter.done, 'Erkundet'),
            (_Filter.open, 'Offen'),
          ],
          onChanged: onFilter,
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.sort_rounded,
                    size: 16, color: AppColors.textMuted),
              ),
              for (final s in _Sort.values) ...[
                _SortChip(
                  label: s.label,
                  selected: s == sort,
                  onTap: () => onSort(s),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.gridLine,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.black : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Pass tile ───────────────────────────

class _PassTile extends StatelessWidget {
  const _PassTile({required this.progress, this.onTap});
  final PassProgress progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = progress.pass;
    final crossed = progress.crossed;
    final dateFmt = DateFormat('dd.MM.yyyy');

    final titleColor = crossed ? AppColors.text : AppColors.textMuted;
    final facts = <String>[
      if (p.ele != null) '${p.ele} m',
      if (p.cantons.isNotEmpty) p.cantons.join('/'),
      if (p.hairpins != null) '${p.hairpins} Kehren',
    ].join(' · ');

    return Opacity(
      opacity: crossed ? 1.0 : 0.55,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: crossed
                    ? AppColors.accent.withValues(alpha: 0.35)
                    : AppColors.gridLine.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              children: [
                _StatusBadge(crossed: crossed, count: progress.count),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                      if (p.connects != null && p.connects!.length == 2) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.swap_horiz_rounded,
                                size: 13, color: AppColors.textMuted),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${p.connects![0]} – ${p.connects![1]}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (crossed) ...[
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (progress.lastDate != null)
                        Text(
                          dateFmt.format(progress.lastDate!),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      if (onTap != null)
                        const Icon(Icons.chevron_right_rounded,
                            color: AppColors.textMuted, size: 20),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.crossed, required this.count});
  final bool crossed;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (!crossed) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.lock_outline_rounded,
            size: 17, color: AppColors.textMuted),
      );
    }
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: count > 1
            ? Text(
                '$count×',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              )
            : const Icon(Icons.check_rounded,
                size: 19, color: AppColors.accent),
      ),
    );
  }
}

// ──────────────────────── Crossing-rides sheet ────────────────────────

class _CrossingRidesSheet extends StatelessWidget {
  const _CrossingRidesSheet({required this.progress});
  final PassProgress progress;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('EEEE, dd.MM.yyyy', 'de');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              progress.pass.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${progress.count}× erkundet',
              style: const TextStyle(fontSize: 13, color: AppColors.accent),
            ),
            const SizedBox(height: 14),
            if (progress.rideIds.isEmpty)
              const Text(
                'Keine verknüpften Fahrten.',
                style: TextStyle(color: AppColors.textMuted),
              )
            else
              ...progress.rideIds.map((rideId) {
                final matches = rideRepo.latest.where((r) => r.id == rideId);
                final Ride? ride = matches.isEmpty ? null : matches.first;
                final title = ride?.title;
                final subtitle = ride != null
                    ? dateFmt.format(ride.startedAt)
                    : 'Fahrt';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.route_rounded,
                      color: AppColors.accent),
                  title: Text(
                    (title != null && title.isNotEmpty) ? title : 'Ausfahrt',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    subtitle,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textMuted),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RideDetailScreen(rideId: rideId),
                      ),
                    );
                  },
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── Footer ───────────────────────────

class _AttributionFooter extends StatelessWidget {
  const _AttributionFooter({this.text});
  final String? text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Text(
        text ?? 'Pass-Daten © OpenStreetMap-Mitwirkende (ODbL).',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
      ),
    );
  }
}
