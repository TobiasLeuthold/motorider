import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../stats/pass_explorer.dart';
import '../stats/pass_summary.dart';
import '../theme.dart';
import '../widgets/pass_elevation_chart.dart';
import 'ride_detail_screen.dart';

/// Rich detail view for a single Swiss pass: its facts (elevation, climb,
/// length, gradient, hairpins, curviness), a mini map of the road segment
/// (col + both feet marked, the geometry polyline drawn), and the rider's
/// personal crossing history — each crossing's date, direction, Ø speed and
/// duration, plus best/mean/count, deep-linking into the originating ride.
///
/// Opened from the Pässe list, the "Meine Pässe" overview and the map's pass
/// tap-sheet. Renders entirely from a [PassProgress] (already computed by the
/// exploration loader), so it needs no async work of its own.
class PassDetailScreen extends StatelessWidget {
  const PassDetailScreen({super.key, required this.progress});

  final PassProgress progress;

  Pass get pass => progress.pass;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pass.name),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Header(progress: progress),
          const SizedBox(height: 4),
          if (pass.geometry.length >= 2) ...[
            _SegmentMap(pass: pass),
            const SizedBox(height: 4),
          ],
          PassElevationChart(pass: pass),
          _FactsGrid(pass: pass),
          const SizedBox(height: 8),
          _HistorySection(progress: progress),
        ],
      ),
    );
  }
}

// ───────────────────────────── Header ─────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.progress});
  final PassProgress progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.pass;
    final crossed = progress.crossed;
    final color = crossed ? AppColors.accent : AppColors.textMuted;
    final connects =
        (p.connects != null && p.connects!.length == 2) ? p.connects! : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
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
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color, width: 2),
                ),
                child: Icon(
                  crossed ? Icons.terrain_rounded : Icons.landscape_rounded,
                  color: AppColors.text,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passHistorySummary(progress),
                      style: TextStyle(fontSize: 13, color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in p.cantons)
                _Chip(icon: Icons.flag_rounded, label: c),
              if (connects != null)
                _Chip(
                  icon: Icons.swap_horiz_rounded,
                  label: '${connects[0]} ↔ ${connects[1]}',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.accentSoft),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Segment mini-map ───────────────────────────

/// A small, non-interactive map of the pass road segment: the [Pass.geometry]
/// polyline with the col and both feet marked, fitted to the segment bounds so
/// the road's shape (the serpentines!) is visible at a glance.
class _SegmentMap extends StatefulWidget {
  const _SegmentMap({required this.pass});
  final Pass pass;

  @override
  State<_SegmentMap> createState() => _SegmentMapState();
}

class _SegmentMapState extends State<_SegmentMap> {
  final _ctrl = MapController();
  bool _didFit = false;

  void _fit() {
    final geom = widget.pass.geometry;
    if (geom.length < 2) return;
    _ctrl.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(geom),
        padding: const EdgeInsets.all(34),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pass;
    final geom = p.geometry;
    final startFoot = p.start;
    final endFoot = p.end;
    final markers = <Marker>[
      Marker(
        point: p.latLng,
        width: 30,
        height: 30,
        child: const _ColMarker(),
      ),
      if (startFoot != null)
        Marker(
          point: startFoot.latLng,
          width: 16,
          height: 16,
          child: const _FootDot(),
        ),
      if (endFoot != null)
        Marker(
          point: endFoot.latLng,
          width: 16,
          height: 16,
          child: const _FootDot(),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: 220,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _ctrl,
                options: MapOptions(
                  initialCenter: p.latLng,
                  initialZoom: 12,
                  minZoom: 6,
                  maxZoom: 17,
                  // A glanceable thumbnail, not a navigable map: keep gestures
                  // off so scrolling the detail page doesn't pan it.
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                  ),
                  onMapReady: () {
                    if (!_didFit) {
                      _didFit = true;
                      _fit();
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ch.tleuthold.motorider',
                    maxNativeZoom: 19,
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: geom,
                        strokeWidth: 5,
                        color: AppColors.accent,
                        borderStrokeWidth: 1.5,
                        borderColor: Colors.black.withValues(alpha: 0.4),
                      ),
                    ],
                  ),
                  MarkerLayer(markers: markers),
                  const RichAttributionWidget(
                    alignment: AttributionAlignment.bottomLeft,
                    showFlutterMapAttribution: false,
                    attributions: [TextSourceAttribution('© OpenStreetMap')],
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

class _ColMarker extends StatelessWidget {
  const _ColMarker();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.terrain_rounded, size: 17, color: AppColors.bg),
    );
  }
}

class _FootDot extends StatelessWidget {
  const _FootDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }
}

// ─────────────────────────── Facts grid ───────────────────────────

class _FactsGrid extends StatelessWidget {
  const _FactsGrid({required this.pass});
  final Pass pass;

  @override
  Widget build(BuildContext context) {
    final tiles = passFactTiles(pass);
    // Pair an icon to each fact (same order as passFactTiles).
    const icons = [
      Icons.height_rounded, // Höhe
      Icons.trending_up_rounded, // Anstieg
      Icons.straighten_rounded, // Länge
      Icons.show_chart_rounded, // Max. Steigung
      Icons.u_turn_right_rounded, // Kehren
      Icons.moving_rounded, // Kurvigkeit
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.96,
        children: [
          for (var i = 0; i < tiles.length; i++)
            _FactTile(
              icon: icons[i],
              label: tiles[i].label,
              value: tiles[i].value,
            ),
        ],
      ),
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 18, color: AppColors.accentSoft),
          const Spacer(),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── History section ───────────────────────────

class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.progress});
  final PassProgress progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded,
                  size: 18, color: AppColors.text),
              const SizedBox(width: 8),
              const Text(
                'Deine Überquerungen',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                ),
              ),
              const Spacer(),
              if (progress.crossed)
                Text(
                  '${progress.count}×',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.accent,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!progress.crossed)
            const _NotExplored()
          else ...[
            _SpeedSummary(progress: progress),
            const SizedBox(height: 12),
            for (var i = 0; i < progress.crossings.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _CrossingRow(crossing: progress.crossings[i]),
            ],
            if (progress.crossings.isEmpty)
              // Counted as crossed (hysteresis) but no corridor could be
              // measured — still tell the rider it happened.
              Text(
                progress.lastDate != null
                    ? 'Überquert am ${DateFormat('dd.MM.yyyy').format(progress.lastDate!)} '
                        '(keine Detaildaten).'
                    : 'Überquert (keine Detaildaten).',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textMuted),
              ),
          ],
        ],
      ),
    );
  }
}

class _NotExplored extends StatelessWidget {
  const _NotExplored();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.surfaceHi,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.lock_outline_rounded,
                color: AppColors.textMuted, size: 24),
          ),
          const SizedBox(height: 12),
          const Text(
            'Noch nicht erkundet',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Fahr diesen Pass und er erscheint hier in Gold – mit Datum, '
            'Richtung und Tempo jeder Überquerung.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Best / mean / total-time roll-up across all measured crossings.
class _SpeedSummary extends StatelessWidget {
  const _SpeedSummary({required this.progress});
  final PassProgress progress;

  @override
  Widget build(BuildContext context) {
    final best = progress.bestSpeedKmh;
    final mean = progress.meanSpeedKmh;
    final total = progress.totalTimeOnPassS;
    return Row(
      children: [
        Expanded(
          child: _SummaryTile(
            icon: Icons.bolt_rounded,
            label: 'Bestschnitt',
            value: formatSpeedKmh(best),
            tint: AppColors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            icon: Icons.speed_rounded,
            label: 'Ø Schnitt',
            value: formatSpeedKmh(mean),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            icon: Icons.timer_outlined,
            label: 'Zeit am Pass',
            value: formatPassDuration(total),
          ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.icon,
    required this.label,
    required this.value,
    this.tint,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? AppColors.accentSoft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
              letterSpacing: -0.3,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// One crossing row: date, direction label, Ø speed + duration, tappable into
/// the originating ride's detail.
class _CrossingRow extends StatelessWidget {
  const _CrossingRow({required this.crossing});
  final PassCrossing crossing;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    final c = crossing;
    final dir = c.directionLabel;
    final speed = formatSpeedKmh(c.avgSpeedKmh);
    final dur = formatPassDuration(c.durationS);
    final facts = <String>[
      if (speed != '–') speed,
      if (dur != '–') dur,
    ].join(' · ');

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openRide(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border:
                Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.route_rounded,
                    size: 19, color: AppColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          dateFmt.format(c.at),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                          ),
                        ),
                        if (dir != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              dir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: AppColors.accentSoft,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (facts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        facts,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
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

  void _openRide(BuildContext context) {
    // Guard: only navigate if the ride still exists in the repo.
    final exists = rideRepo.latest.any((Ride r) => r.id == crossing.rideId);
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fahrt nicht gefunden.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RideDetailScreen(rideId: crossing.rideId),
      ),
    );
  }
}
