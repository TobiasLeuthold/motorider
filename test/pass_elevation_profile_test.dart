import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:motorider/stats/pass_explorer.dart';
import 'package:motorider/stats/pass_elevation_profile.dart';

/// Build a straight west→east geometry of [n] points spanning [lengthM] metres
/// at latitude 46, so cumulative distance along it is easy to reason about.
List<LatLng> _line(int n, double lengthM) {
  const lat = 46.0;
  final mPerDegLon = 111320.0 * 0.694; // cos(46°)
  final dLon = (lengthM / mPerDegLon) / (n - 1);
  return [for (var i = 0; i < n; i++) LatLng(lat, 8.0 + i * dLon)];
}

void main() {
  group('passElevationProfile', () {
    test('places the col at its real distance — flanks are asymmetric', () {
      // 10 km road; the col sits ~3 km in (early), so the descent flank is far
      // longer than the climb flank. Feet differ in height too.
      final geom = _line(11, 10000);
      final colLatLng = geom[3]; // 3/10 of the way along
      final pass = Pass(
        name: 'Test',
        lat: colLatLng.latitude,
        lon: colLatLng.longitude,
        cantons: const ['XX'],
        summitEle: 2000,
        ele: 2000,
        start: PassPoint(
            lat: geom.first.latitude, lon: geom.first.longitude, ele: 1500),
        end: PassPoint(
            lat: geom.last.latitude, lon: geom.last.longitude, ele: 1000),
        lengthKm: 10.0,
        geometry: geom,
      );

      final prof = passElevationProfile(pass);
      expect(prof.length, 3);
      // Left foot, col, right foot.
      expect(prof.first.km, closeTo(0, 0.01));
      expect(prof.first.ele, 1500);
      expect(prof[1].km, closeTo(3.0, 0.3)); // col at its real ~3 km
      expect(prof[1].ele, 2000); // summit
      expect(prof.last.km, closeTo(10.0, 0.3));
      expect(prof.last.ele, 1000);
      // The two flanks have clearly different widths (the whole point).
      final climb = prof[1].km - prof.first.km;
      final descent = prof.last.km - prof[1].km;
      expect(descent, greaterThan(climb * 1.5));
    });

    test('feet keep their real, unequal heights', () {
      final geom = _line(7, 6000);
      final pass = Pass(
        name: 'T',
        lat: geom[3].latitude,
        lon: geom[3].longitude,
        cantons: const [],
        summitEle: 2200,
        start: PassPoint(
            lat: geom.first.latitude, lon: geom.first.longitude, ele: 800),
        end: PassPoint(
            lat: geom.last.latitude, lon: geom.last.longitude, ele: 1300),
        geometry: geom,
      );
      final prof = passElevationProfile(pass);
      expect(prof.first.ele, 800);
      expect(prof.last.ele, 1300);
      expect(prof.first.ele == prof.last.ele, isFalse);
    });

    test('orients to the feet even when geometry runs end→start', () {
      // Geometry from east to west; start foot is the EAST end here.
      final geom = _line(7, 6000);
      final startFoot = PassPoint(
          lat: geom.last.latitude, lon: geom.last.longitude, ele: 900);
      final endFoot = PassPoint(
          lat: geom.first.latitude, lon: geom.first.longitude, ele: 1400);
      final pass = Pass(
        name: 'T',
        lat: geom[3].latitude,
        lon: geom[3].longitude,
        cantons: const [],
        summitEle: 2100,
        start: startFoot,
        end: endFoot,
        geometry: geom,
      );
      final prof = passElevationProfile(pass);
      // km 0 is geometry.first, which is nearest the END foot (1400 m).
      expect(prof.first.ele, 1400);
      expect(prof.last.ele, 900);
    });

    test('merges a col that sits right at a foot (no vertical spike)', () {
      // Col coincides with the start foot (high plateau approach).
      final geom = _line(11, 10000);
      final pass = Pass(
        name: 'Umbrail-like',
        lat: geom.first.latitude,
        lon: geom.first.longitude, // col == start foot
        cantons: const [],
        summitEle: 2500,
        start: PassPoint(
            lat: geom.first.latitude, lon: geom.first.longitude, ele: 2495),
        end: PassPoint(
            lat: geom.last.latitude, lon: geom.last.longitude, ele: 1426),
        geometry: geom,
      );
      final prof = passElevationProfile(pass);
      // Start foot + col merge into one high anchor, then the long descent.
      expect(prof.length, 2);
      expect(prof.first.km, closeTo(0, 0.01));
      expect(prof.first.ele, 2500); // summit wins the merge
      expect(prof.last.ele, 1426);
    });

    test('returns nothing without a summit or any foot height', () {
      final geom = _line(5, 4000);
      final noSummit = Pass(
        name: 'x',
        lat: geom[2].latitude,
        lon: geom[2].longitude,
        cantons: const [],
        start: PassPoint(
            lat: geom.first.latitude, lon: geom.first.longitude, ele: 900),
        geometry: geom,
      );
      expect(passElevationProfile(noSummit), isEmpty);

      final noFeet = Pass(
        name: 'y',
        lat: geom[2].latitude,
        lon: geom[2].longitude,
        cantons: const [],
        summitEle: 2000,
        geometry: geom,
      );
      expect(passElevationProfile(noFeet), isEmpty);
    });
  });

  group('detailedPassProfile', () {
    test('pairs each geometry vertex with its elevation by distance', () {
      final geom = _line(5, 4000); // 5 pts over 4 km → 1 km spacing
      final eles = [1000.0, 1200.0, 1500.0, 1300.0, 900.0];
      final prof = detailedPassProfile(geom, eles);
      expect(prof.length, 5);
      expect(prof.first.km, closeTo(0, 0.01));
      expect(prof.last.km, closeTo(4.0, 0.05));
      expect(prof[2].km, closeTo(2.0, 0.05));
      expect(prof[2].ele, 1500);
      // Distances increase monotonically.
      for (var i = 1; i < prof.length; i++) {
        expect(prof[i].km, greaterThanOrEqualTo(prof[i - 1].km));
      }
    });

    test('returns nothing when lengths mismatch', () {
      final geom = _line(5, 4000);
      expect(detailedPassProfile(geom, [1.0, 2.0]), isEmpty);
      expect(detailedPassProfile(geom, const []), isEmpty);
    });
  });

  group('eleAtKm', () {
    final pts = [
      const PassElevationPoint(km: 0, ele: 1000),
      const PassElevationPoint(km: 2, ele: 2000),
      const PassElevationPoint(km: 4, ele: 1000),
    ];
    test('interpolates within a segment', () {
      expect(eleAtKm(pts, 1), closeTo(1500, 0.001)); // halfway up
      expect(eleAtKm(pts, 3), closeTo(1500, 0.001)); // halfway down
      expect(eleAtKm(pts, 2), 2000);
    });
    test('clamps past the ends', () {
      expect(eleAtKm(pts, -1), 1000);
      expect(eleAtKm(pts, 99), 1000);
    });
  });

  group('pointAlongGeometry', () {
    test('walks the polyline by distance and clamps to the ends', () {
      final geom = _line(5, 4000);
      final cum = [
        0.0,
        for (var i = 1; i < geom.length; i++) i * 1000.0,
      ];
      final mid = pointAlongGeometry(geom, cum, 2000);
      expect(mid.latitude, closeTo(geom[2].latitude, 1e-6));
      expect(mid.longitude, closeTo(geom[2].longitude, 1e-4));
      // Clamps.
      expect(pointAlongGeometry(geom, cum, -5).longitude,
          closeTo(geom.first.longitude, 1e-9));
      expect(pointAlongGeometry(geom, cum, 999999).longitude,
          closeTo(geom.last.longitude, 1e-9));
    });
  });

  group('parsePassElevations', () {
    test('reads the elevations map keyed by id', () {
      const json = '{"_attribution":"x",'
          '"elevations":{"123":[1000,1100,1200],"Foo":[800.5,810]}}';
      final m = parsePassElevations(json);
      expect(m['123'], [1000.0, 1100.0, 1200.0]);
      expect(m['Foo'], [800.5, 810.0]);
    });
    test('tolerates junk', () {
      expect(parsePassElevations('[]'), isEmpty);
      expect(parsePassElevations('{"nope":1}'), isEmpty);
    });
  });
}
