import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/curviness.dart';
import 'geo.dart';
import 'maneuvers.dart';

/// A routed line plus its summary stats, as returned by [RoutingService].
class RouteResult {
  const RouteResult({
    required this.geometry,
    required this.distanceM,
    required this.durationS,
    required this.ascentM,
    required this.curviness,
    required this.profile,
    this.maneuvers = const [],
  });

  final List<LatLng> geometry;
  final double distanceM;
  final int durationS;
  final double? ascentM;

  /// Computed curviness score (degrees of turning per km) of [geometry].
  final double curviness;

  /// BRouter profile that produced this line.
  final String profile;

  /// Turn-by-turn maneuvers (from BRouter voice hints) for navigation.
  final List<Maneuver> maneuvers;

  double get distanceKm => distanceM / 1000.0;
  Duration get duration => Duration(seconds: durationS);
}

/// Thrown when a route cannot be computed (network down, no road found,
/// server error). [message] is safe to show to the user.
class RoutingException implements Exception {
  const RoutingException(this.message);
  final String message;
  @override
  String toString() => 'RoutingException: $message';
}

/// Computes motorcycle routes via the public BRouter server
/// (https://brouter.de). BRouter's car/moped profiles keep us on roads a
/// motorcycle may legally use, and its alternative routes give us a curviness
/// lever: for the twisty levels we fetch a few alternatives and keep whichever
/// one [curvinessScore] rates as bendiest.
class RoutingService {
  RoutingService({http.Client? client, this.baseUrl = _defaultBase})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const _defaultBase = 'https://brouter.de/brouter';

  final http.Client _client;
  final bool _ownsClient;
  final String baseUrl;

  /// Route through [waypoints] (at least 2) at the given [curviness].
  Future<RouteResult> route({
    required List<LatLng> waypoints,
    required Curviness curviness,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (waypoints.length < 2) {
      throw const RoutingException('Mindestens zwei Punkte nötig.');
    }
    final lonlats =
        waypoints.map((w) => '${w.longitude},${w.latitude}').join('|');
    final profile = curviness.profile;
    final n = curviness.alternatives;

    // idx 0 is required; extra alternatives are best-effort (a profile may
    // offer fewer than we ask for).
    final base = await _fetchOne(lonlats, profile, 0, timeout);
    if (n <= 1) return base;

    final extras = await Future.wait([
      for (var i = 1; i < n; i++)
        _fetchOne(lonlats, profile, i, timeout)
            .then<RouteResult?>((r) => r)
            .catchError((Object _) => null),
    ]);

    var best = base;
    for (final r in extras) {
      if (r != null && r.curviness > best.curviness) best = r;
    }
    return best;
  }

  Future<RouteResult> _fetchOne(
    String lonlats,
    String profile,
    int altIdx,
    Duration timeout,
  ) async {
    final uri = Uri.parse(
      '$baseUrl?lonlats=$lonlats&profile=$profile'
      '&alternativeidx=$altIdx&format=geojson&timode=2', // timode=2 → voicehints
    );
    http.Response res;
    try {
      res = await _client.get(uri).timeout(timeout);
    } catch (e) {
      throw RoutingException('Routing nicht erreichbar ($e).');
    }
    if (res.statusCode != 200) {
      throw RoutingException('Routing-Server: HTTP ${res.statusCode}.');
    }
    final body = res.body.trimLeft();
    // BRouter signals errors as a plain-text body (still HTTP 200), e.g.
    // "operation killed" or "..no track found..".
    if (!body.startsWith('{')) {
      final msg = res.body.trim();
      throw RoutingException(
        msg.isEmpty ? 'Keine Route gefunden.' : _humanize(msg),
      );
    }
    return _parse(body, profile);
  }

  static String _humanize(String brouterError) {
    final e = brouterError.toLowerCase();
    if (e.contains('no track') || e.contains('not mapped')) {
      return 'Hier konnte keine Strasse gefunden werden.';
    }
    if (e.contains('killed') || e.contains('timeout')) {
      return 'Routing dauerte zu lange — versuch es nochmal.';
    }
    return brouterError.length > 120
        ? '${brouterError.substring(0, 120)}…'
        : brouterError;
  }

  RouteResult _parse(String body, String profile) {
    final Map<String, Object?> fc;
    try {
      fc = jsonDecode(body) as Map<String, Object?>;
    } catch (_) {
      throw const RoutingException('Antwort des Routing-Servers unlesbar.');
    }
    final features = fc['features'] as List?;
    if (features == null || features.isEmpty) {
      throw const RoutingException('Keine Route gefunden.');
    }
    final feat = features.first as Map<String, Object?>;
    final props = (feat['properties'] as Map?) ?? const {};
    final geom = feat['geometry'] as Map<String, Object?>?;
    final coords = geom?['coordinates'] as List?;
    if (coords == null || coords.length < 2) {
      throw const RoutingException('Route enthält keine Strecke.');
    }
    final pts = <LatLng>[
      for (final c in coords)
        if (c is List && c.length >= 2)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];
    double parseNum(Object? v) =>
        v == null ? 0 : double.tryParse(v.toString()) ?? 0;
    final distanceM = parseNum(props['track-length']);
    var durationS = parseNum(props['total-time']).round();
    // BRouter's `moped` profile (our "maximal kurvig" level) reports
    // moped-speed travel times — far too slow for a motorcycle. Estimate from
    // distance at a realistic average for tight, curvy roads instead.
    if (profile.contains('moped') && distanceM > 0) {
      const curvyAvgKmh = 45.0;
      durationS = (distanceM / 1000.0 / curvyAvgKmh * 3600).round();
    }
    return RouteResult(
      geometry: pts,
      distanceM: distanceM,
      durationS: durationS,
      ascentM: props['filtered ascend'] == null
          ? null
          : parseNum(props['filtered ascend']),
      curviness: curvinessScore(pts),
      profile: profile,
      maneuvers: parseVoicehints(props['voicehints']),
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
