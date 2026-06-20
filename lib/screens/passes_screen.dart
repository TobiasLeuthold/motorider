import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../stats/pass_exploration_loader.dart';
import '../stats/pass_explorer.dart';
import '../stats/pass_summary.dart';
import '../theme.dart';
import '../widgets/seg_toggle.dart';
import 'pass_detail_screen.dart';

/// Which top-level view of the Pässe screen is shown.
enum _View { all, mine }

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
/// build thread and renders, behind a top "Alle Pässe / Meine Pässe" toggle,
/// either a sortable/filterable pass list or a rewarding personal-stats view.
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

  _View _view = _View.all;
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

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Headline(stats: stats)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegToggle<_View>(
              value: _view,
              options: const [
                (_View.all, 'Alle Pässe'),
                (_View.mine, 'Meine Pässe'),
              ],
              onChanged: (v) => setState(() => _view = v),
            ),
          ),
        ),
        if (_view == _View.all)
          ..._allPassesSlivers(res)
        else
          SliverToBoxAdapter(child: _MineView(res: res, onOpenPass: _openPass)),
        SliverToBoxAdapter(child: _AttributionFooter(text: _attribution)),
      ],
    );
  }

  List<Widget> _allPassesSlivers(PassExplorationResult res) {
    final items = _sortedFiltered(res.progress);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
              child: _PassTile(progress: p, onTap: () => _openPass(p)),
            );
          },
        ),
    ];
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

  void _openPass(PassProgress p) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PassDetailScreen(progress: p)),
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

// ───────────────────────── Meine Pässe (overview) ─────────────────────────

/// The rewarding personal-stats view: a hero "fastest crossing" banner, a grid
/// of dopamine stats (metres collected, hairpins ridden, favourite pass,
/// highest explored, time on passes), and a full per-canton progress board.
class _MineView extends StatelessWidget {
  const _MineView({required this.res, required this.onOpenPass});
  final PassExplorationResult res;
  final ValueChanged<PassProgress> onOpenPass;

  @override
  Widget build(BuildContext context) {
    final stats = res.stats;
    final dec = NumberFormat.decimalPattern('de_CH');

    if (stats.explored == 0) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: _MineEmpty(),
      );
    }

    final fastest = stats.fastestCrossing;
    final fav = stats.mostCrossed;
    final highest = stats.highestCrossed;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (fastest != null) ...[
            _FastestBanner(
              fastest: fastest,
              onTap: () => _openFastest(fastest),
            ),
            const SizedBox(height: 12),
          ],
          // Dopamine grid.
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.terrain_rounded,
                  label: 'Höhenmeter gesammelt',
                  value: '${dec.format(stats.metresCollected)} m',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
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
                child: _StatCard(
                  icon: Icons.timer_outlined,
                  label: 'Zeit auf Pässen',
                  value: formatTotalTimeOnPasses(stats.totalTimeOnPassesS),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  icon: Icons.map_rounded,
                  label: 'Kantone befahren',
                  value: '${cantonsWithProgress(stats.perCanton)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (fav != null)
            _HighlightCard(
              icon: Icons.favorite_rounded,
              label: 'Lieblingspass',
              title: fav.pass.name,
              trailing: '${fav.count}×',
              onTap: () => onOpenPass(fav),
            ),
          if (highest != null) ...[
            const SizedBox(height: 10),
            _HighlightCard(
              icon: Icons.landscape_rounded,
              label: 'Höchster erkundet',
              title: highest.pass.name,
              trailing:
                  highest.pass.ele == null ? '–' : '${highest.pass.ele} m',
              onTap: () => onOpenPass(highest),
            ),
          ],
          const SizedBox(height: 20),
          if (stats.perCanton.isNotEmpty) ...[
            const _SectionLabel(
              icon: Icons.flag_rounded,
              text: 'Fortschritt nach Kanton',
            ),
            const SizedBox(height: 10),
            _CantonBoard(perCanton: stats.perCanton),
          ],
        ],
      ),
    );
  }

  void _openFastest(FastestCrossing fastest) {
    // Jump to the detail of the pass that holds the fastest crossing.
    final match =
        res.progress.where((p) => p.pass.name == fastest.pass.name);
    if (match.isNotEmpty) onOpenPass(match.first);
  }
}

class _MineEmpty extends StatelessWidget {
  const _MineEmpty();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.surfaceHi,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.terrain_rounded,
                color: AppColors.accentSoft, size: 28),
          ),
          const SizedBox(height: 14),
          const Text(
            'Noch keine Pässe erobert',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Sobald du deinen ersten Pass überquerst, sammeln sich hier deine '
            'Höhenmeter, Kehren und Bestzeiten.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// The trophy card: your single fastest pass crossing anywhere.
class _FastestBanner extends StatelessWidget {
  const _FastestBanner({required this.fastest, required this.onTap});
  final FastestCrossing fastest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.accent.withValues(alpha: 0.30),
                AppColors.surfaceHi,
              ],
            ),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.bolt_rounded,
                    color: AppColors.accent, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Schnellste Passüberquerung',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accentSoft,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fastest.pass.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                    Text(
                      dateFmt.format(fastest.at),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${fastest.avgSpeedKmh.round()}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: AppColors.accent,
                      letterSpacing: -1,
                    ),
                  ),
                  const Text(
                    'km/h',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accentSoft,
                    ),
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

/// A compact dopamine stat card (icon, big value, label).
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.accentSoft),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A wide highlight card (favourite / highest) that opens the pass detail.
class _HighlightCard extends StatelessWidget {
  const _HighlightCard({
    required this.icon,
    required this.label,
    required this.title,
    required this.trailing,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String title;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.accent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trailing,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: AppColors.text),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
      ],
    );
  }
}

/// Full per-canton progress board: one row per canton with a done/total tally
/// and a progress bar, sorted by most-explored first.
class _CantonBoard extends StatelessWidget {
  const _CantonBoard({required this.perCanton});
  final Map<String, CantonProgress> perCanton;

  @override
  Widget build(BuildContext context) {
    final entries = perCanton.entries.toList()
      ..sort((a, b) {
        final c = b.value.done.compareTo(a.value.done);
        if (c != 0) return c;
        final pc = b.value.percent.compareTo(a.value.percent);
        return pc != 0 ? pc : a.key.compareTo(b.key);
      });
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: AppColors.gridLine.withValues(alpha: 0.5),
              ),
            _CantonRow(code: entries[i].key, prog: entries[i].value),
          ],
        ],
      ),
    );
  }
}

class _CantonRow extends StatelessWidget {
  const _CantonRow({required this.code, required this.prog});
  final String code;
  final CantonProgress prog;

  @override
  Widget build(BuildContext context) {
    final done = prog.done > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              code,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: done ? AppColors.text : AppColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: _ProgressBar(value: prog.percent / 100.0, height: 7),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              '${prog.done}/${prog.total}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: done ? AppColors.text : AppColors.textMuted,
              ),
            ),
          ),
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
      // Kurvigkeit (°/km) — only on genuinely curvy passes to avoid clutter.
      if (p.curvinessScore != null && p.curvinessScore! >= 200)
        '${p.curvinessScore!.round()} °/km',
    ].join(' · ');

    return Opacity(
      opacity: crossed ? 1.0 : 0.7,
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
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (crossed && progress.lastDate != null)
                      Text(
                        dateFmt.format(progress.lastDate!),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textMuted, size: 20),
                  ],
                ),
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
