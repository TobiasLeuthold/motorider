import 'package:latlong2/latlong.dart';

/// Serialises a planned route into a standard **GPX 1.1** document so the rider
/// can hand a tour to Garmin BaseCamp, Komoot, OsmAnd, Calimoto, … .
///
/// The document holds one `<trk>` with a single `<trkseg>` containing one
/// `<trkpt>` per [geometry] point (the routed line), preceded by one `<wpt>`
/// per rider-placed [waypoints] entry (start, vias, end). [name] is reused for
/// both the document and the track and is XML-escaped; coordinates are the only
/// other variable data and are pure numbers.
///
/// Dependency-free on purpose: the XML is built by hand (only `latlong2`, which
/// the app already uses, is imported) so export adds no parser/encoder package.
String buildGpx({
  required String name,
  required List<LatLng> geometry,
  required List<LatLng> waypoints,
}) {
  final safeName = _escapeXml(name);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="MotoRider" '
        'xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
        'http://www.topografix.com/GPX/1/1/gpx.xsd">')
    ..writeln('  <metadata>')
    ..writeln('    <name>$safeName</name>')
    ..writeln('  </metadata>');

  // Rider-placed control points as named waypoints (start / vias / end).
  for (var i = 0; i < waypoints.length; i++) {
    final w = waypoints[i];
    final label = _escapeXml(_waypointLabel(i, waypoints.length));
    b
      ..writeln('  <wpt lat="${_coord(w.latitude)}" lon="${_coord(w.longitude)}">')
      ..writeln('    <name>$label</name>')
      ..writeln('  </wpt>');
  }

  // The routed line as a single track segment.
  b
    ..writeln('  <trk>')
    ..writeln('    <name>$safeName</name>')
    ..writeln('    <trkseg>');
  for (final p in geometry) {
    b.writeln(
        '      <trkpt lat="${_coord(p.latitude)}" lon="${_coord(p.longitude)}"/>');
  }
  b
    ..writeln('    </trkseg>')
    ..writeln('  </trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// A filesystem-safe `.gpx` file name derived from a tour [name], e.g.
/// `"Tour 16.06."` → `"Tour_16.06.gpx"`. Falls back to `route.gpx` when the
/// name has no usable characters.
String gpxFilename(String name) {
  final base = name.trim();
  final cleaned = base
      .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  return '${cleaned.isEmpty ? 'route' : cleaned}.gpx';
}

/// German label for the [i]-th of [count] waypoints: first is the start, last
/// the destination, anything between is a numbered via.
String _waypointLabel(int i, int count) {
  if (i == 0) return 'Start';
  if (i == count - 1) return 'Ziel';
  return 'Wegpunkt $i';
}

/// Fixed 7-decimal coordinate (~11 mm), enough to round-trip exactly through a
/// GPX consumer and to keep the output deterministic (no locale/exponent
/// surprises from `double.toString`).
String _coord(double v) => v.toStringAsFixed(7);

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
