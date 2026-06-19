import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../services/ride_tracker.dart';
import '../stats/ride_filter.dart';
import '../theme.dart';
import '../widgets/ride_polyline_map.dart';
import 'home_shell.dart';
import 'ride_detail_screen.dart';

// ───────────────────────────────────────────────────────────────────────
// Colour cue: maps a normalised metric (0 chill → 1 spirited) to green→red.
// Local to the rides screen — mirrors map_screen's priceColor scale rather
// than importing it, so the two stay independent.
// ───────────────────────────────────────────────────────────────────────
const _cueChill = Color(0xFF34D399); // green
const _cueMid = Color(0xFFF5C453); // amber
const _cueSpirited = Color(0xFFFF5A6A); // red

Color rideCueColor(double t) {
  t = t.clamp(0.0, 1.0);
  return t < 0.5
      ? Color.lerp(_cueChill, _cueMid, t * 2)!
      : Color.lerp(_cueMid, _cueSpirited, (t - 0.5) * 2)!;
}

/// "Touren" tab. Two presentation modes:
///   - No ride active → header + Start button + history list.
///   - Ride active → live map + live stats + Stop button.
class RidesScreen extends StatelessWidget {
  const RidesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<TrackerState>(
        stream: rideTracker.changes,
        initialData: rideTracker.state,
        builder: (context, snap) {
          final tracker = snap.data ?? const TrackerState.idle();
          return tracker.isTracking
              ? const _ActiveRideView()
              : const _HistoryView();
        },
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// History (no ride active)
// ───────────────────────────────────────────────────────────────────────

class _HistoryView extends StatefulWidget {
  const _HistoryView();

  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  RideFilter _filter = RideFilter.none;
  RideColorMetric _cueMetric = RideColorMetric.avgSpeed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const TabHeader(title: 'Touren', subtitle: 'Honda CB 750 Hornet'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _startRide(context),
              icon: const Icon(Icons.play_arrow_rounded, size: 22),
              label: const Text('Tour starten'),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Ride>>(
            stream: rideRepo.watchAll(),
            initialData: rideRepo.latest,
            builder: (context, snap) {
              final all = snap.data ?? const <Ride>[];
              // No rides recorded at all → first-run prompt, no filter chrome.
              if (all.isEmpty) {
                return const _EmptyHistory();
              }

              final shown = applyRideFilter(all, _filter);
              final summary = rideSummary(shown);
              final range = metricRange(shown, _cueMetric);

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  _FilterSortBar(
                    filter: _filter,
                    onSort: (s) =>
                        setState(() => _filter = _filter.copyWith(sort: s)),
                    onOpenFilters: () => _openFilterSheet(all),
                    onReset: _filter.hasActiveConstraints
                        ? () =>
                            setState(() => _filter = _filter.clearedConstraints())
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _SummaryHeader(summary: summary),
                  const SizedBox(height: 12),
                  if (shown.isNotEmpty)
                    _CueLegend(
                      metric: _cueMetric,
                      range: range,
                      onCycleMetric: () => setState(() {
                        const values = RideColorMetric.values;
                        _cueMetric =
                            values[(_cueMetric.index + 1) % values.length];
                      }),
                    ),
                  if (shown.isNotEmpty) const SizedBox(height: 12),
                  if (shown.isEmpty)
                    _NoMatches(
                      onReset: () => setState(
                          () => _filter = _filter.clearedConstraints()),
                    )
                  else
                    for (var i = 0; i < shown.length; i++) ...[
                      _RideTile(
                        ride: shown[i],
                        cueT: range.normalize(_cueMetric.value(shown[i])),
                      ),
                      if (i != shown.length - 1) const SizedBox(height: 10),
                    ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openFilterSheet(List<Ride> all) async {
    final result = await showModalBottomSheet<RideFilter>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FilterSheet(initial: _filter, allRides: all),
    );
    if (result != null && mounted) {
      setState(() => _filter = result);
    }
  }

  Future<void> _startRide(BuildContext context) async {
    try {
      await rideTracker.startRide();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }
}

// ───────────────────────────────────────────────────────────────────────
// Filter / sort bar
// ───────────────────────────────────────────────────────────────────────

class _FilterSortBar extends StatelessWidget {
  const _FilterSortBar({
    required this.filter,
    required this.onSort,
    required this.onOpenFilters,
    required this.onReset,
  });

  final RideFilter filter;
  final ValueChanged<RideSort> onSort;
  final VoidCallback onOpenFilters;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final activeCount = filter.activeDimensionCount;
    return Row(
      children: [
        // Filter button with an active-dimension count badge.
        _BarButton(
          icon: Icons.tune_rounded,
          label: activeCount > 0 ? 'Filter · $activeCount' : 'Filter',
          active: activeCount > 0,
          onTap: onOpenFilters,
        ),
        const SizedBox(width: 8),
        if (onReset != null) ...[
          _BarButton(
            icon: Icons.close_rounded,
            label: 'Reset',
            active: false,
            onTap: onReset!,
          ),
          const SizedBox(width: 8),
        ],
        const Spacer(),
        // Sort dropdown.
        PopupMenuButton<RideSort>(
          initialValue: filter.sort,
          color: AppColors.surfaceHi,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onSelected: onSort,
          itemBuilder: (_) => [
            for (final s in RideSort.values)
              PopupMenuItem(
                value: s,
                child: Text(
                  s.label,
                  style: TextStyle(
                    color: s == filter.sort
                        ? AppColors.accent
                        : AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.surfaceHi,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.gridLine),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.swap_vert_rounded,
                    size: 16, color: AppColors.textMuted),
                const SizedBox(width: 6),
                Text(
                  filter.sort.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const Icon(Icons.arrow_drop_down_rounded,
                    size: 18, color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.accent : AppColors.surfaceHi,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? AppColors.accent : AppColors.gridLine,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 15,
                  color: active ? Colors.black : AppColors.textMuted),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.black : AppColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Summary header — reflects the filtered set
// ───────────────────────────────────────────────────────────────────────

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});
  final RideSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                s.isEmpty ? 'Keine Touren' : '${s.count} Touren',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _SummaryStat(
                label: 'km gesamt',
                value: s.totalDistanceKm.toStringAsFixed(0),
              ),
              _SummaryStat(
                label: 'Zeit',
                value: _formatDuration(s.totalDuration),
              ),
              _SummaryStat(
                label: 'Längste',
                value: '${s.longestRideKm.toStringAsFixed(0)} km',
              ),
              _SummaryStat(
                label: 'Top km/h',
                value: s.topSpeedKmh.toStringAsFixed(0),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Colour-cue legend (tap to cycle the mapped metric)
// ───────────────────────────────────────────────────────────────────────

class _CueLegend extends StatelessWidget {
  const _CueLegend({
    required this.metric,
    required this.range,
    required this.onCycleMetric,
  });
  final RideColorMetric metric;
  final MetricRange range;
  final VoidCallback onCycleMetric;

  String _fmt(double v) => metric == RideColorMetric.distance
      ? '${v.toStringAsFixed(0)} km'
      : v.toStringAsFixed(0);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onCycleMetric,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gridLine),
          ),
          child: Row(
            children: [
              const Icon(Icons.palette_rounded,
                  size: 15, color: AppColors.textMuted),
              const SizedBox(width: 8),
              Text(
                'Farbe: ${metric.label}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(width: 10),
              Text(_fmt(range.min),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 7,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: const LinearGradient(
                      colors: [_cueChill, _cueMid, _cueSpirited],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(_fmt(range.max),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      alignment: Alignment.center,
      child: Column(
        children: [
          const Icon(Icons.filter_alt_off_rounded,
              size: 40, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text(
            'Keine Touren passen zum Filter',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Lockere die Filter oder setze sie zurück.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Filter zurücksetzen'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'Noch keine Touren aufgezeichnet.\nTippe oben auf "Tour starten" für deine erste Fahrt.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted, fontSize: 14),
        ),
      ),
    );
  }
}

class _RideTile extends StatelessWidget {
  const _RideTile({required this.ride, required this.cueT});
  final Ride ride;

  /// 0 (chill) → 1 (spirited): position of this ride's cue metric within the
  /// currently-shown set. Drives the left colour bar.
  final double cueT;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final timeFmt = DateFormat('HH:mm');
    final durFmt = _formatDuration(ride.totalDuration);
    final cue = rideCueColor(cueT);
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RideDetailScreen(rideId: ride.id)),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.gridLine),
          ),
          child: Row(
            children: [
              // Colour cue: a vertical bar coloured green→red by the active
              // metric across the shown rides.
              Container(
                width: 5,
                height: 44,
                decoration: BoxDecoration(
                  color: cue,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.route_rounded,
                  color: AppColors.accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ride.title?.isNotEmpty == true
                          ? ride.title!
                          : '${dateFmt.format(ride.startedAt)} · ${timeFmt.format(ride.startedAt)}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${ride.distanceKm.toStringAsFixed(1)} km · '
                      '$durFmt · '
                      'Ø ${ride.avgMovingSpeedKmh.toStringAsFixed(0)} · '
                      'Max ${ride.maxSpeedKmh.toStringAsFixed(0)} km/h',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Filter bottom sheet — range sliders + date window
// ───────────────────────────────────────────────────────────────────────

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.allRides});
  final RideFilter initial;

  /// The full (unfiltered) ride set, used to bound the sliders to the data's
  /// actual extents so the controls always span something meaningful.
  final List<Ride> allRides;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late RangeValues _distance;
  late RangeValues _avg;
  late RangeValues _max;
  late RangeValues _durationMin; // ride length in whole minutes
  DateTime? _from;
  DateTime? _to;

  // Data bounds (full extents). When a dimension is at its full extent we treat
  // it as "no constraint" so the resulting filter only carries real narrowing.
  late final double _distMin, _distMax;
  late final double _avgMin, _avgMax;
  late final double _maxMin, _maxMax;
  late final double _durMin, _durMax; // minutes

  @override
  void initState() {
    super.initState();
    final rides = widget.allRides;

    ({double lo, double hi}) extent(double Function(Ride) f, double pad) {
      var lo = f(rides.first);
      var hi = lo;
      for (final r in rides) {
        final v = f(r);
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      // Round outward to whole units and guarantee a non-zero span so the
      // slider is draggable even when every ride shares a value.
      lo = lo.floorToDouble();
      hi = hi.ceilToDouble();
      if (hi <= lo) hi = lo + pad;
      return (lo: lo, hi: hi);
    }

    final d = extent((r) => r.distanceKm, 1);
    _distMin = d.lo;
    _distMax = d.hi;
    final a = extent((r) => r.avgMovingSpeedKmh, 1);
    _avgMin = a.lo;
    _avgMax = a.hi;
    final m = extent((r) => r.maxSpeedKmh, 1);
    _maxMin = m.lo;
    _maxMax = m.hi;
    final du = extent((r) => r.totalDuration.inMinutes.toDouble(), 1);
    _durMin = du.lo;
    _durMax = du.hi;

    final f = widget.initial;
    _distance = RangeValues(
      (f.minDistanceKm ?? _distMin).clamp(_distMin, _distMax),
      (f.maxDistanceKm ?? _distMax).clamp(_distMin, _distMax),
    );
    _avg = RangeValues(
      (f.minAvgSpeedKmh ?? _avgMin).clamp(_avgMin, _avgMax),
      (f.maxAvgSpeedKmh ?? _avgMax).clamp(_avgMin, _avgMax),
    );
    _max = RangeValues(
      (f.minMaxSpeedKmh ?? _maxMin).clamp(_maxMin, _maxMax),
      (f.maxMaxSpeedKmh ?? _maxMax).clamp(_maxMin, _maxMax),
    );
    _durationMin = RangeValues(
      (f.minDuration?.inMinutes.toDouble() ?? _durMin).clamp(_durMin, _durMax),
      (f.maxDuration?.inMinutes.toDouble() ?? _durMax).clamp(_durMin, _durMax),
    );
    _from = f.from;
    _to = f.to;
  }

  RideFilter _build() {
    // Only emit a bound when the slider is pulled in from the full extent.
    double? lo(RangeValues v, double min) => v.start > min ? v.start : null;
    double? hi(RangeValues v, double max) => v.end < max ? v.end : null;

    return RideFilter(
      sort: widget.initial.sort,
      minDistanceKm: lo(_distance, _distMin),
      maxDistanceKm: hi(_distance, _distMax),
      minAvgSpeedKmh: lo(_avg, _avgMin),
      maxAvgSpeedKmh: hi(_avg, _avgMax),
      minMaxSpeedKmh: lo(_max, _maxMin),
      maxMaxSpeedKmh: hi(_max, _maxMax),
      minDuration: _durationMin.start > _durMin
          ? Duration(minutes: _durationMin.start.round())
          : null,
      maxDuration: _durationMin.end < _durMax
          ? Duration(minutes: _durationMin.end.round())
          : null,
      from: _from,
      to: _to,
    );
  }

  void _resetAll() {
    setState(() {
      _distance = RangeValues(_distMin, _distMax);
      _avg = RangeValues(_avgMin, _avgMax);
      _max = RangeValues(_maxMin, _maxMax);
      _durationMin = RangeValues(_durMin, _durMax);
      _from = null;
      _to = null;
    });
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = (isFrom ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2015),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = DateTime(picked.year, picked.month, picked.day);
      } else {
        // Inclusive end-of-day so the chosen day is fully covered.
        _to = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.tune_rounded,
                      size: 20, color: AppColors.accent),
                  const SizedBox(width: 8),
                  const Text(
                    'Touren filtern',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _resetAll,
                    child: const Text('Zurücksetzen'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _RangeRow(
                label: 'Distanz',
                unit: 'km',
                values: _distance,
                min: _distMin,
                max: _distMax,
                decimals: 0,
                onChanged: (v) => setState(() => _distance = v),
              ),
              _RangeRow(
                label: 'Ø Tempo',
                unit: 'km/h',
                values: _avg,
                min: _avgMin,
                max: _avgMax,
                decimals: 0,
                onChanged: (v) => setState(() => _avg = v),
              ),
              _RangeRow(
                label: 'Max Tempo',
                unit: 'km/h',
                values: _max,
                min: _maxMin,
                max: _maxMax,
                decimals: 0,
                onChanged: (v) => setState(() => _max = v),
              ),
              _RangeRow(
                label: 'Dauer',
                unit: 'min',
                values: _durationMin,
                min: _durMin,
                max: _durMax,
                decimals: 0,
                onChanged: (v) => setState(() => _durationMin = v),
              ),
              const SizedBox(height: 8),
              const Text(
                'Zeitraum',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _DateButton(
                      label: 'Von',
                      value: _from == null ? null : dateFmt.format(_from!),
                      onTap: () => _pickDate(isFrom: true),
                      onClear:
                          _from == null ? null : () => setState(() => _from = null),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DateButton(
                      label: 'Bis',
                      value: _to == null ? null : dateFmt.format(_to!),
                      onTap: () => _pickDate(isFrom: false),
                      onClear:
                          _to == null ? null : () => setState(() => _to = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_build()),
                  child: const Text('Anwenden'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeRow extends StatelessWidget {
  const _RangeRow({
    required this.label,
    required this.unit,
    required this.values,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onChanged,
  });
  final String label;
  final String unit;
  final RangeValues values;
  final double min;
  final double max;
  final int decimals;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    // At least one division per unit, capped so very wide ranges stay smooth.
    final span = (max - min).round();
    final divisions = span <= 0 ? 1 : (span > 200 ? 200 : span);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const Spacer(),
              Text(
                '${values.start.toStringAsFixed(decimals)}'
                ' – ${values.end.toStringAsFixed(decimals)} $unit',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
          RangeSlider(
            values: values,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: AppColors.accent,
            inactiveColor: AppColors.gridLine,
            labels: RangeLabels(
              values.start.toStringAsFixed(decimals),
              values.end.toStringAsFixed(decimals),
            ),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
  });
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHi,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.gridLine),
          ),
          child: Row(
            children: [
              const Icon(Icons.event_rounded,
                  size: 16, color: AppColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      value ?? 'beliebig',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: value == null
                            ? AppColors.textMuted
                            : AppColors.text,
                      ),
                    ),
                  ],
                ),
              ),
              if (onClear != null)
                GestureDetector(
                  onTap: onClear,
                  child: const Icon(Icons.close_rounded,
                      size: 16, color: AppColors.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Active ride view
// ───────────────────────────────────────────────────────────────────────

class _ActiveRideView extends StatefulWidget {
  const _ActiveRideView();
  @override
  State<_ActiveRideView> createState() => _ActiveRideViewState();
}

class _ActiveRideViewState extends State<_ActiveRideView> {
  final List<RidePoint> _points = [];

  @override
  void initState() {
    super.initState();
    // Pull whatever's already been collected (in case the screen rebuilds
    // after backgrounding while the ride continued recording).
    _hydratePoints();
  }

  Future<void> _hydratePoints() async {
    final ride = rideTracker.state.currentRide;
    if (ride == null) return;
    final existing = await rideRepo.getPoints(ride.id);
    if (!mounted) return;
    setState(() {
      _points
        ..clear()
        ..addAll(existing);
    });
  }

  void _appendFromTracker(TrackerState s) {
    final last = s.lastPoint;
    if (last == null) return;
    if (_points.isNotEmpty && _points.last.sequence == last.sequence) return;
    setState(() => _points.add(last));
  }

  Future<void> _stop() async {
    final ride = await rideTracker.stopRide();
    if (!mounted || ride == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Tour gespeichert: ${ride.distanceKm.toStringAsFixed(1)} km · '
          '${_formatDuration(ride.totalDuration)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TrackerState>(
      stream: rideTracker.changes,
      initialData: rideTracker.state,
      builder: (context, snap) {
        final state = snap.data ?? const TrackerState.idle();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _appendFromTracker(state);
        });
        return Stack(
          children: [
            RidePolylineMap(
              points: _points,
              followLast: true,
            ),
            // Stats panel at top + Stop button at bottom both ride above
            // the map.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: _LiveStatsPanel(state: state),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            // Solid fill so the button doesn't show the live
                            // map through it — a bare OutlinedButton is
                            // transparent and reads as broken over the map.
                            backgroundColor: AppColors.surface,
                            foregroundColor: state.isManuallyPaused
                                ? AppColors.accent
                                : AppColors.text,
                            side: BorderSide(
                              color: state.isManuallyPaused
                                  ? AppColors.accent
                                  : AppColors.gridLine,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: state.isManuallyPaused
                              ? rideTracker.resumeRide
                              : rideTracker.pauseRide,
                          icon: Icon(
                            state.isManuallyPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            size: 22,
                          ),
                          label: Text(
                            state.isManuallyPaused ? 'Weiter' : 'Pause',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 6,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _stop,
                          icon: const Icon(Icons.stop_rounded, size: 22),
                          label: const Text(
                            'Tour beenden',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LiveStatsPanel extends StatelessWidget {
  const _LiveStatsPanel({required this.state});
  final TrackerState state;

  @override
  Widget build(BuildContext context) {
    // lastSpeedKmh blends Doppler and positional speed — raw speedMs is
    // zero-stuck on emulators and some devices.
    final speedNow = state.stats.lastSpeedKmh;
    final s = state.stats;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left-aligned by the Column's crossAxisAlignment; the Container
          // hugs its content so the badge never stretches full-width.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: state.isPaused
                  ? AppColors.textMuted.withValues(alpha: 0.25)
                  : AppColors.accent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              state.isPaused ? 'PAUSIERT' : 'AUFNAHME',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
                color: state.isPaused ? AppColors.textMuted : Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _BigStat(
                label: 'km/h',
                value: speedNow.toStringAsFixed(0),
                highlight: true,
              ),
              _BigStat(
                label: 'km',
                value: s.distanceKm.toStringAsFixed(1),
              ),
              _BigStat(
                label: 'Zeit',
                value: _formatDuration(s.movingDuration),
                small: true,
              ),
              _BigStat(
                label: 'Ø km/h',
                value: s.avgMovingSpeedKmh.toStringAsFixed(0),
                small: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.label,
    required this.value,
    this.highlight = false,
    this.small = false,
  });
  final String label;
  final String value;
  final bool highlight;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      fontSize: small ? 18 : 26,
      fontWeight: FontWeight.w800,
      color: highlight ? AppColors.accent : AppColors.text,
      letterSpacing: -0.5,
    );
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: valueStyle),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
