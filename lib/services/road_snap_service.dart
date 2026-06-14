import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// Thrown when an Overpass response can't be parsed. Callers generally treat a
/// failed snap as "no snap" (null) and fall back to the raw point, so this is
/// rarely caught — it mirrors the other services' shape for consistency.
class RoadSnapException implements Exception {
  const RoadSnapException(this.message);
  final String message;
  @override
  String toString() => 'RoadSnapException: $message';
}

/// Snaps a free-dropped point onto the nearest *drivable* road via the public
/// Overpass API (OpenStreetMap).
///
/// Used to soften route "via" points: a rider drops a pin to guide the tour
/// through a village/area, and we pull the route to the nearest real road
/// within a radius instead of forcing BRouter exactly through whatever lane the
/// pin happened to land on. The pin itself stays put as a visual guide — only
/// the coordinate handed to the router moves.
///
/// Only through-roads a motorcycle would actually ride are considered; service
/// roads, tracks, driveways and foot/cycle paths are excluded by the query,
/// which is precisely what stops the "routed me down a tiny lane" detours.
///
/// Swap [baseUrl] to a self-hosted Overpass instance (e.g. on the NAS) later
/// without touching callers.
class RoadSnapService {
  RoadSnapService({http.Client? client, this.baseUrl = _defaultBase})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const _defaultBase = 'https://overpass-api.de/api/interpreter';
  static const _userAgent = 'MotoRider/1.0 (ch.tleuthold.motorider)';

  /// Highway classes worth routing a motorcycle onto. Deliberately excludes
  /// service / track / path / footway / cycleway / steps / pedestrian so a via
  /// never snaps to a driveway, trail or parking aisle.
  static const _drivable =
      'motorway|motorway_link|trunk|trunk_link|primary|primary_link|'
      'secondary|secondary_link|tertiary|tertiary_link|unclassified|'
      'residential|living_street|road';

  final http.Client _client;
  final bool _ownsClient;
  final String baseUrl;

  // Geographic answers are stable, so cache by ~1 m-quantised coordinate to
  // avoid re-querying Overpass on every reroute (curviness tweaks, adding a
  // later via, dragging a different pin). Only real answers are cached;
  // transport failures are not, so they can be retried.
  final Map<String, LatLng?> _cache = {};

  /// Nearest drivable road point to [p] within [radiusMeters], or null if none
  /// is found within range (or the lookup fails — callers fall back to [p]).
  Future<LatLng?> nearestRoad(
    LatLng p, {
    double radiusMeters = 500,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final key = _cacheKey(p, radiusMeters);
    if (_cache.containsKey(key)) return _cache[key];

    final query = '[out:json][timeout:25];'
        'way["highway"~"^($_drivable)\$"]'
        '(around:${radiusMeters.round()},${p.latitude},${p.longitude});'
        'out geom;';

    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(baseUrl),
            headers: const {'User-Agent': _userAgent},
            body: {'data': query},
          )
          .timeout(timeout);
    } catch (_) {
      return null; // network/timeout — don't cache, let a later reroute retry
    }
    if (res.statusCode != 200) return null; // incl. 429 rate-limit → retry later

    try {
      final snapped = nearestInBody(res.body, p, radiusMeters);
      _cache[key] = snapped; // geographic result is stable — safe to remember
      return snapped;
    } on RoadSnapException {
      return null;
    }
  }

  /// Pure nearest-point selection over an Overpass `out geom` response: returns
  /// the closest point lying on any returned way, provided it is within
  /// [radiusMeters] of [p]; otherwise null. Exposed for testing.
  static LatLng? nearestInBody(String body, LatLng p, double radiusMeters) {
    final Map<String, Object?> json;
    try {
      json = jsonDecode(body) as Map<String, Object?>;
    } catch (_) {
      throw const RoadSnapException('Overpass-Antwort unlesbar.');
    }
    final elements = json['elements'] as List? ?? const [];
    LatLng? best;
    var bestD = double.infinity;
    for (final e in elements) {
      if (e is! Map) continue;
      final geom = e['geometry'] as List?;
      if (geom == null || geom.length < 2) continue;
      final nodes = <LatLng>[
        for (final g in geom)
          if (g is Map && g['lat'] is num && g['lon'] is num)
            LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
      ];
      if (nodes.length < 2) continue;
      final snap = snapToPath(p, nodes);
      if (snap == null) continue;
      if (snap.crossTrackMeters < bestD) {
        bestD = snap.crossTrackMeters;
        best = snap.point;
      }
    }
    return (best != null && bestD <= radiusMeters) ? best : null;
  }

  static String _cacheKey(LatLng p, double radiusMeters) =>
      '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}'
      '@${radiusMeters.round()}';

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
