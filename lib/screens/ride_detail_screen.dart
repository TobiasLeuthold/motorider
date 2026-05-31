import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/ride.dart';
import '../models/ride_point.dart';
import '../theme.dart';
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
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  bool _loading = true;

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
    if (!mounted) return;
    setState(() {
      _ride = r;
      _points = pts;
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
                          ? RidePolylineMap(points: _points)
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
                      child: _StatsGrid(ride: r),
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
  const _StatsGrid({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final r = ride;
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
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
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
