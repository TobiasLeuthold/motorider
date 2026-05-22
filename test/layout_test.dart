// Renders each screen + suspected leaf widget in a real Material/Localized
// scaffold and asserts NO Flutter exception is thrown during layout/paint.
//
// Run with: flutter test test/layout_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motorider/models/fillup.dart';
import 'package:motorider/screens/add_fillup_screen.dart';
import 'package:motorider/screens/dashboard_screen.dart';
import 'package:motorider/screens/fuel_log_screen.dart';
import 'package:motorider/screens/home_shell.dart';
import 'package:motorider/stats/stats_calculator.dart';
import 'package:motorider/widgets/consumption_chart.dart';
import 'package:motorider/widgets/empty_state.dart';
import 'package:motorider/widgets/stat_card.dart';

Widget _appShell(Widget child, {Size size = const Size(411, 891)}) {
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 2.625),
    child: MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('de'), Locale('en')],
      locale: const Locale('de'),
      home: child,
    ),
  );
}

List<FillUp> _sampleFillUps() {
  final base = DateTime(2026, 4, 1, 9, 0);
  return [
    FillUp(date: base,                          odometerKm: 47,   liters: 0,    totalChf: 0,    notes: 'Startkilometer'),
    FillUp(date: base.add(const Duration(days: 3)),  odometerKm: 210,  liters: 10.0,  totalChf: 18.43),
    FillUp(date: base.add(const Duration(days: 7)),  odometerKm: 385,  liters: 9.56,  totalChf: 17.90),
    FillUp(date: base.add(const Duration(days: 13)), odometerKm: 685,  liters: 12.54, totalChf: 23.95),
    FillUp(date: base.add(const Duration(days: 18)), odometerKm: 946,  liters: 10.10, totalChf: 18.08),
    FillUp(date: base.add(const Duration(days: 22)), odometerKm: 1126, liters: 7.97,  totalChf: 14.11),
    FillUp(date: base.add(const Duration(days: 26)), odometerKm: 1317, liters: 9.01,  totalChf: 17.40),
    FillUp(date: base.add(const Duration(days: 31)), odometerKm: 1511, liters: 8.06,  totalChf: 16.11),
    FillUp(date: base.add(const Duration(days: 37)), odometerKm: 1730, liters: 9.14,  totalChf: 17.27),
    FillUp(date: base.add(const Duration(days: 43)), odometerKm: 1967, liters: 8.66,  totalChf: 15.24),
    FillUp(date: base.add(const Duration(days: 49)), odometerKm: 2223, liters: 9.61,  totalChf: 17.68),
  ];
}

void main() {
  setUpAll(() {
    debugSetAddFillUpUnderTest = true;
  });

  group('StatCard', () {
    testWidgets('fits in the dashboard grid cell (188x124)', (tester) async {
      await tester.pumpWidget(_appShell(
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 188,
              height: 124,
              child: StatCard(
                icon: Icons.speed_rounded,
                label: 'Ø Verbrauch',
                value: '5.42 L',
                sub: 'pro 100 km',
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with very long label & value still does not throw', (tester) async {
      await tester.pumpWidget(_appShell(
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 188,
              height: 124,
              child: StatCard(
                icon: Icons.event_rounded,
                label: 'Eine sehr lange Bezeichnung die nicht passt',
                value: 'CHF 12345.678901',
                sub: 'Mit einem ebenfalls langen Untertitel der überläuft',
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('ConsumptionChart', () {
    testWidgets('with 10 points renders without throwing', (tester) async {
      final series = [
        for (var i = 0; i < 10; i++)
          ConsumptionPoint(
            date: DateTime(2026, 4, 1).add(Duration(days: i * 5)),
            odometerKm: 200 + i * 250,
            lPer100Km: 4 + (i % 4) * 0.4,
            chfPerLiter: 1.80 + (i % 3) * 0.05,
          ),
      ];
      await tester.pumpWidget(_appShell(
        Scaffold(
          body: ConsumptionChart(points: series, metric: ChartMetric.lPer100Km),
        ),
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('EmptyState', () {
    testWidgets('with SVG illustration renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(
        const Scaffold(
          body: EmptyState(
            illustrationAsset: 'assets/illustrations/no_fillups.svg',
            title: 'Test',
            subtitle: 'Test subtitle line',
          ),
        ),
      ));
      // Pump enough frames to let SVG load (rootBundle is unavailable in tests
      // but fallback should not throw a layout exception).
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('DashboardScreen', () {
    testWidgets('empty state renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(
        DashboardScreen(stream: Stream.value(const <FillUp>[])),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with sample data renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(
        DashboardScreen(stream: Stream.value(_sampleFillUps())),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('FuelLogScreen', () {
    testWidgets('empty state renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(
        FuelLogScreen(stream: Stream.value(const <FillUp>[])),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with sample data renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(
        FuelLogScreen(stream: Stream.value(_sampleFillUps())),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('HomeShell', () {
    testWidgets('renders with all three tabs mounted at once', (tester) async {
      await tester.pumpWidget(_appShell(const HomeShell()));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching to Fuel Log tab does not throw', (tester) async {
      await tester.pumpWidget(_appShell(const HomeShell()));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Tankbuch'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching to Map tab does not throw', (tester) async {
      await tester.pumpWidget(_appShell(const HomeShell()));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Karte'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping FAB on Dashboard pushes Add screen without throwing',
        (tester) async {
      await tester.pumpWidget(_appShell(const HomeShell()));
      await tester.pump(const Duration(seconds: 1));
      // FAB is labeled "Tankfüllung". Tap it.
      await tester.tap(find.byType(FloatingActionButton).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'AddFillUpScreen must build cleanly after FAB tap');
      // Make sure the form actually appeared.
      expect(find.text('Neue Tankfüllung'), findsOneWidget);
    });

    testWidgets('FuelLog tab + FAB tap also clean', (tester) async {
      await tester.pumpWidget(_appShell(const HomeShell()));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Tankbuch'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(FloatingActionButton).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Neue Tankfüllung'), findsOneWidget);
    });
  });

  group('AddFillUpScreen', () {
    testWidgets('new-entry form renders without throwing', (tester) async {
      await tester.pumpWidget(_appShell(const AddFillUpScreen()));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing form renders without throwing', (tester) async {
      final existing = _sampleFillUps()[3];
      await tester.pumpWidget(_appShell(AddFillUpScreen(existing: existing)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  });
}
