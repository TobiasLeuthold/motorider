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
    test('parsePasses reads the full v2 schema (segment fields incl.)', () {
      const json = '''
      {
        "_attribution": "Pass data © OpenStreetMap contributors (ODbL).",
        "passes": [
          {"name":"Furkapass","lat":46.5727,"lon":8.4152,"ele":2429,
           "cantons":["VS","UR"],"connects":["Realp","Gletsch"],
           "hairpins":24,"curvinessScore":385.1,
           "maxGradientPct":13.0,"climbLengthKm":null,"osmId":123,
           "summitEle":2429,
           "start":{"lat":46.61,"lon":8.36,"ele":1757},
           "end":{"lat":46.59,"lon":8.49,"ele":1538},
           "heightGainM":672,"netDiffM":-219,"lengthKm":25.7,
           "geometry":[[46.61,8.36],[46.5727,8.4152],[46.59,8.49]]},
          {"name":"Col de la Tourne","lat":46.9837,"lon":6.7789,"ele":null,
           "cantons":["NE"],"connects":null}
        ]
      }
      ''';
      final passes = parsePasses(json);
      expect(passes, hasLength(2));
      final f = passes[0];
      expect(f.name, 'Furkapass');
      expect(f.ele, 2429);
      expect(f.summitEle, 2429);
      expect(f.cantons, ['VS', 'UR']);
      expect(f.connects, ['Realp', 'Gletsch']);
      expect(f.hairpins, 24);
      expect(f.curvinessScore, 385.1);
      expect(f.maxGradientPct, 13.0);
      expect(f.start!.ele, 1757);
      expect(f.end!.lat, 46.59);
      expect(f.heightGainM, 672);
      expect(f.netDiffM, -219);
      expect(f.lengthKm, 25.7);
      expect(f.geometry, hasLength(3));
      expect(f.geometry.first.latitude, 46.61);
      expect(f.geometry.last.longitude, 8.49);
      // Sparse pass: every optional/segment field is null/empty, no throw.
      final t = passes[1];
      expect(t.ele, isNull);
      expect(t.summitEle, isNull);
      expect(t.connects, isNull);
      expect(t.start, isNull);
      expect(t.end, isNull);
      expect(t.heightGainM, isNull);
      expect(t.geometry, isEmpty);
    });

    test('summitEle falls back to ele and vice-versa', () {
      // ele only → summitEle mirrors it.
      final a = parsePasses(
          '{"passes":[{"name":"A","lat":46.5,"lon":8.4,"cantons":["UR"],"ele":2000}]}');
      expect(a.single.summitEle, 2000);
      // summitEle only → ele mirrors it.
      final b = parsePasses(
          '{"passes":[{"name":"B","lat":46.5,"lon":8.4,"cantons":["UR"],"summitEle":1500}]}');
      expect(b.single.ele, 1500);
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
    Pass byName(String n) =>
        passes.firstWhere((p) => p.name == n, orElse: () => throw 'missing $n');

    // 41 canonical Swiss road passes that MUST be present (by exact name).
    const mustHave = <String>[
      'Pass Umbrail - Giogo di Santa Maria',
      'Nufenenpass / Passo della Novena',
      'Col du Grand Saint-Bernard',
      'Furkapass',
      'Grimselpass',
      'Sustenpass',
      'Passo del San Gottardo',
      'Passo del Bernina',
      'Flüelapass',
      'Albulapass',
      'Julierpass',
      'Passo dello Spluga - Splügenpass',
      'Passo del San Bernardino',
      'Klausenpass',
      'Oberalppass',
      'Passo del Lucomagno',
      'Simplonpass',
      'Malojapass',
      'Pass dal Fuorn',
      'Col de la Forclaz',
      'Col du Pillon',
      'Col des Mosses',
      'Col de la Croix',
      'Col du Sanetsch',
      'Grosse Scheidegg',
      'Jaunpass',
      'Brünigpass',
      'Wolfgangpass',
      'Lenzerheide / Passhöhe',
      'Pragelpass',
      'Ibergeregg',
      'Schwägalp Passhöhe',
      'Sattelegg',
      'Vue des Alpes',
      'Col du Marchairuz',
      'Saanenmöser',
      'Schallenbergpass',
      'Gurnigel / Gurnigelpass',
      'Glaubenbielen / Panoramastrasse',
      'Glaubenbergpass',
    ];

    test('holds a curated set of ~80–120 passes', () {
      // Not pinned to an exact count (curation may shift), but guards against a
      // truncated or runaway asset.
      expect(passes.length, inInclusiveRange(60, 130),
          reason: 'curated count was ${passes.length}');
    });

    test('attribution credits OpenStreetMap / ODbL and notes derivation', () {
      final attr = parseAttribution(raw);
      expect(attr, contains('OpenStreetMap'));
      expect(attr, contains('ODbL'));
      // v2 attribution must flag the OSM/SRTM-derived geometry & fields.
      expect(attr.toLowerCase(), contains('srtm'));
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

    test('every canonical Swiss road pass is present', () {
      final names = passes.map((p) => p.name).toSet();
      for (final n in mustHave) {
        expect(names, contains(n), reason: 'must-have pass missing: $n');
      }
    });

    test('pass names are unique', () {
      final seen = <String>{};
      final dupes = <String>{};
      for (final p in passes) {
        if (!seen.add(p.name)) dupes.add(p.name);
      }
      expect(dupes, isEmpty, reason: 'duplicate names: $dupes');
    });

    test('elevations are present and plausible for Swiss passes', () {
      for (final p in passes) {
        expect(p.ele, isNotNull, reason: 'ele for ${p.name}');
        expect(p.ele, inInclusiveRange(400, 2700), reason: 'ele ${p.name}');
        // ele mirrors summitEle.
        expect(p.summitEle, p.ele, reason: 'summitEle != ele for ${p.name}');
      }
    });

    test('the iconic high passes sit at sane elevations', () {
      // SRTM-derived summits, so allow ~40 m slack vs. the surveyed col height.
      expect(byName('Furkapass').ele, closeTo(2429, 40));
      expect(byName('Grimselpass').ele, closeTo(2164, 40));
      expect(byName('Sustenpass').ele, closeTo(2224, 40));
      expect(byName('Passo del San Gottardo').ele, closeTo(2106, 40));
      expect(byName('Nufenenpass / Passo della Novena').ele, closeTo(2478, 40));
    });

    // ── segment foundation (tools/compute_pass_data.dart) ──
    // Every pass is now a road segment with two feet, a summit, a climb and a
    // drawable polyline. These guard that the derived data is well-formed.

    test('every pass has both feet, a summit, and a positive height gain', () {
      for (final p in passes) {
        expect(p.start, isNotNull, reason: 'start for ${p.name}');
        expect(p.end, isNotNull, reason: 'end for ${p.name}');
        expect(p.summitEle, isNotNull, reason: 'summitEle for ${p.name}');
        expect(p.heightGainM, isNotNull, reason: 'heightGainM for ${p.name}');
        // A real pass climbs; allow a small floor but reject zero/negative.
        expect(p.heightGainM, greaterThanOrEqualTo(80),
            reason: 'heightGain ${p.name} = ${p.heightGainM}');
        // The summit is at least as high as either foot (it's the top).
        expect(p.summitEle!, greaterThanOrEqualTo(p.start!.ele! - 5),
            reason: 'summit below start foot for ${p.name}');
        expect(p.summitEle!, greaterThanOrEqualTo(p.end!.ele! - 5),
            reason: 'summit below end foot for ${p.name}');
        // heightGain == summit minus the lower foot (within rounding).
        final lower =
            p.start!.ele! < p.end!.ele! ? p.start!.ele! : p.end!.ele!;
        expect((p.heightGainM! - (p.summitEle! - lower)).abs(),
            lessThanOrEqualTo(2),
            reason: 'heightGain mismatch for ${p.name}');
      }
    });

    test('netDiff equals end minus start foot elevation', () {
      for (final p in passes) {
        expect(p.netDiffM, isNotNull, reason: 'netDiffM for ${p.name}');
        expect((p.netDiffM! - (p.end!.ele! - p.start!.ele!)).abs(),
            lessThanOrEqualTo(2),
            reason: 'netDiff mismatch for ${p.name}');
      }
    });

    test('every segment has a plausible length (2–60 km)', () {
      for (final p in passes) {
        expect(p.lengthKm, isNotNull, reason: 'lengthKm for ${p.name}');
        expect(p.lengthKm, inInclusiveRange(2.0, 60.0),
            reason: 'lengthKm ${p.name} = ${p.lengthKm}');
      }
    });

    test('geometry has ≥2 points, endpoints match the feet, and nears the col',
        () {
      for (final p in passes) {
        final g = p.geometry;
        expect(g.length, greaterThanOrEqualTo(2),
            reason: 'geometry too short for ${p.name}');
        expect(g.length, lessThanOrEqualTo(60),
            reason: 'geometry too long for ${p.name}: ${g.length}');
        // First vertex == start foot, last == end foot (rounded to 5 dp).
        expect(g.first.latitude, closeTo(p.start!.lat, 1e-4),
            reason: 'geom start lat ${p.name}');
        expect(g.first.longitude, closeTo(p.start!.lon, 1e-4),
            reason: 'geom start lon ${p.name}');
        expect(g.last.latitude, closeTo(p.end!.lat, 1e-4),
            reason: 'geom end lat ${p.name}');
        expect(g.last.longitude, closeTo(p.end!.lon, 1e-4),
            reason: 'geom end lon ${p.name}');
        // The polyline passes near the col (anchor of crossing detection):
        // some vertex within 250 m of (lat,lon).
        final col = p.latLng;
        final nearCol =
            g.any((v) => haversineMeters(v, col) <= 250);
        expect(nearCol, isTrue,
            reason: 'geometry never approaches the col for ${p.name}');
      }
    });

    test('maxGradient, where present, is a sane road grade (0–20 %)', () {
      for (final p in passes) {
        final g = p.maxGradientPct;
        if (g == null) continue;
        expect(g, inInclusiveRange(0, 20), reason: 'maxGrad ${p.name} = $g');
      }
    });

    test('a few segments are dimensionally sane (spot-check)', () {
      // Furka, Grimsel, Splügen, Gotthard: real climbs of many hundreds of m
      // over several km. Loose bounds — guard against a degenerate segment.
      for (final n in const [
        'Furkapass',
        'Grimselpass',
        'Passo dello Spluga - Splügenpass',
        'Passo del San Gottardo',
      ]) {
        final p = byName(n);
        expect(p.heightGainM, greaterThanOrEqualTo(400),
            reason: '$n climb too small');
        expect(p.lengthKm, greaterThanOrEqualTo(6.0),
            reason: '$n segment too short');
      }
    });

    // ── hairpin / curviness data (computed over the whole segment) ──

    test('hairpins is populated for the vast majority of passes', () {
      final withHairpins = passes.where((p) => p.hairpins != null).length;
      expect(withHairpins, greaterThanOrEqualTo((passes.length * 0.9).floor()),
          reason: 'only $withHairpins/${passes.length} have hairpins');
    });

    test('every known hairpin count is in a sane range (0–80)', () {
      for (final p in passes) {
        final h = p.hairpins;
        if (h == null) continue;
        expect(h, inInclusiveRange(0, 80), reason: 'hairpins ${p.name} = $h');
      }
    });

    test('curvinessScore is populated and non-negative where present', () {
      final withCv = passes.where((p) => p.curvinessScore != null).length;
      expect(withCv, greaterThanOrEqualTo((passes.length * 0.9).floor()),
          reason: 'only $withCv/${passes.length} have curvinessScore');
      for (final p in passes) {
        final c = p.curvinessScore;
        if (c == null) continue;
        expect(c, inInclusiveRange(0, 1500), reason: 'curviness ${p.name} = $c');
      }
    });

    test('famously hairpin-heavy passes have plausibly high counts', () {
      // Over the full segment the counts are higher than the old col-only ones;
      // floors set well below the computed values so OSM edits don't break CI.
      expect(byName('Furkapass').hairpins, greaterThanOrEqualTo(8),
          reason: 'Furka should be very hairpinny');
      expect(byName('Grimselpass').hairpins, greaterThanOrEqualTo(8));
      expect(byName('Passo del San Bernardino').hairpins,
          greaterThanOrEqualTo(15));
      expect(byName('Passo dello Spluga - Splügenpass').hairpins,
          greaterThanOrEqualTo(12));
      expect(byName('Klausenpass').hairpins, greaterThanOrEqualTo(8));
      expect(byName('Albulapass').hairpins, greaterThanOrEqualTo(6));
      expect(byName('Julierpass').hairpins, greaterThanOrEqualTo(6));
    });

    test('gentle passes have far fewer hairpins than the serpentine ones', () {
      expect(byName('Simplonpass').hairpins, lessThanOrEqualTo(6),
          reason: 'Simplon is a fast sweeping pass, not hairpinny');
      expect(byName('Brünigpass').hairpins, lessThanOrEqualTo(8));
      // And the ordering that motivates the whole feature holds.
      expect(byName('Passo del San Bernardino').hairpins!,
          greaterThan(byName('Brünigpass').hairpins!));
      expect(byName('Furkapass').hairpins!,
          greaterThan(byName('Simplonpass').hairpins!));
    });

    test('curviness tracks hairpins: serpentine passes out-curve gentle ones',
        () {
      expect(byName('Passo del San Bernardino').curvinessScore!,
          greaterThan(byName('Simplonpass').curvinessScore!));
    });
  });
}
