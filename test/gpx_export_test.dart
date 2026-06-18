import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motorider/services/gpx_export.dart';
import 'package:xml/xml.dart';

void main() {
  // A tiny tour: 3 control points, a 5-point routed line between them.
  final waypoints = const [
    LatLng(46.8182, 8.2275),
    LatLng(46.9000, 8.3000),
    LatLng(47.0000, 8.4500),
  ];
  final geometry = const [
    LatLng(46.8182000, 8.2275000),
    LatLng(46.8500123, 8.2600456),
    LatLng(46.9000000, 8.3000000),
    LatLng(46.9500789, 8.3700321),
    LatLng(47.0000000, 8.4500000),
  ];

  group('buildGpx', () {
    test('produces well-formed, parseable XML', () {
      final gpx = buildGpx(
          name: 'Sonntagstour', geometry: geometry, waypoints: waypoints);
      // Throws XmlParserException on malformed XML — the assertion is that it
      // does not.
      final doc = XmlDocument.parse(gpx);
      final root = doc.rootElement;
      expect(root.name.local, 'gpx');
      expect(root.getAttribute('version'), '1.1');
      expect(root.getAttribute('creator'), 'MotoRider');
      expect(root.getAttribute('xmlns'),
          'http://www.topografix.com/GPX/1/1');
    });

    test('emits exactly one <trkpt> per geometry point', () {
      final gpx =
          buildGpx(name: 'T', geometry: geometry, waypoints: waypoints);
      final doc = XmlDocument.parse(gpx);
      final trkpts = doc.findAllElements('trkpt').toList();
      expect(trkpts.length, geometry.length);

      // Single track / single segment.
      expect(doc.findAllElements('trk').length, 1);
      expect(doc.findAllElements('trkseg').length, 1);
    });

    test('emits one <wpt> per waypoint', () {
      final gpx =
          buildGpx(name: 'T', geometry: geometry, waypoints: waypoints);
      final doc = XmlDocument.parse(gpx);
      expect(doc.findAllElements('wpt').length, waypoints.length);
    });

    test('coordinates round-trip through the XML', () {
      final gpx =
          buildGpx(name: 'T', geometry: geometry, waypoints: waypoints);
      final doc = XmlDocument.parse(gpx);
      final trkpts = doc.findAllElements('trkpt').toList();
      for (var i = 0; i < geometry.length; i++) {
        final lat = double.parse(trkpts[i].getAttribute('lat')!);
        final lon = double.parse(trkpts[i].getAttribute('lon')!);
        expect(lat, closeTo(geometry[i].latitude, 1e-7));
        expect(lon, closeTo(geometry[i].longitude, 1e-7));
      }
      // Waypoints round-trip too.
      final wpts = doc.findAllElements('wpt').toList();
      for (var i = 0; i < waypoints.length; i++) {
        expect(double.parse(wpts[i].getAttribute('lat')!),
            closeTo(waypoints[i].latitude, 1e-7));
        expect(double.parse(wpts[i].getAttribute('lon')!),
            closeTo(waypoints[i].longitude, 1e-7));
      }
    });

    test('XML-escapes the route name', () {
      final gpx = buildGpx(
        name: 'Tom & Jerry <"Bergpass">',
        geometry: geometry,
        waypoints: waypoints,
      );
      // Raw special characters must not leak into the markup …
      expect(gpx.contains('Tom & Jerry'), isFalse);
      expect(gpx.contains('<"Bergpass">'), isFalse);
      expect(gpx, contains('&amp;'));
      expect(gpx, contains('&lt;'));
      expect(gpx, contains('&gt;'));
      expect(gpx, contains('&quot;'));
      // … and the parser must decode them back to the original text.
      final doc = XmlDocument.parse(gpx);
      final trkName = doc.findAllElements('trk').first.getElement('name')!;
      expect(trkName.innerText, 'Tom & Jerry <"Bergpass">');
    });

    test('names the first and last waypoints Start / Ziel', () {
      final gpx =
          buildGpx(name: 'T', geometry: geometry, waypoints: waypoints);
      final doc = XmlDocument.parse(gpx);
      final names = doc
          .findAllElements('wpt')
          .map((w) => w.getElement('name')!.innerText)
          .toList();
      expect(names.first, 'Start');
      expect(names.last, 'Ziel');
      expect(names[1], 'Wegpunkt 1');
    });

    test('handles an empty geometry without producing trkpts', () {
      final gpx = buildGpx(name: 'Leer', geometry: const [], waypoints: const [
        LatLng(46.0, 8.0),
        LatLng(46.1, 8.1),
      ]);
      final doc = XmlDocument.parse(gpx);
      expect(doc.findAllElements('trkpt'), isEmpty);
      expect(doc.findAllElements('wpt').length, 2);
    });
  });

  group('gpxFilename', () {
    test('keeps a clean name and swaps spaces for underscores', () {
      expect(gpxFilename('Bergpass'), 'Bergpass.gpx');
      // Trailing dot is trimmed rather than producing a double-dot extension.
      expect(gpxFilename('Tour 16.06.'), 'Tour_16.06.gpx');
    });

    test('preserves German/Swiss umlauts and other Unicode letters', () {
      expect(gpxFilename('Ölberg'), 'Ölberg.gpx');
      expect(gpxFilename('Zürich Tour'), 'Zürich_Tour.gpx');
      expect(gpxFilename('Pässe & Täler'), 'Pässe_Täler.gpx');
      expect(gpxFilename('Süd-Schwyz/Glarus'), 'Süd-SchwyzGlarus.gpx');
    });

    test('strips path-illegal characters, symbols and emoji', () {
      expect(gpxFilename('A/B:C*?'), 'ABC.gpx');
      expect(gpxFilename('🏍️ Sonntag'), 'Sonntag.gpx');
    });

    test('falls back to route.gpx for an unusable name', () {
      expect(gpxFilename('   '), 'route.gpx');
      expect(gpxFilename('/\\:*'), 'route.gpx');
      expect(gpxFilename('...'), 'route.gpx');
    });
  });
}
