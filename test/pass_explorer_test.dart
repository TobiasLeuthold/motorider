import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/geo.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// A reference col used throughout the tests.
const _col = LatLng(46.5727, 8.4152); // Furkapass-ish

/// Metres-per-degree of latitude (spherical). Moving lat by `m / _mPerLat`
/// shifts a point exactly `m` metres north/south of [_col], which lets the
/// tests place fixes at precise distances from the col and trust the real
/// haversine detector to do the rest.
const double _mPerLat = 111195.0;

/// A point [metresNorth] of [_col] (negative = south).
LatLng _north(double metresNorth) =>
    LatLng(_col.latitude + metresNorth / _mPerLat, _col.longitude);

RideTrack _track(String id, List<LatLng> pts, {DateTime? start}) {
  final t0 = start ?? DateTime(2026, 6, 1, 10);
  return RideTrack(
    rideId: id,
    points: pts,
    times: [for (var i = 0; i < pts.length; i++) t0.add(Duration(seconds: i))],
  );
}

Pass _pass(
  String name,
  LatLng at, {
  int? ele,
  List<String> cantons = const ['UR'],
  int? hairpins,
}) =>
    Pass(
      name: name,
      lat: at.latitude,
      lon: at.longitude,
      ele: ele,
      cantons: cantons,
      hairpins: hairpins,
    );

void main() {
  group('distance sanity (test scaffolding)', () {
    test('_north places points at the requested distance from the col', () {
      expect(haversineMeters(_north(200), _col), closeTo(200, 1));
      expect(haversineMeters(_north(3500), _col), closeTo(3500, 5));
      expect(haversineMeters(_north(-3500), _col), closeTo(3500, 5));
    });
  });

  group('detectCrossingsInTrack — single ride hysteresis', () {
    test('a clean drive-through counts exactly one crossing', () {
      // Approach from 4 km south, pass right over the col, leave 4 km north.
      final pts = [
        _north(-4000),
        _north(-1000),
        _north(-100), // within 250 m → triggers here
        _north(100),
        _north(1000),
        _north(4000),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
      // Timestamp is the first in-radius fix (index 2 → t0 + 2s).
      expect(c.first.at, DateTime(2026, 6, 1, 10, 0, 2));
    });

    test('lingering within 250 m counts once, not once per point', () {
      final pts = [
        _north(-3000),
        _north(-200),
        _north(-150),
        _north(-50),
        _north(0),
        _north(50),
        _north(150),
        _north(200), // many fixes inside the radius
        _north(3500),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
    });

    test('GPS jitter in/out of 250 m without leaving 3 km counts once', () {
      // Dance across the trigger boundary repeatedly but never get 3 km away.
      final pts = [
        _north(-2000),
        _north(-200), // in
        _north(-400), // out of trigger, still well within re-arm
        _north(-100), // in again — must NOT re-count (still armed=false)
        _north(-500),
        _north(-50), // in again
        _north(-2500), // still inside re-arm radius (<3 km)
        _north(-200), // in again
        _north(-2000),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
    });

    test('a genuine out-and-back that exits 3 km then returns counts twice',
        () {
      final pts = [
        _north(-4000),
        _north(-100), // crossing #1
        _north(100),
        _north(3500), // > 3 km away → re-arm
        _north(100),
        _north(-100), // crossing #2
        _north(-4000),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(2));
    });

    test('a near-miss (closest 300 m, never within 250) counts zero', () {
      final pts = [
        _north(-3000),
        _north(-400),
        _north(-300), // closest approach, still outside trigger
        _north(-350),
        _north(-3000),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, isEmpty);
    });

    test('exactly on the trigger boundary (250 m) counts (<=)', () {
      final pts = [_north(-3000), _north(250), _north(-3000)];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
    });

    test('re-arm needs the full 3 km; 2.9 km out then back is still one', () {
      final pts = [
        _north(-4000),
        _north(-50), // crossing
        _north(2900), // not quite 3 km → stays disarmed
        _north(-50), // would-be second, but disarmed
        _north(-4000),
      ];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
    });

    test('starts armed: a ride that begins on the col still counts', () {
      final pts = [_north(0), _north(100), _north(4000)];
      final c = detectCrossingsInTrack(_track('r1', pts), _col);
      expect(c, hasLength(1));
      expect(c.first.at, DateTime(2026, 6, 1, 10)); // first fix
    });

    test('empty track yields no crossings', () {
      final c = detectCrossingsInTrack(_track('r1', const []), _col);
      expect(c, isEmpty);
    });
  });

  group('bbox pruning', () {
    test('trackMayReach is false for a ride far from the col', () {
      // A ride near Zürich, ~150 km from the Furka col.
      final far = _track('z', const [
        LatLng(47.37, 8.54),
        LatLng(47.38, 8.55),
      ]);
      expect(trackMayReach(far, _col), isFalse);
    });

    test('trackMayReach is true when the box edge is within the margin', () {
      // Box sits 1 km south of the col → within the 3 km default margin.
      final near = _track('n', [_north(-1000), _north(-1200)]);
      expect(trackMayReach(near, _col), isTrue);
    });

    test('trackMayReach is true when the col is inside the box', () {
      final around = _track('a', [_north(-2000), _north(2000)]);
      expect(trackMayReach(around, _col), isTrue);
    });

    test('a pruned ride contributes zero crossings via explorePasses', () {
      final passes = [_pass('Furka', _col, ele: 2429)];
      final far = _track('z', const [LatLng(47.37, 8.54), LatLng(47.38, 8.55)]);
      final res = explorePasses(passes, [far]);
      expect(res.progress.single.count, 0);
      expect(res.stats.explored, 0);
    });

    test('pruning does not drop a real crossing that just clips the margin',
        () {
      // Ride approaches to 100 m (a real crossing) but its bbox would also be
      // close — proves the prune never rejects a true positive.
      final passes = [_pass('Furka', _col, ele: 2429)];
      final ride = _track('r', [_north(-3000), _north(-100), _north(-3000)]);
      final res = explorePasses(passes, [ride]);
      expect(res.progress.single.count, 1);
    });
  });

  group('explorePasses — multi-ride aggregation', () {
    test('crossings sum across rides; rideIds + first/last date tracked', () {
      final passes = [_pass('Furka', _col, ele: 2429)];
      final r1 = _track(
        'r1',
        [_north(-3000), _north(-50), _north(-3000)],
        start: DateTime(2026, 5, 1, 9),
      );
      final r2 = _track(
        'r2',
        [_north(3000), _north(50), _north(3000)],
        start: DateTime(2026, 6, 10, 14),
      );
      final res = explorePasses(passes, [r1, r2]);
      final p = res.progress.single;
      expect(p.count, 2);
      expect(p.rideIds, ['r1', 'r2']);
      // First crossing fires at r1's first in-radius fix (index 1 → +1s);
      // last at r2's (also index 1 → +1s).
      expect(p.firstDate, DateTime(2026, 5, 1, 9, 0, 1));
      expect(p.lastDate, DateTime(2026, 6, 10, 14, 0, 1));
      expect(p.crossed, isTrue);
    });

    test('one ride crossing the same pass twice → count 2, one rideId', () {
      final passes = [_pass('Furka', _col, ele: 2429)];
      final r = _track('r1', [
        _north(-4000),
        _north(-50), // #1
        _north(3500), // re-arm
        _north(-50), // #2
        _north(-4000),
      ]);
      final res = explorePasses(passes, [r]);
      final p = res.progress.single;
      expect(p.count, 2);
      expect(p.rideIds, ['r1']);
    });
  });

  group('collection stats', () {
    // Three passes at distinct, separated locations so a ride near one does
    // not accidentally trigger another.
    final colA = const LatLng(46.50, 8.40); // crossed twice
    final colB = const LatLng(46.70, 9.00); // crossed once
    final colC = const LatLng(47.00, 7.00); // never crossed (highest)

    List<Pass> passes() => [
          Pass(name: 'A', lat: colA.latitude, lon: colA.longitude, ele: 2000, cantons: const ['UR', 'VS'], hairpins: 10),
          Pass(name: 'B', lat: colB.latitude, lon: colB.longitude, ele: 1500, cantons: const ['GR'], hairpins: 5),
          Pass(name: 'C', lat: colC.latitude, lon: colC.longitude, ele: 2500, cantons: const ['VS']),
        ];

    LatLng near(LatLng c, double m) =>
        LatLng(c.latitude + m / _mPerLat, c.longitude);

    List<RideTrack> rides() => [
          // crosses A (out-and-back → twice)
          _track('rA', [
            near(colA, -4000),
            near(colA, -50),
            near(colA, 3500),
            near(colA, -50),
            near(colA, -4000),
          ]),
          // crosses B once
          _track('rB', [near(colB, -3000), near(colB, 50), near(colB, -3000)]),
        ];

    test('explored count, total and percent', () {
      final res = explorePasses(passes(), rides());
      expect(res.stats.total, 3);
      expect(res.stats.explored, 2); // A and B
      expect(res.stats.percent, closeTo(66.6667, 0.01));
    });

    test('metres collected = sum of ele over crossed passes', () {
      final res = explorePasses(passes(), rides());
      expect(res.stats.metresCollected, 2000 + 1500); // C not crossed
    });

    test('total hairpins ridden = sum of known hairpins over crossed passes',
        () {
      final res = explorePasses(passes(), rides());
      expect(res.stats.totalHairpins, 10 + 5);
    });

    test('highest crossed and highest uncrossed', () {
      final res = explorePasses(passes(), rides());
      expect(res.stats.highestCrossed?.pass.name, 'A'); // 2000 > 1500
      expect(res.stats.highestUncrossed?.pass.name, 'C'); // 2500, uncrossed
    });

    test('most-crossed pass picks the highest count', () {
      final res = explorePasses(passes(), rides());
      expect(res.stats.mostCrossed?.pass.name, 'A'); // crossed twice
      expect(res.stats.mostCrossed?.count, 2);
    });

    test('per-canton progress (multi-canton pass counts for both)', () {
      final res = explorePasses(passes(), rides());
      final pc = res.stats.perCanton;
      // UR: only A → done 1 / total 1
      expect(pc['UR'], isNotNull);
      expect(pc['UR']!.done, 1);
      expect(pc['UR']!.total, 1);
      // VS: A (crossed) + C (uncrossed) → done 1 / total 2
      expect(pc['VS']!.done, 1);
      expect(pc['VS']!.total, 2);
      // GR: only B (crossed) → 1 / 1
      expect(pc['GR']!.done, 1);
      expect(pc['GR']!.total, 1);
    });

    test('progress list preserves input pass order', () {
      final res = explorePasses(passes(), rides());
      expect(res.progress.map((p) => p.pass.name).toList(), ['A', 'B', 'C']);
    });
  });

  group('edge cases', () {
    test('empty rides → nothing crossed, stats still well-formed', () {
      final passes = [_pass('Furka', _col, ele: 2429, cantons: const ['UR'])];
      final res = explorePasses(passes, const []);
      expect(res.stats.explored, 0);
      expect(res.stats.total, 1);
      expect(res.stats.percent, 0);
      expect(res.stats.metresCollected, 0);
      expect(res.stats.highestCrossed, isNull);
      expect(res.stats.highestUncrossed?.pass.name, 'Furka');
      expect(res.stats.mostCrossed, isNull);
      expect(res.stats.perCanton['UR']!.done, 0);
      expect(res.stats.perCanton['UR']!.total, 1);
    });

    test('empty passes → empty result, percent 0, no NaN', () {
      final res = explorePasses(const [], [
        _track('r', [_north(0)])
      ]);
      expect(res.progress, isEmpty);
      expect(res.stats.total, 0);
      expect(res.stats.explored, 0);
      expect(res.stats.percent, 0);
      expect(res.stats.perCanton, isEmpty);
    });

    test('rides with a single point do not crash and can still trigger', () {
      final passes = [_pass('Furka', _col, ele: 2429)];
      final res = explorePasses(passes, [
        _track('r', [_north(10)]) // single fix on the col
      ]);
      expect(res.progress.single.count, 1);
    });

    test('a pass with null ele is ignored for metres + highest, still counts',
        () {
      final passes = [_pass('NoEle', _col, ele: null)];
      final res = explorePasses(passes, [
        _track('r', [_north(-3000), _north(0), _north(-3000)])
      ]);
      expect(res.stats.explored, 1);
      expect(res.stats.metresCollected, 0); // null ele contributes nothing
      expect(res.stats.highestCrossed, isNull); // no ele to rank
    });
  });

  group('dataset parsing', () {
    test('parsePasses reads name/lat/lon/ele/cantons and optional fields', () {
      const json = '''
      {
        "_attribution": "Pass data © OpenStreetMap contributors (ODbL).",
        "passes": [
          {"name":"Furkapass","lat":46.5727,"lon":8.4152,"ele":2429,
           "cantons":["VS","UR"],"connects":["Realp","Gletsch"],
           "hairpins":null,"maxGradientPct":null,"climbLengthKm":null,"osmId":123},
          {"name":"Col de la Tourne","lat":46.9837,"lon":6.7789,"ele":null,
           "cantons":["NE"],"connects":null}
        ]
      }
      ''';
      final passes = parsePasses(json);
      expect(passes, hasLength(2));
      expect(passes[0].name, 'Furkapass');
      expect(passes[0].ele, 2429);
      expect(passes[0].cantons, ['VS', 'UR']);
      expect(passes[0].connects, ['Realp', 'Gletsch']);
      expect(passes[0].hairpins, isNull);
      expect(passes[1].ele, isNull);
      expect(passes[1].connects, isNull);
    });

    test('parseAttribution extracts the ODbL string', () {
      const json =
          '{"_attribution":"Pass data © OpenStreetMap contributors (ODbL).","passes":[]}';
      expect(parseAttribution(json), contains('OpenStreetMap'));
      expect(parseAttribution(json), contains('ODbL'));
    });
  });

  group('shipped asset integrity', () {
    // Read the real bundled dataset straight from disk (tests run with cwd at
    // the package root) so a broken/mangled asset fails CI.
    final raw = File('assets/data/passes_ch.json').readAsStringSync();
    final passes = parsePasses(raw);

    test('has 99 passes', () {
      expect(passes, hasLength(99));
    });

    test('attribution credits OpenStreetMap / ODbL', () {
      final attr = parseAttribution(raw);
      expect(attr, contains('OpenStreetMap'));
      expect(attr, contains('ODbL'));
    });

    test('every pass has a name, ≥1 canton, and coords inside Switzerland', () {
      for (final p in passes) {
        expect(p.name.trim(), isNotEmpty, reason: 'name for $p');
        expect(p.cantons, isNotEmpty, reason: 'cantons for ${p.name}');
        // CH bounding box (a little slack for border cols).
        expect(p.lat, inInclusiveRange(45.7, 47.9), reason: 'lat ${p.name}');
        expect(p.lon, inInclusiveRange(5.8, 10.6), reason: 'lon ${p.name}');
      }
    });

    test('elevations, where present, are plausible for Swiss passes', () {
      for (final p in passes) {
        if (p.ele == null) continue;
        expect(p.ele, inInclusiveRange(300, 2900), reason: 'ele ${p.name}');
      }
    });

    test('the iconic high passes are present at sane elevations', () {
      Pass byName(String n) => passes.firstWhere((p) => p.name == n);
      expect(byName('Furkapass').ele, closeTo(2429, 30));
      expect(byName('Grimselpass').ele, closeTo(2164, 30));
      expect(byName('Sustenpass').ele, closeTo(2224, 30));
      expect(byName('Passo del San Gottardo').ele, closeTo(2106, 30));
      // A spread of the must-have names exists.
      final names = passes.map((p) => p.name).toSet();
      for (final n in const [
        'Klausenpass',
        'Julierpass',
        'Passo del Bernina',
        'Flüelapass',
        'Oberalppass',
        'Simplonpass',
      ]) {
        expect(names, contains(n));
      }
    });

    test('names are unique except for the two distinct Col de la Croix cols',
        () {
      final names = passes.map((p) => p.name).toList();
      final dupes = <String>{};
      final seen = <String>{};
      for (final n in names) {
        if (!seen.add(n)) dupes.add(n);
      }
      expect(dupes, {'Col de la Croix'});
    });
  });
}
