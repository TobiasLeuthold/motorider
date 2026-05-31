import 'package:flutter/material.dart';

import '../services/nas_config.dart';
import '../services/nas_health.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pinging = false;
  NasPingResult? _lastResult;

  Future<void> _ping() async {
    setState(() {
      _pinging = true;
      _lastResult = null;
    });
    final res = await pingNas(NasConfig.defaultBaseUrl);
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _lastResult = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const _SectionTitle('NAS-Sync'),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Server',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    NasConfig.defaultBaseUrl,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 14,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _pinging ? null : _ping,
                        icon: _pinging
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.network_check_rounded),
                        label: Text(_pinging ? 'Pingt…' : 'NAS pingen'),
                      ),
                    ],
                  ),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 16),
                    _PingResultTile(result: _lastResult!),
                  ],
                ],
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
