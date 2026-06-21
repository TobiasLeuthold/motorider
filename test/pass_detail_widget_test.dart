import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:motorider/screens/pass_detail_screen.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// Widget-level smoke tests for the Pässe Stage C detail screen. These build
/// the screen with a single frame (no pumpAndSettle, so no FlutterMap network
/// settle) and assert the key German facts/sections render. Passes here carry
/// NO geometry so the mini-map widget isn't constructed — the map is verified
/// visually; this guards the facts, profile and history layout headlessly.

Pass _pass({
  String name = 'Furkapass',
  int? ele = 2429,
  int? heightGainM = 870,
  double? lengthKm = 11.8,
  double? maxGradientPct = 11.0,
  int? hairpins = 22,
  double? curvinessScore = 240,
  List<String> cantons = const ['UR', 'VS'],
  List<String>? connects = const ['Realp', 'Gletsch'],
}) =>
    Pass(
      name: name,
      lat: 46.57,
      lon: 8.41,
      ele: ele,
      cantons: cantons,
      connects: connects,
      heightGainM: heightGainM,
      lengthKm: lengthKm,
      maxGradientPct: maxGradientPct,
      hairpins: hairpins,
      curvinessScore: curvinessScore,
      start: const PassPoint(lat: 46.60, lon: 8.49, ele: 1538),
      end: const PassPoint(lat: 46.56, lon: 8.36, ele: 1757),
      summitEle: ele,
      // No geometry → mini-map not built (keeps the test off the network).
    );

PassProgress _progress(
  Pass pass, {
  int count = 0,
  List<PassCrossing> crossings = const [],
}) =>
    PassProgress(
      pass: pass,
      count: count,
      firstDate: crossings.isEmpty ? null : crossings.first.at,
      lastDate: crossings.isEmpty ? null : crossings.last.at,
      rideIds: [for (final c in crossings) c.rideId],
      crossings: crossings,
    );

Future<void> _pumpDetail(WidgetTester tester, PassProgress p) async {
  // A tall viewport so the whole ListView (facts grid + history) lays out and
  // its children are actually built — otherwise lazy off-screen rows wouldn't
  // be found and the assertions would be vacuous.
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: PassDetailScreen(progress: p),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
  });

  testWidgets('uncrossed pass shows facts + "Noch nicht erkundet"',
      (tester) async {
    await _pumpDetail(tester, _progress(_pass()));

    // Name appears (app bar + header).
    expect(find.text('Furkapass'), findsWidgets);
    // Fact labels.
    expect(find.text('Höhe'), findsOneWidget);
    expect(find.text('Anstieg'), findsOneWidget);
    expect(find.text('Länge'), findsOneWidget);
    expect(find.text('Max. Steigung'), findsOneWidget);
    expect(find.text('Kehren'), findsOneWidget);
    expect(find.text('Kurvigkeit'), findsOneWidget);
    // Some fact values (de_CH formatting).
    expect(find.text('2’429 m'), findsOneWidget); // Höhe
    expect(find.text('22'), findsOneWidget); // Kehren
    // Connects chip.
    expect(find.textContaining('Realp'), findsWidgets);
    // History empty state.
    expect(find.text('Noch nicht erkundet'), findsWidgets);
  });

  testWidgets('crossed pass shows per-direction cards + history rows',
      (tester) async {
    final crossings = <PassCrossing>[
      PassCrossing(
        rideId: 'r1',
        at: DateTime(2026, 5, 10, 11),
        direction: PassDirection.startToEnd,
        directionLabel: 'Realp → Gletsch',
        avgSpeedKmh: 64,
        movingTimeS: 420, // 7:00
        durationS: 480,
      ),
      PassCrossing(
        rideId: 'r2',
        at: DateTime(2026, 6, 1, 14),
        direction: PassDirection.endToStart,
        directionLabel: 'Gletsch → Realp',
        avgSpeedKmh: 88,
        movingTimeS: 360, // 6:00
        durationS: 390,
      ),
    ];
    await _pumpDetail(tester, _progress(_pass(), count: 2, crossings: crossings));

    expect(find.text('Deine Überquerungen'), findsOneWidget);
    // Two per-direction cards, each with its own "Bestschnitt" figure.
    expect(find.text('Bestschnitt'), findsNWidgets(2));
    // Each direction label appears twice: card header + history row.
    expect(find.text('Realp → Gletsch'), findsNWidgets(2));
    expect(find.text('Gletsch → Realp'), findsNWidgets(2));
    // Fixed-distance best speeds (card big number + the row's facts line).
    expect(find.text('64 km/h'), findsWidgets);
    expect(find.text('88 km/h'), findsWidgets);
    // Moving time shows on the history rows (stops excluded).
    expect(find.textContaining('7:00'), findsWidgets);
    // Total moving time across both directions = 13:00.
    expect(find.textContaining('Gesamte Fahrzeit am Pass'), findsOneWidget);
    // Not the empty state.
    expect(find.text('Noch nicht erkundet'), findsNothing);
  });
}
