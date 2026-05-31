import 'package:flutter/material.dart';

import '../theme.dart';
import 'dashboard_screen.dart';
import 'fuel_log_screen.dart';
import 'map_screen.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = const [
      DashboardScreen(),
      FuelLogScreen(),
      MapScreen(),
    ];
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(index: _index, children: pages),
          // Settings affordance sits above each tab's custom header. Padding
          // matches TabHeader's top inset so it lines up with the header text.
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 44, right: 8),
                child: IconButton(
                  tooltip: 'Einstellungen',
                  icon: const Icon(
                    Icons.settings_rounded,
                    color: AppColors.textMuted,
                  ),
                  onPressed: _openSettings,
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_rounded),
            label: 'Übersicht',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_gas_station_rounded),
            label: 'Tankbuch',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_rounded),
            label: 'Karte',
          ),
        ],
      ),
    );
  }
}

/// Reusable accent gradient header used at the top of full-screen tabs.
class TabHeader extends StatelessWidget {
  const TabHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
              letterSpacing: -0.6,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
