import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import '../models/ride.dart';
import '../services/geo.dart' show cumulativeMeters;
import '../stats/pass_elevation_profile.dart';
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
class PassDetailScreen extends StatefulWidget {
  const PassDetailScreen({super.key, required this.progress});

  final PassProgress progress;

  @override
  State<PassDetailScreen> createState() => _PassDetailScreenState();
}

class _PassDetailScreenState extends State<PassDetailScreen> {
  Pass get pass => widget.progress.pass;

  /// Per-vertex elevations keyed by pass id, loaded once from the bundled asset.
  Map<String, List<double>>? _eleMap;

  /// Distance (km) along the pass the rider is scrubbing on the profile, mirrored
  /// as a moving marker on the segment map. Null when not scrubbing.
  double? _cursorKm;

  @override
  void initState() {
    super.initState();
    loadPassElevations().then((m) {
      if (mounted) setState(() => _eleMap = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final geom = pass.geometry;
    final hasGeom = geom.length >= 2;
    final cum = hasGeom ? cumulativeMeters(geom) : const <double>[];

    // Prefer the detailed per-vertex profile; fall back to the 3-anchor sketch
    // until/unless the elevation asset has a matching entry for this pass.
    final eles = _eleMap?[passElevationId(pass)];
    final detailed = (eles != null && hasGeom)
        ? detailedPassProfile(geom, eles)
        : const <PassElevationPoint>[];
    final points = detailed.length >= 2 ? detailed : passElevationProfile(pass);

    final cursor = (_cursorKm != null && hasGeom)
        ? pointAlongGeometry(geom, cum, _cursorKm! * 1000)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(pass.name),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Header(progress: widget.progress),
          const SizedBox(height: 4),
          if (hasGeom) ...[
            _SegmentMap(pass: pass, cursor: cursor),
            _Endpoints(pass: pass),
            const SizedBox(height: 4),
          ],
          PassElevationChart(
            pass: pass,
            points: points,
            cursorKm: _cursorKm,
            onScrub: hasGeom ? (km) => setState(() => _cursorKm = km) : null,
          ),
          _FactsGrid(pass: pass),
          const SizedBox(height: 8),
          _HistorySection(progress: widget.progress),
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
  const _SegmentMap({required this.pass, this.cursor});
  final Pass pass;

  /// Live position scrubbed on the height profile, drawn as a moving marker so
  /// the rider sees exactly where on the road that elevation sits. Null = none.
  final LatLng? cursor;

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
          width: 20,
          height: 20,
          child: const _FootMarker(isStart: true),
        ),
      if (endFoot != null)
        Marker(
          point: endFoot.latLng,
          width: 20,
          height: 20,
          child: const _FootMarker(isStart: false),
        ),
      // Scrub cursor: where the height-profile finger currently is. Drawn last
      // so it sits on top of the col/foot markers.
      if (widget.cursor != null)
        Marker(
          point: widget.cursor!,
          width: 24,
          height: 24,
          child: const _CursorMarker(),
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

/// Marker tracking the rider's finger on the height profile — a bright ringed
/// dot so it reads clearly as "this point on the road = this point on the curve".
class _CursorMarker extends StatelessWidget {
  const _CursorMarker();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.accent, width: 4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
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

/// A foot marker on the segment map: green "start" / red "end" so the rider can
/// see exactly where the timed foot-to-foot segment begins and ends.
class _FootMarker extends StatelessWidget {
  const _FootMarker({required this.isStart});
  final bool isStart;
  @override
  Widget build(BuildContext context) {
    final color =
        isStart ? const Color(0xFF34D399) : const Color(0xFFE0352B);
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 4),
        ],
      ),
      child: Icon(
        isStart ? Icons.play_arrow_rounded : Icons.flag_rounded,
        size: 12,
        color: Colors.white,
      ),
    );
  }
}

/// Caption under the segment map naming exactly where the timed segment starts
/// and ends — the two feet, with place + elevation — so the rider sees what the
/// times and speeds are measured over.
class _Endpoints extends StatelessWidget {
  const _Endpoints({required this.pass});
  final Pass pass;

  @override
  Widget build(BuildContext context) {
    final start = passFootLabel(pass, isStart: true);
    final end = passFootLabel(pass, isStart: false);
    if (start == null && end == null) return const SizedBox.shrink();

    Widget chip(IconData icon, Color color, String? text) => Expanded(
          child: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  text ?? '–',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
      child: Row(
        children: [
          chip(Icons.play_arrow_rounded, const Color(0xFF34D399), start),
          const SizedBox(width: 8),
          chip(Icons.flag_rounded, const Color(0xFFE0352B), end),
        ],
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
            _DirectionSummary(progress: progress),
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

/// Per-direction roll-up: one card for each way the pass has been ridden (the
/// two ascents differ, so they're kept apart), each with its fastest fixed-
/// distance average and a count/best-time/Ø line, plus the total moving time.
class _DirectionSummary extends StatelessWidget {
  const _DirectionSummary({required this.progress});
  final PassProgress progress;

  @override
  Widget build(BuildContext context) {
    final dirs = progress.directions;
    // Crossed (hysteresis) but no clean foot-to-foot traversal to time yet.
    if (dirs.isEmpty) return const SizedBox.shrink();
    final total = progress.totalTimeOnPassS;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < dirs.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _DirectionCard(stats: dirs[i]),
        ],
        if (total > 0) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.timer_outlined,
                  size: 15, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Text(
                'Gesamte Fahrzeit am Pass: ${formatPassDuration(total)}',
                style:
                    const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DirectionCard extends StatelessWidget {
  const _DirectionCard({required this.stats});
  final DirectionStats stats;

  @override
  Widget build(BuildContext context) {
    final d = stats;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.arrow_forward_rounded,
                        size: 15, color: AppColors.accentSoft),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        d.label ?? 'Überquerung',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  directionStatLine(d),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatSpeedKmh(d.bestSpeedKmh),
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: AppColors.accent,
                  letterSpacing: -0.5,
                ),
              ),
              const Text('Bestschnitt',
                  style: TextStyle(fontSize: 10, color: AppColors.textMuted)),
            ],
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
    final dur = formatPassDuration(c.movingTimeS); // moving time, stops excluded
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
