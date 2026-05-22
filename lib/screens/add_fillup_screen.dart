import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models/fillup.dart';
import '../services/location_service.dart';
import '../theme.dart';

class AddFillUpScreen extends StatefulWidget {
  const AddFillUpScreen({super.key, this.existing});

  final FillUp? existing;

  @override
  State<AddFillUpScreen> createState() => _AddFillUpScreenState();
}

/// Set true from widget tests to skip platform-channel side effects
/// (location auto-capture) so the screen layout can be exercised in isolation.
bool _isUnderTest = false;
// ignore: avoid_setters_without_getters
set debugSetAddFillUpUnderTest(bool v) => _isUnderTest = v;

class _AddFillUpScreenState extends State<AddFillUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _odoCtrl = TextEditingController();
  final _litersCtrl = TextEditingController();
  final _chfCtrl = TextEditingController();
  final _stationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late DateTime _when;
  double? _lat;
  double? _lon;
  bool _fullTank = true;
  bool _saving = false;
  bool _locating = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _when = e.date;
      _odoCtrl.text = e.odometerKm.toString();
      _litersCtrl.text = e.liters.toStringAsFixed(2);
      _chfCtrl.text = e.totalChf.toStringAsFixed(2);
      _stationCtrl.text = e.station ?? '';
      _notesCtrl.text = e.notes ?? '';
      _lat = e.latitude;
      _lon = e.longitude;
      _fullTank = e.fullTank;
    } else {
      _when = DateTime.now();
      // Try to auto-capture current location for new entries.
      // Skipped in widget tests (geolocator platform channels not available).
      if (!_isUnderTest) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _captureLocation(silent: true),
        );
      }
    }
    _litersCtrl.addListener(() => setState(() {}));
    _chfCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _odoCtrl.dispose();
    _litersCtrl.dispose();
    _chfCtrl.dispose();
    _stationCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  double? get _pricePerLiter {
    final l = double.tryParse(_litersCtrl.text.replaceAll(',', '.'));
    final c = double.tryParse(_chfCtrl.text.replaceAll(',', '.'));
    if (l == null || c == null || l <= 0) return null;
    return c / l;
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('EEEE, dd.MM.yyyy', 'de');
    final timeFmt = DateFormat('HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Tankfüllung bearbeiten' : 'Neue Tankfüllung'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Löschen',
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
              onPressed: _saving ? null : _confirmDelete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            _SectionLabel('Wann?'),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _PickerTile(
                    icon: Icons.calendar_today_rounded,
                    label: dateFmt.format(_when),
                    onTap: _pickDate,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _PickerTile(
                    icon: Icons.schedule_rounded,
                    label: timeFmt.format(_when),
                    onTap: _pickTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _SectionLabel('Tankung'),
            TextFormField(
              controller: _odoCtrl,
              keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Kilometerstand',
                suffixText: 'km',
                prefixIcon: Icon(Icons.speed_rounded, color: AppColors.textMuted),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Bitte eintragen';
                final n = int.tryParse(v);
                if (n == null || n < 0) return 'Ungültige Zahl';
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _litersCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_DecimalFmt()],
                    decoration: const InputDecoration(
                      labelText: 'Liter',
                      suffixText: 'L',
                      prefixIcon: Icon(Icons.water_drop_rounded, color: AppColors.textMuted),
                    ),
                    validator: _positiveDoubleValidator,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _chfCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_DecimalFmt()],
                    decoration: const InputDecoration(
                      labelText: 'Total',
                      prefixText: 'CHF  ',
                      prefixIcon: Icon(Icons.payments_rounded, color: AppColors.textMuted),
                    ),
                    validator: _positiveDoubleValidator,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _PricePreview(pricePerLiter: _pricePerLiter),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              activeTrackColor: AppColors.accent,
              value: _fullTank,
              onChanged: (v) => setState(() => _fullTank = v),
              title: const Text(
                'Vollgetankt',
                style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.text),
              ),
              subtitle: const Text(
                'Für genaue Verbrauchsberechnung',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            _SectionLabel('Ort'),
            _LocationTile(
              lat: _lat,
              lon: _lon,
              locating: _locating,
              onCapture: () => _captureLocation(),
              onClear: () => setState(() {
                _lat = null;
                _lon = null;
              }),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _stationCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Tankstelle (optional)',
                prefixIcon: Icon(Icons.local_gas_station_rounded, color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notiz (optional)',
                alignLabelWithHint: true,
                prefixIcon: Padding(
                  padding: EdgeInsets.only(bottom: 36),
                  child: Icon(Icons.notes_rounded, color: AppColors.textMuted),
                ),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(_editing ? 'Änderungen speichern' : 'Tankfüllung speichern'),
            ),
          ],
        ),
      ),
    );
  }

  String? _positiveDoubleValidator(String? v) {
    if (v == null || v.trim().isEmpty) return 'Bitte eintragen';
    final n = double.tryParse(v.replaceAll(',', '.'));
    if (n == null || n <= 0) return 'Ungültig';
    return null;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      locale: const Locale('de', 'CH'),
    );
    if (picked != null) {
      setState(() {
        _when = DateTime(picked.year, picked.month, picked.day, _when.hour, _when.minute);
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _when = DateTime(_when.year, _when.month, _when.day, picked.hour, picked.minute);
      });
    }
  }

  Future<void> _captureLocation({bool silent = false}) async {
    setState(() => _locating = true);
    final res = await LocationService.getCurrent();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (res.position != null) {
        _lat = res.position!.latitude;
        _lon = res.position!.longitude;
      }
    });
    if (!silent && res.position == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.error ?? 'Standort nicht verfügbar')),
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final f = FillUp(
      id: widget.existing?.id,
      date: _when,
      odometerKm: int.parse(_odoCtrl.text),
      liters: double.parse(_litersCtrl.text.replaceAll(',', '.')),
      totalChf: double.parse(_chfCtrl.text.replaceAll(',', '.')),
      latitude: _lat,
      longitude: _lon,
      station: _stationCtrl.text.trim().isEmpty ? null : _stationCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      fullTank: _fullTank,
    );
    try {
      await fillUpRepo.upsert(f);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler beim Speichern: $e')),
      );
    }
  }

  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eintrag löschen?'),
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
    setState(() => _saving = true);
    await fillUpRepo.delete(widget.existing!.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.gridLine),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: AppColors.textMuted),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PricePreview extends StatelessWidget {
  const _PricePreview({required this.pricePerLiter});
  final double? pricePerLiter;
  @override
  Widget build(BuildContext context) {
    final shown = pricePerLiter != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: shown ? 0.14 : 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: shown ? 0.45 : 0.18),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.calculate_rounded, color: AppColors.accent),
          const SizedBox(width: 10),
          Text(
            'Preis pro Liter',
            style: const TextStyle(
              color: AppColors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            shown ? 'CHF ${pricePerLiter!.toStringAsFixed(3)}' : '–',
            style: const TextStyle(
              color: AppColors.accent,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    required this.lat,
    required this.lon,
    required this.locating,
    required this.onCapture,
    required this.onClear,
  });
  final double? lat;
  final double? lon;
  final bool locating;
  final VoidCallback onCapture;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final has = lat != null && lon != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.gridLine),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            has ? Icons.place_rounded : Icons.location_searching_rounded,
            color: has ? AppColors.accent : AppColors.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  has ? 'Standort erfasst' : 'Kein Standort',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                Text(
                  has
                      ? '${lat!.toStringAsFixed(5)}, ${lon!.toStringAsFixed(5)}'
                      : 'Aktuellen Standort verwenden',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          if (has)
            IconButton(
              tooltip: 'Entfernen',
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
              onPressed: onClear,
            ),
          IconButton(
            tooltip: 'Standort holen',
            onPressed: locating ? null : onCapture,
            icon: locating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.accent,
                    ),
                  )
                : const Icon(Icons.my_location_rounded, color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

/// Allows only digits and a single decimal separator (`.` or `,`).
class _DecimalFmt extends TextInputFormatter {
  static final _re = RegExp(r'^\d{0,6}([.,]\d{0,3})?$');
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue n) {
    return _re.hasMatch(n.text) ? n : old;
  }
}
