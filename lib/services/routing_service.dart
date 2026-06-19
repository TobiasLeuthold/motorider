import 'dart:async';
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

/// Fuse per-leg [RouteResult]s (in tour order, as produced by
/// [RoutingService.routeLegs]) into a single end-to-end route:
///
///  * geometries are joined, dropping the duplicate shared node where one leg
///    ends and the next begins (the last point of leg i equals the first point
///    of leg i+1, since both are routed to/from the same waypoint),
///  * distance, duration and ascent are summed,
///  * the overall [RouteResult.curviness] is recomputed from the joined line
///    (so a mixed-curviness tour reports its true °/km, not a leg average),
///  * maneuvers are concatenated with each leg's `geometryIndex` shifted by the
///    running length of the joined geometry, so they keep pointing at the right
///    vertex after the shared-node de-duplication.
///
/// The [RouteResult.profile] is the common leg profile, or `'mixed'` when legs
/// used different ones.
RouteResult concatRouteLegs(List<RouteResult> legs) {
  if (legs.isEmpty) {
    throw const RoutingException('Keine Route gefunden.');
  }
  if (legs.length == 1) return legs.first;

  final geometry = <LatLng>[];
  final maneuvers = <Maneuver>[];
  var distanceM = 0.0;
  var durationS = 0;
  double? ascentM;

  for (var i = 0; i < legs.length; i++) {
    final leg = legs[i];
    // Points already in the joined line before this leg is appended. For legs
    // after the first we skip their first point (the shared node) and shift
    // their maneuver indices so index 0 maps back onto that shared node, which
    // now lives at `base - 1` (the previous leg's last point).
    final base = geometry.length;
    if (i == 0) {
      geometry.addAll(leg.geometry);
      maneuvers.addAll(leg.maneuvers);
    } else {
      geometry.addAll(leg.geometry.skip(1));
      for (final m in leg.maneuvers) {
        maneuvers.add(Maneuver(
          geometryIndex: base - 1 + m.geometryIndex,
          command: m.command,
          exitNumber: m.exitNumber,
        ));
      }
    }

    distanceM += leg.distanceM;
    durationS += leg.durationS;
    if (leg.ascentM != null) ascentM = (ascentM ?? 0) + leg.ascentM!;
  }

  final profiles = {for (final l in legs) l.profile};
  return RouteResult(
    geometry: geometry,
    distanceM: distanceM,
    durationS: durationS,
    ascentM: ascentM,
    curviness: curvinessScore(geometry),
    profile: profiles.length == 1 ? profiles.first : 'mixed',
    maneuvers: maneuvers,
  );
}

/// Default distance (meters) the rider may be from a planned route's start
/// before navigation inserts a "lead-in" leg that first guides them to the
/// start. Below this the rider is treated as already at the start (GPS jitter,
/// parked on the verge, etc.) and the planned route is navigated unchanged.
const double kLeadInThresholdM = 100.0;

/// Whether navigation should route the rider from [current] to the planned
/// [start] before following the planned route. True only when [current] is a
/// real, known position more than [thresholdM] away from the start.
bool needsLeadIn(
  LatLng? current,
  LatLng start, {
  double thresholdM = kLeadInThresholdM,
}) {
  if (current == null) return false;
  return haversineMeters(current, start) > thresholdM;
}

/// Stitch a [leadIn] connector route (rider's current location → planned start)
/// in front of the [planned] route, producing one continuous [RouteResult] that
/// guidance, the map line and the maneuvers all follow seamlessly.
///
/// The [planned] route is preserved verbatim (its geometry, maneuvers and the
/// final destination are unchanged); only the connector is prepended. Where the
/// lead-in ends and the planned route begins they meet at the planned start, so
/// the lead-in's last point (a near-duplicate of the planned first point) is
/// dropped to avoid a zero-length segment, and the planned maneuvers are shifted
/// to point at their new vertex indices in the joined line.
RouteResult prependLeadIn(RouteResult leadIn, RouteResult planned) {
  if (leadIn.geometry.length < 2) return planned;

  // Drop the lead-in's final vertex (it coincides with the planned start) so the
  // shared node appears once, then the whole planned line follows.
  final lead = leadIn.geometry.sublist(0, leadIn.geometry.length - 1);
  final geometry = <LatLng>[...lead, ...planned.geometry];
  final offset = lead.length; // where the planned route's vertex 0 now lives

  final maneuvers = <Maneuver>[
    // Keep only the lead-in's real turns (a trailing "arrive at start" hint
    // would falsely look like the destination); their indices are unaffected.
    for (final m in leadIn.maneuvers)
      if (m.geometryIndex < lead.length) m,
    for (final m in planned.maneuvers)
      Maneuver(
        geometryIndex: offset + m.geometryIndex,
        command: m.command,
        exitNumber: m.exitNumber,
      ),
  ];

  return RouteResult(
    geometry: geometry,
    distanceM: leadIn.distanceM + planned.distanceM,
    durationS: leadIn.durationS + planned.durationS,
    ascentM: planned.ascentM == null && leadIn.ascentM == null
        ? null
        : (leadIn.ascentM ?? 0) + (planned.ascentM ?? 0),
    curviness: curvinessScore(geometry),
    profile: leadIn.profile == planned.profile ? planned.profile : 'mixed',
    maneuvers: maneuvers,
  );
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

  /// Caps how many requests hit the public BRouter server at once. Per-leg
  /// routing with alternatives can otherwise fan out into a dozen simultaneous
  /// requests, which the free server's frontend answers with HTTP 400/429.
  /// Three in-flight keeps us fast without bursting it.
  final _gate = _RequestGate(3);

  /// Total tries per request before giving up (1 initial + 2 retries).
  static const _maxAttempts = 3;

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

  /// Route each leg of [waypoints] with its own [legCurviness] level and return
  /// the per-leg results in order. With N waypoints there are N-1 legs, so
  /// `legCurviness.length` must equal `waypoints.length - 1`. Legs are fetched
  /// concurrently; if any leg fails the whole call throws (a tour is only
  /// useful end-to-end). Use [concatRouteLegs] to fuse the results into a
  /// single [RouteResult], or keep the list to colour each leg separately.
  Future<List<RouteResult>> routeLegs({
    required List<LatLng> waypoints,
    required List<Curviness> legCurviness,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (waypoints.length < 2) {
      throw const RoutingException('Mindestens zwei Punkte nötig.');
    }
    if (legCurviness.length != waypoints.length - 1) {
      throw const RoutingException('Kurvigkeit pro Abschnitt fehlt.');
    }
    return Future.wait([
      for (var i = 0; i < waypoints.length - 1; i++)
        route(
          waypoints: [waypoints[i], waypoints[i + 1]],
          curviness: legCurviness[i],
          timeout: timeout,
        ),
    ]);
  }

  /// Convenience: [routeLegs] then [concatRouteLegs] into one [RouteResult].
  Future<RouteResult> routePerLeg({
    required List<LatLng> waypoints,
    required List<Curviness> legCurviness,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final legs = await routeLegs(
      waypoints: waypoints,
      legCurviness: legCurviness,
      timeout: timeout,
    );
    return concatRouteLegs(legs);
  }

  Future<RouteResult> _fetchOne(
    String lonlats,
    String profile,
    int altIdx,
    Duration timeout,
  ) {
    final uri = Uri.parse(
      '$baseUrl?lonlats=$lonlats&profile=$profile'
      '&alternativeidx=$altIdx&format=geojson&timode=2', // timode=2 → voicehints
    );
    // Run through the gate so concurrent legs/alternatives don't burst the
    // server, and retry transient frontend errors (the 400/429/5xx it returns
    // under load) with a short backoff before surfacing an error to the rider.
    return _gate.run(() => _fetchWithRetry(uri, profile, timeout));
  }

  Future<RouteResult> _fetchWithRetry(
    Uri uri,
    String profile,
    Duration timeout,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      http.Response res;
      try {
        res = await _client.get(uri).timeout(timeout);
      } on TimeoutException {
        // A genuine timeout is slow; don't stack more of them.
        throw const RoutingException(
            'Routing dauerte zu lange — versuch es nochmal.');
      } catch (e) {
        // Fast network hiccup (reset/DNS) — worth one more try.
        lastError = e;
        if (attempt < _maxAttempts) {
          await _backoff(attempt);
          continue;
        }
        throw RoutingException('Routing nicht erreichbar ($e).');
      }

      if (res.statusCode == 200) return _handleBody(res, profile);

      // The free BRouter frontend rejects bursts with 400/429/5xx; these clear
      // on a retry once the gate has drained. Genuinely bad requests don't
      // happen here (coordinates are always well-formed), so retrying is safe.
      if (_retryable(res.statusCode) && attempt < _maxAttempts) {
        lastError = res.statusCode;
        await _backoff(attempt);
        continue;
      }
      throw RoutingException('Routing-Server: HTTP ${res.statusCode}.');
    }
    throw RoutingException('Routing fehlgeschlagen ($lastError).');
  }

  RouteResult _handleBody(http.Response res, String profile) {
    final body = res.body.trimLeft();
    // BRouter signals routing errors as a plain-text body (still HTTP 200), e.g.
    // "operation killed" or "..no track found..". These are permanent for the
    // given points, so they are not retried.
    if (!body.startsWith('{')) {
      final msg = res.body.trim();
      throw RoutingException(
        msg.isEmpty ? 'Keine Route gefunden.' : _humanize(msg),
      );
    }
    return _parse(body, profile);
  }

  static bool _retryable(int status) =>
      status == 400 ||
      status == 408 ||
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504;

  /// Increasing backoff between attempts: ~400 ms, then ~900 ms.
  static Future<void> _backoff(int attempt) =>
      Future<void>.delayed(Duration(milliseconds: 100 + 300 * attempt * attempt));

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

/// A tiny async semaphore: at most [maxConcurrent] tasks run at once, the rest
/// queue FIFO. Keeps the routing fan-out from overwhelming the free server.
class _RequestGate {
  _RequestGate(this.maxConcurrent);
  final int maxConcurrent;

  int _active = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= maxConcurrent) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}
