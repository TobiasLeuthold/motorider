import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../services/weather_service.dart';
import '../stats/ride_detail_stats.dart';
import '../theme.dart';
import '../widgets/ride_charts.dart';
import '../widgets/ride_polyline_map.dart';

/// Detail view for a single saved ride: map polyline, stat grid, editable
/// title/notes, delete.
class RideDetailScreen extends StatefulWidget {
  const RideDetailScreen({super.key, required this.rideId});
  final String rideId;

  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen> {
  Ride? _ride;
  List<RidePoint> _points = const [];
  RideDetailStats? _detail;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  bool _loading = true;
  bool _fetchingWeather = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final r = await rideRepo.getById(widget.rideId);
    final pts = await rideRepo.getPoints(widget.rideId);
    final detail = pts.length >= 2 ? computeDetailStats(pts) : null;
    if (!mounted) return;
    setState(() {
      _ride = r;
      _points = pts;
      _detail = detail;
      _titleCtrl.text = r?.title ?? '';
      _notesCtrl.text = r?.notes ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final r = _ride;
    if (r == null) return;
    final updated = r.copyWith(
      title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );
    await rideRepo.upsert(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Gespeichert')),
    );
    setState(() => _ride = updated);
  }

  Future<void> _fetchWeather() async {
    setState(() => _fetchingWeather = true);
    final ok = await WeatherService.enrichRide(
      repo: rideRepo,
      rideId: widget.rideId,
    );
    if (!mounted) return;
    if (ok) {
      // Reload to surface the new weather card.
      await _load();
      if (!mounted) return;
      setState(() => _fetchingWeather = false);
    } else {
      setState(() => _fetchingWeather = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wetter konnte nicht abgerufen werden (offline oder kein Treffer im Zeitfenster).',
          ),
        ),
      );
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tour löschen?'),
        content: const Text('Diese Aktion kann nicht rückgängig gemacht werden.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await rideRepo.delete(widget.rideId);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String _elevationSubtitle(Ride r, RideDetailStats d) {
    final parts = <String>[];
    if (d.minAltitudeM != null && d.maxAltitudeM != null) {
      parts.add('${d.minAltitudeM!.toStringAsFixed(0)}–'
          '${d.maxAltitudeM!.toStringAsFixed(0)} m ü. M.');
    }
    if (r.elevationGainM != null) {
      parts.add('↑ ${r.elevationGainM!.toStringAsFixed(0)} m');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final r = _ride;
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(
        title: Text(r == null ? 'Tour' : dateFmt.format(r.startedAt.toLocal())),
        actions: [
          IconButton(
            tooltip: 'Löschen',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: r == null ? null : _delete,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : r == null
              ? const Center(child: Text('Tour nicht gefunden.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                  children: [
                    SizedBox(
                      height: 280,
                      child: _points.length >= 2
                          ? RidePolylineMap(
                              points: _points,
                              colorBySpeed: true,
                              enableFullscreen: true,
                            )
                          : Container(
                              color: AppColors.surface,
                              alignment: Alignment.center,
                              child: const Text(
                                'Keine GPS-Punkte für diese Tour',
                                style: TextStyle(color: AppColors.textMuted),
                              ),
                            ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _StatsGrid(ride: r, detail: _detail),
                    ),
                    if (_detail != null &&
                        _detail!.speedSeries.length >= 2) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _ChartCard(
                          title: 'Geschwindigkeit',
                          subtitle: 'km/h über die Fahrzeit · '
                              'Ø ${r.avgMovingSpeedKmh.toStringAsFixed(0)} km/h gestrichelt',
                          child: RideSpeedChart(
                            series: _detail!.speedSeries,
                            avgKmh: r.avgMovingSpeedKmh,
                          ),
                        ),
                      ),
                    ],
                    if (_detail != null &&
                        _detail!.elevationSeries.length >= 2) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _ChartCard(
                          title: 'Höhenprofil',
                          subtitle: _elevationSubtitle(r, _detail!),
                          child:
                              RideElevationChart(series: _detail!.elevationSeries),
                        ),
                      ),
                    ],
                    if (_detail != null && _detail!.speedBands.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _DynamicsCard(detail: _detail!),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: r.hasWeather
                          ? _WeatherCard(ride: r)
                          : _WeatherPlaceholder(
                              loading: _fetchingWeather,
                              onFetch: _points.isEmpty ? null : _fetchWeather,
                            ),
                    ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _titleCtrl,
                            decoration: const InputDecoration(labelText: 'Titel'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _notesCtrl,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Notizen',
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _save,
                            icon: const Icon(Icons.save_rounded),
                            label: const Text('Speichern'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.ride, this.detail});
  final Ride ride;
  final RideDetailStats? detail;

  @override
  Widget build(BuildContext context) {
    final r = ride;
    final d = detail;
    final standzeit = r.totalDuration - r.movingDuration;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Stat(
                label: 'Distanz',
                value: '${r.distanceKm.toStringAsFixed(1)} km',
              ),
              _Stat(
                label: 'Gesamtzeit',
                value: _fmt(r.totalDuration),
              ),
              _Stat(
                label: 'Fahrzeit',
                value: _fmt(r.movingDuration),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Stat(
                label: 'Max',
                value: '${r.maxSpeedKmh.toStringAsFixed(0)} km/h',
              ),
              _Stat(
                label: 'Ø Fahrt',
                value: '${r.avgMovingSpeedKmh.toStringAsFixed(0)} km/h',
              ),
              _Stat(
                label: 'Höhenmeter',
                value: r.elevationGainM == null
                    ? '–'
                    : '${r.elevationGainM!.toStringAsFixed(0)} m',
              ),
            ],
          ),
          if (d != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _Stat(
                  label: 'Schnellster km',
                  value: d.fastestKmKmh == null
                      ? '–'
                      : '${d.fastestKmKmh!.toStringAsFixed(0)} km/h',
                ),
                _Stat(
                  label: 'Stopps',
                  value: '${d.stopsCount}',
                ),
                _Stat(
                  label: 'Standzeit',
                  value: standzeit.inSeconds <= 0 ? '–' : _fmt(standzeit),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m == 0) return '${d.inSeconds}s';
    return '${m}m';
  }
}

/// Shared shell for the chart cards: title + optional subtitle + content.
class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.child,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _DynamicsCard extends StatelessWidget {
  const _DynamicsCard({required this.detail});
  final RideDetailStats detail;

  @override
  Widget build(BuildContext context) {
    final left = detail.maxLeanLeftDeg;
    final right = detail.maxLeanRightDeg;
    final hasLean = left != null && right != null;
    return _ChartCard(
      title: 'Fahrdynamik',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasLean) ...[
            const Text(
              'Max. Schräglage (geschätzt)',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _LeanTile(
                    icon: Icons.turn_left_rounded,
                    side: 'Links',
                    deg: left,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _LeanTile(
                    icon: Icons.turn_right_rounded,
                    side: 'Rechts',
                    deg: right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          const Text(
            'Tempo-Verteilung (Fahrzeit)',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SpeedBandBar(bands: detail.speedBands),
        ],
      ),
    );
  }
}

/// One side's estimated maximum lean angle.
class _LeanTile extends StatelessWidget {
  const _LeanTile({required this.icon, required this.side, required this.deg});
  final IconData icon;
  final String side;
  final double deg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.accentSoft, size: 24),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${deg.round()}°',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                side,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeatherPlaceholder extends StatelessWidget {
  const _WeatherPlaceholder({required this.loading, required this.onFetch});
  final bool loading;
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded,
              color: AppColors.textMuted, size: 22),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Kein Wetter abgerufen',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: loading ? null : onFetch,
            icon: loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                : const Icon(Icons.refresh_rounded, size: 16),
            label: Text(loading ? 'Lädt…' : 'Wetter abrufen'),
          ),
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final code = ride.weatherCode ?? 0;
    final icon = WeatherService.iconForCode(code);
    final label = WeatherService.labelForCode(code);

    final tempLine = _tempLine(ride);
    final precip = ride.precipitationMm ?? 0;
    final wind = ride.windMaxKmh;

    return Container(
      padding: const EdgeInsets.all(14),
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppColors.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (tempLine != null)
                      Text(
                        tempLine,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (precip > 0 || wind != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (precip > 0)
                  _Pill(
                    icon: Icons.water_drop_rounded,
                    label: '${precip.toStringAsFixed(1)} mm',
                  ),
                if (precip > 0 && wind != null) const SizedBox(width: 8),
                if (wind != null)
                  _Pill(
                    icon: Icons.air_rounded,
                    label: 'bis ${wind.toStringAsFixed(0)} km/h',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String? _tempLine(Ride r) {
    final min = r.tempMinC;
    final max = r.tempMaxC;
    final avg = r.tempAvgC;
    if (min == null && max == null && avg == null) return null;
    if (min != null && max != null && (max - min).abs() >= 1) {
      return '${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} °C'
          '${avg != null ? ' · Ø ${avg.toStringAsFixed(0)} °C' : ''}';
    }
    final shown = avg ?? max ?? min!;
    return '${shown.toStringAsFixed(0)} °C';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.gridLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textMuted, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
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
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
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
