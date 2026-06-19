import 'package:flutter_test/flutter_test.dart';
import 'package:motorider/screens/map_screen.dart';
import 'package:motorider/stats/pass_explorer.dart';

/// A throwaway pass at an arbitrary col; only [PassProgress.count] drives the
/// marker styling, so the pass facts here are irrelevant.
const _pass = Pass(
  name: 'Testpass',
  lat: 46.5,
  lon: 8.4,
  cantons: ['UR'],
  ele: 2000,
);

PassProgress _progress(int count) => PassProgress(
      pass: _pass,
      count: count,
      firstDate: count > 0 ? DateTime(2026, 1, 1) : null,
      lastDate: count > 0 ? DateTime(2026, 6, 1) : null,
      rideIds: const [],
    );

void main() {
  group('passMarkerSpec — the on-map styling contract', () {
    test('an uncrossed pass is small, dim, and badgeless', () {
      final spec = passMarkerSpec(_progress(0));
      expect(spec.crossed, isFalse);
      expect(spec.badge, isNull);
      // Distinctly smaller than a crossed pin so 99 dots stay legible.
      expect(spec.size, 14.0);
    });

    test('a single crossing is prominent but shows a glyph, not a count', () {
      final spec = passMarkerSpec(_progress(1));
      expect(spec.crossed, isTrue);
      expect(spec.size, 30.0);
      // ×1 would be noise — only multiple crossings get a number.
      expect(spec.badge, isNull);
    });

    test('multiple crossings get a ×N badge', () {
      expect(passMarkerSpec(_progress(2)).badge, '×2');
      expect(passMarkerSpec(_progress(5)).badge, '×5');
    });

    test('crossed pins are markedly larger than uncrossed ones', () {
      expect(
        passMarkerSpec(_progress(3)).size,
        greaterThan(passMarkerSpec(_progress(0)).size),
      );
    });
  });
}
