import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/stats/pass_explorer.dart';
import 'package:motorider/stats/pass_summary.dart';

/// Stage C — pure formatting/aggregation helpers behind the Pässe UI. These
/// pin down the German wording, units and rounding the detail screen and the
/// "Meine Pässe" overview render, with no Flutter binding involved.

Pass _pass({
  String name = 'Testpass',
  int? ele = 2400,
  int? heightGainM = 850,
  double? lengthKm = 12.4,
  double? maxGradientPct = 9.7,
  int? hairpins = 18,
  double? curvinessScore = 233.6,
  List<String> cantons = const ['UR'],
}) =>
    Pass(
      name: name,
      lat: 46.5,
      lon: 8.4,
      ele: ele,
      cantons: cantons,
      heightGainM: heightGainM,
      lengthKm: lengthKm,
      maxGradientPct: maxGradientPct,
      hairpins: hairpins,
      curvinessScore: curvinessScore,
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
      rideIds: const [],
      crossings: crossings,
    );

PassCrossing _crossing({double? kmh, int? durS, String rideId = 'r'}) =>
    PassCrossing(
      rideId: rideId,
      at: DateTime(2026, 6, 1, 10),
      direction: PassDirection.startToEnd,
      avgSpeedKmh: kmh,
      durationS: durS,
    );

void main() {
  group('formatPassDuration', () {
    test('m:ss under an hour, with zero-padded seconds', () {
      expect(formatPassDuration(42), '0:42');
      expect(formatPassDuration(125), '2:05');
      expect(formatPassDuration(600), '10:00');
    });
    test('h:mm:ss once it crosses an hour', () {
      expect(formatPassDuration(3800), '1:03:20');
    });
    test('null / zero / negative → dash', () {
      expect(formatPassDuration(null), '–');
      expect(formatPassDuration(0), '–');
      expect(formatPassDuration(-5), '–');
    });
  });

  group('formatTotalTimeOnPasses', () {
    test('minutes under an hour', () {
      expect(formatTotalTimeOnPasses(48 * 60), '48 min');
    });
    test('rolls up to hours with one decimal (de_CH)', () {
      // 2.5 h → "2.5 h" in de_CH (NumberFormat uses "." as decimal there).
      expect(formatTotalTimeOnPasses(9000), '2.5 h');
    });
    test('zero → dash', () {
      expect(formatTotalTimeOnPasses(0), '–');
    });
  });

  group('formatSpeedKmh', () {
    test('rounds to whole km/h', () {
      expect(formatSpeedKmh(87.4), '87 km/h');
      expect(formatSpeedKmh(87.6), '88 km/h');
    });
    test('null / non-positive → dash', () {
      expect(formatSpeedKmh(null), '–');
      expect(formatSpeedKmh(0), '–');
    });
  });

  group('fastestCrossingHeadline', () {
    test('pass name · speed', () {
      final f = FastestCrossing(
        pass: _pass(name: 'Furkapass'),
        avgSpeedKmh: 92.3,
        at: DateTime(2026, 6, 1),
        rideId: 'r',
      );
      expect(fastestCrossingHeadline(f), 'Furkapass · 92 km/h');
    });
    test('null when none', () {
      expect(fastestCrossingHeadline(null), isNull);
    });
  });

  group('passHistorySummary', () {
    test('uncrossed', () {
      expect(passHistorySummary(_progress(_pass())), 'Noch nicht erkundet');
    });
    test('crossed without measured speed', () {
      final p = _progress(_pass(), count: 2, crossings: [
        _crossing(kmh: null, durS: 100),
        _crossing(kmh: null, durS: 100),
      ]);
      expect(passHistorySummary(p), '2× erkundet');
    });
    test('crossed with a best speed', () {
      final p = _progress(_pass(), count: 3, crossings: [
        _crossing(kmh: 60),
        _crossing(kmh: 88),
        _crossing(kmh: 75),
      ]);
      expect(passHistorySummary(p), '3× erkundet · Bestschnitt 88 km/h');
    });
  });

  group('passFactTiles', () {
    test('order, labels and units', () {
      final tiles = passFactTiles(_pass());
      expect(tiles.map((t) => t.label).toList(), [
        'Höhe',
        'Anstieg',
        'Länge',
        'Max. Steigung',
        'Kehren',
        'Kurvigkeit',
      ]);
      expect(tiles[0].value, '2’400 m'); // de_CH groups thousands with ’
      expect(tiles[1].value, '850 m');
      expect(tiles[2].value, '12.4 km');
      expect(tiles[3].value, '10 %'); // 9.7 → rounded to 10
      expect(tiles[4].value, '18');
      expect(tiles[5].value, '234 °/km');
    });
    test('missing facts render as a dash, never fabricated', () {
      final tiles = passFactTiles(_pass(
        ele: null,
        heightGainM: null,
        lengthKm: null,
        maxGradientPct: null,
        hairpins: null,
        curvinessScore: null,
      ));
      expect(tiles.every((t) => t.value == '–'), isTrue);
    });
  });

  group('highest / favourite labels', () {
    test('highest pass label with elevation', () {
      final p = _progress(_pass(name: 'Nufenenpass', ele: 2478));
      expect(highestPassLabel(p), 'Nufenenpass · 2478 m');
    });
    test('highest pass label null when none', () {
      expect(highestPassLabel(null), isNull);
    });
    test('favourite pass label', () {
      final p = _progress(_pass(name: 'Sustenpass'), count: 5);
      expect(favouritePassLabel(p), 'Sustenpass · 5×');
    });
    test('favourite null when uncrossed', () {
      expect(favouritePassLabel(_progress(_pass())), isNull);
    });
  });

  group('cantonsWithProgress', () {
    test('counts only cantons with at least one explored pass', () {
      final m = {
        'UR': const CantonProgress(2, 5),
        'VS': const CantonProgress(0, 8),
        'TI': const CantonProgress(1, 3),
      };
      expect(cantonsWithProgress(m), 2);
    });
    test('empty map → 0', () {
      expect(cantonsWithProgress(const {}), 0);
    });
  });

  // Sanity that the helpers compose with a real explorePasses result.
  test('helpers read a real explorePasses result without throwing', () {
    final col = const LatLng(46.5, 8.4);
    final pass = Pass(
      name: 'Seg',
      lat: col.latitude,
      lon: col.longitude,
      ele: 2000,
      cantons: const ['UR'],
      start: PassPoint(lat: col.latitude - 0.03, lon: col.longitude),
      end: PassPoint(lat: col.latitude + 0.03, lon: col.longitude),
      geometry: [
        LatLng(col.latitude - 0.03, col.longitude),
        col,
        LatLng(col.latitude + 0.03, col.longitude),
      ],
    );
    final res = explorePasses([pass], const []);
    expect(res.stats.explored, 0);
    expect(fastestCrossingHeadline(res.stats.fastestCrossing), isNull);
    expect(passHistorySummary(res.progress.single), 'Noch nicht erkundet');
    expect(passFactTiles(pass).first.value, '2’000 m');
  });
}
