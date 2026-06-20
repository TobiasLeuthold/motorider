import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/main.dart' show rideRepo;
import 'package:motorider/screens/passes_screen.dart';
import 'package:motorider/stats/pass_exploration_loader.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// Widget test for the "Meine Pässe" overview (Stage C centrepiece). A fake
/// loader feeds a canned exploration result with crossings, so the populated
/// dopamine view renders headlessly (the emulator has no crossings). Pumps a
/// single frame and toggles to "Meine Pässe", asserting the reward stats show.

/// A loader that returns a pre-baked result instead of touching the database.
class _FakeLoader extends PassExplorationLoader {
  _FakeLoader(this.result) : super(rideRepo);
  final PassExplorationResult result;
  @override
  Future<PassExplorationResult> compute() async => result;
}

Pass _seg(String name, LatLng col, {int ele = 2000, List<String> cantons = const ['UR'], int hairpins = 10}) =>
    Pass(
      name: name,
      lat: col.latitude,
      lon: col.longitude,
      ele: ele,
      cantons: cantons,
      hairpins: hairpins,
      start: PassPoint(lat: col.latitude - 0.03, lon: col.longitude),
      end: PassPoint(lat: col.latitude + 0.03, lon: col.longitude),
      geometry: [
        LatLng(col.latitude - 0.03, col.longitude),
        col,
        LatLng(col.latitude + 0.03, col.longitude),
      ],
    );

PassExplorationResult _result() {
  final furka = _seg('Furkapass', const LatLng(46.57, 8.41),
      ele: 2429, cantons: const ['UR', 'VS'], hairpins: 22);
  final susten = _seg('Sustenpass', const LatLng(46.73, 8.45),
      ele: 2224, cantons: const ['BE', 'UR'], hairpins: 18);
  final nufenen = _seg('Nufenenpass', const LatLng(46.48, 8.39),
      ele: 2478, cantons: const ['VS', 'TI'], hairpins: 14);

  PassCrossing c(String ride, DateTime at, double kmh, int dur) => PassCrossing(
        rideId: ride,
        at: at,
        direction: PassDirection.startToEnd,
        directionLabel: '↑',
        avgSpeedKmh: kmh,
        durationS: dur,
      );

  final progress = <PassProgress>[
    PassProgress(
      pass: furka,
      count: 3,
      firstDate: DateTime(2026, 5, 1),
      lastDate: DateTime(2026, 6, 1),
      rideIds: const ['r1', 'r2', 'r3'],
      crossings: [
        c('r1', DateTime(2026, 5, 1), 70, 400),
        c('r2', DateTime(2026, 5, 15), 92, 360), // fastest overall
        c('r3', DateTime(2026, 6, 1), 80, 380),
      ],
    ),
    PassProgress(
      pass: susten,
      count: 1,
      firstDate: DateTime(2026, 5, 20),
      lastDate: DateTime(2026, 5, 20),
      rideIds: const ['r4'],
      crossings: [c('r4', DateTime(2026, 5, 20), 60, 500)],
    ),
    PassProgress(
      pass: nufenen,
      count: 0,
      firstDate: null,
      lastDate: null,
      rideIds: const [],
    ),
  ];

  final stats = CollectionStats(
    total: 3,
    explored: 2,
    metresCollected: 2429 + 2224,
    totalHairpins: 22 + 18,
    highestCrossed: progress[0], // Furka 2429 is highest crossed
    highestUncrossed: progress[2], // Nufenen uncrossed
    mostCrossed: progress[0], // Furka 3×
    perCanton: const {
      'UR': CantonProgress(2, 3),
      'VS': CantonProgress(1, 2),
      'BE': CantonProgress(1, 1),
      'TI': CantonProgress(0, 1),
    },
    fastestCrossing: FastestCrossing(
      pass: furka,
      avgSpeedKmh: 92,
      at: DateTime(2026, 5, 15),
      rideId: 'r2',
    ),
    totalTimeOnPassesS: 400 + 360 + 380 + 500,
  );

  return PassExplorationResult(progress: progress, stats: stats);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
  });

  testWidgets('Meine Pässe view shows the reward stats', (tester) async {
    // Tall viewport so the whole sliver list (down to the canton board) builds.
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: PassesScreen(loader: _FakeLoader(_result()))),
    );
    // Resolve the (immediate) future + first build.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Headline progress (2 / 3).
    expect(find.text('2'), findsWidgets);
    expect(find.text(' / 3 Pässe'), findsOneWidget);

    // Switch to the "Meine Pässe" tab.
    await tester.tap(find.text('Meine Pässe'));
    await tester.pump(const Duration(milliseconds: 50));

    // Trophy banner.
    expect(find.text('Schnellste Passüberquerung'), findsOneWidget);
    expect(find.text('92'), findsWidgets); // km/h hero number
    // Dopamine stat labels.
    expect(find.text('Höhenmeter gesammelt'), findsOneWidget);
    expect(find.text('Kehren gefahren'), findsOneWidget);
    expect(find.text('Zeit auf Pässen'), findsOneWidget);
    // Highlight cards.
    expect(find.text('Lieblingspass'), findsOneWidget);
    expect(find.text('Höchster erkundet'), findsOneWidget);
    // Per-canton board.
    expect(find.text('Fortschritt nach Kanton'), findsOneWidget);
    expect(find.text('UR'), findsOneWidget);
  });
}
