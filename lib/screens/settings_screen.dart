import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../services/nas_health.dart';
import '../services/sync_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _passwordCtrl;

  bool _pinging = false;
  bool _saving = false;
  bool _obscurePassword = true;
  NasPingResult? _pingResult;
  int _pendingCount = 0;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: nasSettings.baseUrl);
    _emailCtrl = TextEditingController(text: nasSettings.email ?? '');
    _passwordCtrl = TextEditingController(text: nasSettings.password ?? '');
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    final p = await fillUpRepo.getPendingForSync();
    if (!mounted) return;
    setState(() => _pendingCount = p.length);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    setState(() {
      _pinging = true;
      _pingResult = null;
    });
    // Ping against whatever is currently in the URL field, not the persisted
    // one — lets the user test a URL before saving it.
    final res = await pingNas(_urlCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _pingResult = res;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await nasSettings.setBaseUrl(_urlCtrl.text.trim());
    await nasSettings.setCredentials(
      email: _emailCtrl.text.trim(),
      password: _passwordCtrl.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Gespeichert')),
    );
  }

  Future<void> _syncNow() async {
    final res = await syncService.syncOnce();
    await _refreshPending();
    if (!mounted) return;
    final msg = res.ok
        ? 'Sync ok — ↑${res.pushed} hochgeladen, ↓${res.pulled} empfangen'
        : 'Sync fehlgeschlagen: ${res.error}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const _SectionTitle('NAS-Server'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Basis-URL',
                      hintText: 'http://…:8090',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscurePassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Passwort',
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: const Text('Speichern'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _pinging ? null : _ping,
                        icon: _pinging
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.accent,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded),
                        label: Text(_pinging ? 'Pingt…' : 'NAS pingen'),
                      ),
                    ],
                  ),
                  if (_pingResult != null) ...[
                    const SizedBox(height: 12),
                    _PingResultTile(result: _pingResult!),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Synchronisierung'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: StreamBuilder<SyncState>(
                stream: syncService.changes,
                initialData: syncService.state,
                builder: (context, snap) {
                  final state = snap.data ?? const SyncState.idle();
                  return _SyncSection(
                    state: state,
                    pendingCount: _pendingCount,
                    onSyncNow: state.running ? null : _syncNow,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _SyncSection extends StatelessWidget {
  const _SyncSection({
    required this.state,
    required this.pendingCount,
    required this.onSyncNow,
  });

  final SyncState state;
  final int pendingCount;
  final VoidCallback? onSyncNow;

  @override
  Widget build(BuildContext context) {
    final last = state.lastResult;
    final timeFmt = DateFormat('dd.MM.yyyy HH:mm');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statRow(
          'Ausstehend lokal',
          pendingCount == 0 ? 'alles synchronisiert' : '$pendingCount Einträge',
          warn: pendingCount > 0,
        ),
        const SizedBox(height: 6),
        _statRow(
          'Letzte Synchronisierung',
          last?.at == null
              ? 'noch nie'
              : '${timeFmt.format(last!.at!.toLocal())} '
                  '(${last.ok ? "↑${last.pushed} / ↓${last.pulled}" : "Fehler"})',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onSyncNow,
          icon: state.running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : const Icon(Icons.sync_rounded),
          label: Text(state.running ? 'Synchronisiert…' : 'Jetzt synchronisieren'),
        ),
        if (last != null && !last.ok) ...[
          const SizedBox(height: 12),
          _PingResultTile(
            result: NasPingResult.failure(error: last.error ?? 'Unbekannter Fehler'),
          ),
        ],
      ],
    );
  }

  Widget _statRow(String label, String value, {bool warn = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        Text(
          value,
          style: TextStyle(
            color: warn ? AppColors.accent : AppColors.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PingResultTile extends StatelessWidget {
  const _PingResultTile({required this.result});
  final NasPingResult result;

  @override
  Widget build(BuildContext context) {
    final ok = result.ok;
    final color = ok ? const Color(0xFF44D17A) : AppColors.danger;
    final icon = ok ? Icons.check_circle_rounded : Icons.error_rounded;
    final title = ok
        ? 'Erreichbar (${result.latency!.inMilliseconds} ms)'
        : 'Nicht erreichbar';
    final detail = ok ? (result.body ?? '') : (result.error ?? '');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
