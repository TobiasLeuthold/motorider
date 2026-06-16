import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/models/curviness.dart';
import 'package:motorider/models/planned_route.dart';

void main() {
  PlannedRoute route({
    List<LatLng>? waypoints,
    Curviness curviness = Curviness.balanced,
    List<Curviness> legCurviness = const [],
  }) =>
      PlannedRoute(
        name: 'Test',
        waypoints: waypoints ??
            const [LatLng(46.0, 8.0), LatLng(46.1, 8.1), LatLng(46.2, 8.2)],
        curviness: curviness,
        legCurviness: legCurviness,
      );

  group('legCurviness round-trip', () {
    test('toMap/fromMap preserves the per-leg list', () {
      final r = route(legCurviness: const [Curviness.fast, Curviness.extra]);
      final back = PlannedRoute.fromMap(r.toMap());
      expect(back.legCurviness, const [Curviness.fast, Curviness.extra]);
    });

    test('encode/decode is a JSON int array of enum indices', () {
      final json = PlannedRoute.encodeCurviness(
          const [Curviness.fast, Curviness.curvy, Curviness.extra]);
      expect(json, '[0,2,3]');
      expect(
        PlannedRoute.decodeCurviness(json),
        const [Curviness.fast, Curviness.curvy, Curviness.extra],
      );
    });

    test('copyWith carries legCurviness', () {
      final r = route().copyWith(legCurviness: const [Curviness.curvy, Curviness.fast]);
      expect(r.legCurviness, const [Curviness.curvy, Curviness.fast]);
    });
  });

  group('scalar fallback for old tours', () {
    test('empty legCurviness → every leg uses the scalar curviness', () {
      // Simulates a tour saved before per-leg curviness existed.
      final old = route(curviness: Curviness.curvy); // legCurviness == []
      expect(old.legCurviness, isEmpty);
      expect(
        old.effectiveLegCurviness(),
        const [Curviness.curvy, Curviness.curvy], // 3 waypoints → 2 legs
      );
    });

    test('a missing leg_curviness_json column decodes to empty', () {
      // An old DB row predating the column has no such key at all.
      final m = route(curviness: Curviness.extra).toMap()
        ..remove('leg_curviness_json');
      final back = PlannedRoute.fromMap(m);
      expect(back.legCurviness, isEmpty);
      expect(back.effectiveLegCurviness(),
          const [Curviness.extra, Curviness.extra]);
    });

    test('explicit per-leg values are used as-is, no fallback', () {
      final r = route(
        curviness: Curviness.balanced,
        legCurviness: const [Curviness.fast, Curviness.extra],
      );
      expect(r.effectiveLegCurviness(),
          const [Curviness.fast, Curviness.extra]);
    });

    test('a partial list pads the remaining legs with the scalar', () {
      // Defensive: fewer entries than legs → tail falls back to the scalar.
      final r = route(
        waypoints: const [
          LatLng(46.0, 8.0),
          LatLng(46.1, 8.1),
          LatLng(46.2, 8.2),
          LatLng(46.3, 8.3),
        ], // 3 legs
        curviness: Curviness.balanced,
        legCurviness: const [Curviness.fast],
      );
      expect(r.effectiveLegCurviness(), const [
        Curviness.fast,
        Curviness.balanced,
        Curviness.balanced,
      ]);
    });

    test('fewer than two waypoints has no legs', () {
      final r = route(waypoints: const [LatLng(46.0, 8.0)]);
      expect(r.effectiveLegCurviness(), isEmpty);
    });
  });
}
