import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../services/ride_tracker.dart';
import '../theme.dart';
import '../widgets/ride_polyline_map.dart';
import 'home_shell.dart';
import 'ride_detail_screen.dart';

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

class _HistoryView extends StatelessWidget {
  const _HistoryView();

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
              final rides = snap.data ?? const <Ride>[];
              if (rides.isEmpty) {
                return const _EmptyHistory();
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: rides.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _RideTile(ride: rides[i]),
              );
            },
          ),
        ),
      ],
    );
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
  const _RideTile({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final timeFmt = DateFormat('HH:mm');
    final durFmt = _formatDuration(ride.totalDuration);
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
