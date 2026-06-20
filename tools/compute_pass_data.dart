// Builds the full Swiss-pass dataset (assets/data/passes_ch.json) — "Pässe v2".
//
// A pass is no longer a single col point: it is a *road segment* running from
// the foot of the climb on one side, up over the col, down to the foot on the
// other side. This tool, for every curated pass, derives that segment and all
// the per-pass facts from OpenStreetMap geometry + SRTM elevation:
//
//   1. Fetch the drivable road network in a box around the col (Overpass).
//   2. Walk the connected road outward from the col in BOTH directions,
//      greedily staying on the same road (prefer same `ref`/`name`, then the
//      straightest continuation) up to a generous distance cap.
//   3. Sample SRTM elevation along each side (opentopodata) and locate each
//      "foot": the valley-floor end of the sustained climb — the lowest point
//      reached before the road clearly starts climbing again (or the cap).
//   4. Trim the polyline to [startFoot … col … endFoot], then compute:
//        start/end  {lat,lon,ele}     — the two feet
//        summitEle                    — the col elevation (SRTM)
//        heightGainM                  — summit minus the LOWER foot (the climb)
//        netDiffM                     — end ele minus start ele
//        lengthKm                     — road distance start→end over the col
//        maxGradientPct               — steepest ~250 m segment along the way
//        hairpins, curvinessScore     — over the full trimmed segment
//        geometry                     — the segment polyline, downsampled to
//                                       ≤ ~60 points (col + both feet kept)
//
// The curated list of passes (col coord, cantons, connects, osmId) is embedded
// below — see `_seed`. Re-curation lives here, in code, so it is reviewable.
//
// Run from the package root:
//   dart run tools/compute_pass_data.dart                    # all passes
//   dart run tools/compute_pass_data.dart --only Furkapass,Grimselpass
//   dart run tools/compute_pass_data.dart --dry-run          # don't write file
//   dart run tools/compute_pass_data.dart --limit 5          # first N (debug)
//
// Derived fields are approximate (geometry + 30 m DEM), reproducible modulo
// OSM/SRTM edits. Network: public Overpass mirrors + opentopodata.org (≤100
// locations/req, ~1 req/s) — the tool self-throttles and fails over.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

const String _assetPath = 'assets/data/passes_ch.json';

const List<String> _overpassEndpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

// opentopodata public instance: SRTM 30 m, 100 locations/request, ~1 req/s.
const String _elevationEndpoint = 'https://api.opentopodata.org/v1/srtm30m';

// Public Overpass/opentopodata servers rate-limit (HTTP 429) requests that lack
// a meaningful User-Agent, so identify ourselves on every call.
const Map<String, String> _ua = {
  'User-Agent':
      'MotoRider/1.0 (personal Swiss-pass dataset build; contact: tobias.leuthold@voviva.ch)',
};

// ───────────────────────── geometry helpers ─────────────────────────
// Kept in sync with lib/services/geo.dart (curvinessScore especially).

const double _earthRadiusM = 6371000.0;
double _deg2rad(double d) => d * math.pi / 180.0;

class LatLng {
  const LatLng(this.lat, this.lon);
  final double lat;
  final double lon;
}

double _haversine(LatLng a, LatLng b) {
  final dLat = _deg2rad(b.lat - a.lat);
  final dLon = _deg2rad(b.lon - a.lon);
  final la1 = _deg2rad(a.lat);
  final la2 = _deg2rad(b.lat);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * _earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

double _bearing(LatLng a, LatLng b) {
  final la1 = _deg2rad(a.lat);
  final la2 = _deg2rad(b.lat);
  final dLon = _deg2rad(b.lon - a.lon);
  final y = math.sin(dLon) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLon);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}

double _pathLength(List<LatLng> pts) {
  var s = 0.0;
  for (var i = 1; i < pts.length; i++) {
    s += _haversine(pts[i - 1], pts[i]);
  }
  return s;
}

/// Signed smallest difference b2-b1 in (-180, 180].
double _bearingDelta(double b1, double b2) {
  var d = (b2 - b1) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

/// Mirror of geo.dart::curvinessScore — total absolute heading change per km.
double _curviness(List<LatLng> pts) {
  if (pts.length < 3) return 0;
  var turn = 0.0;
  for (var i = 1; i < pts.length - 1; i++) {
    final b1 = _bearing(pts[i - 1], pts[i]);
    final b2 = _bearing(pts[i], pts[i + 1]);
    var d = (b2 - b1).abs() % 360.0;
    if (d > 180.0) d = 360.0 - d;
    turn += d;
  }
  final km = _pathLength(pts) / 1000.0;
  if (km < 0.05) return 0;
  return turn / km;
}

/// Cumulative along-distance to each vertex.
List<double> _cumulative(List<LatLng> pts) {
  final cum = List<double>.filled(pts.length, 0.0);
  for (var i = 1; i < pts.length; i++) {
    cum[i] = cum[i - 1] + _haversine(pts[i - 1], pts[i]);
  }
  return cum;
}

/// Resample a polyline to ~[stepM] spacing (keeps first & last vertex).
List<LatLng> _resample(List<LatLng> pts, double stepM) {
  if (pts.length < 2) return List.of(pts);
  final out = <LatLng>[pts.first];
  var travelled = 0.0;
  var nextAt = stepM;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final segLen = _haversine(a, b);
    if (segLen < 1e-9) continue;
    final segEnd = travelled + segLen;
    while (nextAt <= segEnd) {
      final t = (nextAt - travelled) / segLen;
      out.add(LatLng(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t));
      nextAt += stepM;
    }
    travelled = segEnd;
  }
  if (out.length < 2 || _haversine(out.last, pts.last) > stepM * 0.25) {
    out.add(pts.last);
  }
  return out;
}

/// Linear interpolation of a point at along-distance [d] on the polyline whose
/// cumulative distances are [cum].
LatLng _interpAt(List<LatLng> pts, List<double> cum, double d) {
  if (d <= 0) return pts.first;
  if (d >= cum.last) return pts.last;
  var i = 1;
  while (i < pts.length && cum[i] < d) {
    i++;
  }
  final a = pts[i - 1], b = pts[i];
  final segLen = cum[i] - cum[i - 1];
  final t = segLen <= 0 ? 0.0 : (d - cum[i - 1]) / segLen;
  return LatLng(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
}

/// Downsample a polyline to at most [maxPts] vertices using Douglas–Peucker,
/// guaranteeing the indices in [keep] survive (col + feet). Endpoints always
/// survive.
List<LatLng> _downsample(List<LatLng> pts, int maxPts, Set<int> keep) {
  if (pts.length <= maxPts) return List.of(pts);

  // Perpendicular distance (m) of p from segment a-b, via local equirect.
  double perp(LatLng p, LatLng a, LatLng b) {
    final mPerLat = 111320.0;
    final mPerLon = 111320.0 * math.cos(_deg2rad(p.lat));
    double px(LatLng q) => (q.lon - p.lon) * mPerLon;
    double py(LatLng q) => (q.lat - p.lat) * mPerLat;
    final ax = px(a), ay = py(a), bx = px(b), by = py(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return math.sqrt(ax * ax + ay * ay);
    var t = -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt(cx * cx + cy * cy);
  }

  // Start from the mandatory-keep indices (sorted, incl. endpoints), then keep
  // splitting the segment with the largest perpendicular error until we reach
  // maxPts. This both honours `keep` and gives an even, shape-preserving thin.
  final selected = <int>{0, pts.length - 1, ...keep.where((i) => i > 0 && i < pts.length - 1)};

  while (selected.length < maxPts) {
    final idx = selected.toList()..sort();
    var bestErr = -1.0;
    var bestI = -1;
    for (var s = 0; s < idx.length - 1; s++) {
      final lo = idx[s], hi = idx[s + 1];
      if (hi - lo < 2) continue;
      for (var k = lo + 1; k < hi; k++) {
        final e = perp(pts[k], pts[lo], pts[hi]);
        if (e > bestErr) {
          bestErr = e;
          bestI = k;
        }
      }
    }
    if (bestI < 0) break; // nothing left to split
    selected.add(bestI);
  }

  final idx = selected.toList()..sort();
  return [for (final i in idx) pts[i]];
}

// ───────────────────────── hairpin detector ─────────────────────────
// (verbatim from tools/compute_pass_curves.dart so counts stay comparable)

int _countHairpins(
  List<LatLng> poly, {
  double windowM = 110.0,
  double thresholdDeg = 140.0,
  double stepM = 12.0,
}) {
  if (poly.length < 4) return 0;
  final rs = _resample(poly, stepM);
  if (rs.length < 4) return 0;

  final n = rs.length;
  final delta = List<double>.filled(n, 0.0);
  final segLen = List<double>.filled(n, 0.0);
  for (var i = 1; i < n; i++) {
    segLen[i] = _haversine(rs[i - 1], rs[i]);
  }
  for (var i = 1; i < n - 1; i++) {
    final b1 = _bearing(rs[i - 1], rs[i]);
    final b2 = _bearing(rs[i], rs[i + 1]);
    delta[i] = _bearingDelta(b1, b2);
  }

  var count = 0;
  var armed = true;
  var lo = 1;
  var winTurn = 0.0;
  var winLen = 0.0;

  var hitSign = 0.0;
  var sinceHit = 0.0;
  const straightenM = 80.0;
  const straightenMaxTurnDeg = 45.0;
  var clo = 1;
  var calmTurn = 0.0;
  var calmLen = 0.0;

  for (var i = 1; i < n - 1; i++) {
    winTurn += delta[i];
    winLen += segLen[i];
    while (winLen > windowM && lo < i) {
      lo++;
      winTurn -= delta[lo];
      winLen -= segLen[lo];
    }

    calmTurn += delta[i].abs();
    calmLen += segLen[i];
    while (calmLen > straightenM && clo < i) {
      clo++;
      calmTurn -= delta[clo].abs();
      calmLen -= segLen[clo];
    }

    if (armed) {
      if (winTurn.abs() >= thresholdDeg) {
        count++;
        armed = false;
        hitSign = winTurn.sign;
        sinceHit = 0.0;
        winTurn = 0.0;
        winLen = 0.0;
        lo = i;
      }
    } else {
      sinceHit += delta[i];
      final reversed = hitSign != 0 &&
          sinceHit.sign != hitSign &&
          sinceHit.abs() >= thresholdDeg * 0.45;
      final straightened =
          calmLen >= straightenM * 0.8 && calmTurn <= straightenMaxTurnDeg;
      if (reversed || straightened) {
        armed = true;
      }
    }
  }
  return count;
}

// ───────────────────────── Overpass road graph ─────────────────────────

class _Way {
  _Way(this.id, this.nodes, this.ref, this.name);
  final int id;
  final List<int> nodes;
  final String? ref;
  final String? name;
}

class _RoadGraph {
  _RoadGraph(this.ways, this.nodeCoords, this.nodeToWays);
  final Map<int, _Way> ways;
  final Map<int, LatLng> nodeCoords;
  final Map<int, List<int>> nodeToWays;
}

Future<String> _overpassPost(String query) async {
  Object? lastErr;
  for (var attempt = 0; attempt < _overpassEndpoints.length * 2; attempt++) {
    final ep = _overpassEndpoints[attempt % _overpassEndpoints.length];
    try {
      final resp = await http
          .post(Uri.parse(ep), headers: _ua, body: {'data': query})
          .timeout(const Duration(seconds: 120));
      // A 200 can still carry a rate-limit/HTML notice instead of JSON.
      if (resp.statusCode == 200 && resp.body.trimLeft().startsWith('{')) {
        return resp.body;
      }
      lastErr = resp.statusCode == 200
          ? 'non-JSON body from $ep: ${resp.body.substring(0, math.min(80, resp.body.length))}'
          : 'HTTP ${resp.statusCode} from $ep';
      await Future<void>.delayed(Duration(seconds: 3 + attempt * 2));
    } catch (e) {
      lastErr = e;
      await Future<void>.delayed(Duration(seconds: 2 + attempt));
    }
  }
  throw Exception('Overpass failed: $lastErr');
}

/// Fetch the drivable road graph in a box [radiusM] around (lat,lon).
Future<_RoadGraph> _fetchGraph(double lat, double lon, double radiusM) async {
  const filter =
      '[highway~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|road)\$"]';
  final query = '''
[out:json][timeout:120];
(
  way$filter(around:${radiusM.toStringAsFixed(0)},$lat,$lon);
);
out body geom;
''';
  final body = await _overpassPost(query);
  final doc = jsonDecode(body) as Map<String, dynamic>;
  final elements = (doc['elements'] as List).cast<Map<String, dynamic>>();

  final ways = <int, _Way>{};
  final nodeCoords = <int, LatLng>{};
  final nodeToWays = <int, List<int>>{};

  for (final el in elements) {
    if (el['type'] != 'way') continue;
    final id = (el['id'] as num).toInt();
    final rawNodes = el['nodes'];
    final geom = (el['geometry'] as List?)?.cast<Map<String, dynamic>>();
    if (rawNodes is! List || geom == null) continue;
    final nodeIds = rawNodes.map((e) => (e as num).toInt()).toList();
    if (geom.length != nodeIds.length) continue;
    final tags = (el['tags'] as Map?)?.cast<String, dynamic>();
    for (var i = 0; i < nodeIds.length; i++) {
      final g = geom[i];
      final p =
          LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble());
      nodeCoords[nodeIds[i]] = p;
      (nodeToWays[nodeIds[i]] ??= []).add(id);
    }
    ways[id] = _Way(
      id,
      nodeIds,
      tags?['ref'] as String?,
      tags?['name'] as String?,
    );
  }
  return _RoadGraph(ways, nodeCoords, nodeToWays);
}

/// Find the graph node nearest to [pt] within [maxM], or null.
int? _nearestNode(_RoadGraph g, LatLng pt, {double maxM = 200}) {
  int? best;
  var bestD = maxM;
  for (final e in g.nodeCoords.entries) {
    final d = _haversine(pt, e.value);
    if (d < bestD) {
      bestD = d;
      best = e.key;
    }
  }
  return best;
}

// ───────────────────────── road walking ─────────────────────────

/// One walked vertex: its coordinate and the id of the OSM way the step that
/// reached it travelled along (used to prefer staying on the same road).
class _Step {
  _Step(this.point, this.wayId);
  final LatLng point;
  final int wayId;
}

/// Walk the road outward from [startNode] toward [firstNextNode], following the
/// best continuation at each junction up to [maxLenM]. "Best" = same `ref`,
/// else same `name`, else the straightest (least-bending) edge. Returns the
/// ordered steps (excluding the start point).
List<_Step> _walk(
  _RoadGraph g,
  int startNode,
  int firstNextNode, {
  required double maxLenM,
}) {
  final out = <_Step>[];
  final visitedEdges = <String>{};
  var current = startNode;
  int? prev;
  int? forcedNext = firstNextNode;
  // The way we are currently travelling on, to bias continuations.
  String? curRef;
  String? curName;
  var length = 0.0;
  var guard = 0;

  // Pick the way id connecting a→b (prefer one matching the current road).
  int wayBetween(int a, int b) {
    int? fallback;
    for (final wid in g.nodeToWays[a] ?? const <int>[]) {
      final w = g.ways[wid]!;
      for (var i = 0; i < w.nodes.length; i++) {
        if (w.nodes[i] != a) continue;
        if ((i > 0 && w.nodes[i - 1] == b) ||
            (i < w.nodes.length - 1 && w.nodes[i + 1] == b)) {
          fallback ??= wid;
          final sameRef = curRef != null && w.ref == curRef;
          final sameName = curName != null && w.name == curName;
          if (sameRef || sameName) return wid;
        }
      }
    }
    return fallback ?? (g.nodeToWays[a]?.first ?? -1);
  }

  while (length < maxLenM && guard++ < 8000) {
    final here = g.nodeCoords[current];
    if (here == null) break;

    final neighbours = <int>{};
    for (final wid in g.nodeToWays[current] ?? const <int>[]) {
      final w = g.ways[wid]!;
      for (var i = 0; i < w.nodes.length; i++) {
        if (w.nodes[i] != current) continue;
        if (i > 0) neighbours.add(w.nodes[i - 1]);
        if (i < w.nodes.length - 1) neighbours.add(w.nodes[i + 1]);
      }
    }
    neighbours.remove(prev);

    final int next;
    if (forcedNext != null && neighbours.contains(forcedNext)) {
      next = forcedNext;
      forcedNext = null;
    } else if (neighbours.isEmpty) {
      break;
    } else if (neighbours.length == 1) {
      next = neighbours.first;
    } else {
      final inBearing =
          prev == null ? null : _bearing(g.nodeCoords[prev]!, here);
      // Score: same-road continuations first (rank 0), then by bend.
      double scoreOf(int cand) {
        final w = g.ways[wayBetween(current, cand)];
        final sameRoad =
            (curRef != null && w?.ref == curRef) ||
                (curName != null && w?.name == curName);
        final candP = g.nodeCoords[cand]!;
        final bend = inBearing == null
            ? -_haversine(here, candP) // no heading yet: prefer longest edge
            : _bearingDelta(inBearing, _bearing(here, candP)).abs();
        return (sameRoad ? 0.0 : 1000.0) + bend;
      }

      final sorted = neighbours.toList()
        ..sort((a, b) => scoreOf(a).compareTo(scoreOf(b)));
      next = sorted.first;
    }

    final edgeKey =
        current < next ? '$current-$next' : '$next-$current';
    if (!visitedEdges.add(edgeKey)) break;

    final wid = wayBetween(current, next);
    final w = wid >= 0 ? g.ways[wid] : null;
    // Update the "current road" identity as we move onto a way.
    if (w != null) {
      curRef = w.ref ?? curRef;
      curName = w.name ?? curName;
      // If this way has neither, drop the bias so we don't cling wrongly.
      if (w.ref == null && w.name == null) {
        curRef = null;
        curName = null;
      }
    }

    final nextP = g.nodeCoords[next]!;
    out.add(_Step(nextP, wid));
    length += _haversine(here, nextP);
    prev = current;
    current = next;
  }
  return out;
}

// ───────────────────────── elevation ─────────────────────────

/// Fetch SRTM elevations (m) for [pts] from opentopodata, ≤100 per request,
/// self-throttled to stay under the public rate limit. Returns one value per
/// input point (null on failure for that point).
Future<List<double?>> _elevations(List<LatLng> pts) async {
  final out = <double?>[];
  const batch = 100;
  for (var i = 0; i < pts.length; i += batch) {
    final chunk = pts.sublist(i, math.min(i + batch, pts.length));
    final locs =
        chunk.map((p) => '${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}').join('|');
    Object? lastErr;
    List<double?>? got;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final resp = await http
            .post(Uri.parse(_elevationEndpoint),
                headers: _ua, body: {'locations': locs})
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 200) {
          final doc = jsonDecode(resp.body) as Map<String, dynamic>;
          if (doc['status'] == 'OK') {
            final results = (doc['results'] as List).cast<Map<String, dynamic>>();
            got = [
              for (final r in results)
                r['elevation'] == null ? null : (r['elevation'] as num).toDouble()
            ];
            break;
          }
          lastErr = 'status ${doc['status']}';
        } else {
          lastErr = 'HTTP ${resp.statusCode}';
        }
      } catch (e) {
        lastErr = e;
      }
      await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
    }
    if (got == null) {
      throw Exception('elevation fetch failed: $lastErr');
    }
    out.addAll(got);
    // Public instance: keep comfortably under 1 req/s.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
  }
  return out;
}

// ───────────────────────── foot finding ─────────────────────────

/// Given one side's polyline starting AT the col (index 0, the high end) and
/// running outward + downhill, with a (possibly noisy SRTM) elevation profile,
/// return the along-distance of the "foot": where the sustained descent ends.
///
/// We scan outward and stop at the FIRST of:
///   • a clear rebound — the road has climbed back up by >[reboundM] above the
///     lowest point seen so far (the next valley/hill begins): foot = that low;
///   • a flattening — over a forward [flatWinM] window the road descends by
///     less than [flatGradePct] on average AND we've already dropped a decent
///     amount ([minDropM]) and gone past [minLenM] (we've reached the valley
///     floor, e.g. the town where the ramp meets the through-valley road);
/// otherwise the foot is the lowest point within the distance cap.
///
/// Elevations are pre-smoothed with a short moving average so 30 m-DEM jitter
/// doesn't trip the flatten/rebound tests prematurely.
double _footAlong(
  List<LatLng> side,
  List<double?> eleRaw,
  List<double> cum, {
  double minLenM = 2000,
  double minDropM = 120,
  double reboundM = 35,
  double flatWinM = 1000,
  double flatGradePct = 3.0,
}) {
  if (side.length < 2) return cum.isEmpty ? 0 : cum.last;

  // Forward-fill nulls then smooth (±2 samples ≈ ±300 m at 150 m spacing).
  final n = side.length;
  final filled = List<double>.filled(n, double.nan);
  double? last;
  for (var i = 0; i < n; i++) {
    final e = eleRaw[i];
    if (e != null) last = e;
    if (last != null) filled[i] = last;
  }
  for (var i = n - 1; i >= 0; i--) {
    if (filled[i].isNaN && i + 1 < n) filled[i] = filled[i + 1];
  }
  final ele = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    var cnt = 0;
    for (var k = i - 2; k <= i + 2; k++) {
      if (k >= 0 && k < n && !filled[k].isNaN) {
        sum += filled[k];
        cnt++;
      }
    }
    ele[i] = cnt > 0 ? sum / cnt : (filled[i].isNaN ? 0 : filled[i]);
  }

  final colEle = ele[0];
  var runMin = ele[0];
  var runMinI = 0;

  for (var i = 1; i < n; i++) {
    if (ele[i] < runMin) {
      runMin = ele[i];
      runMinI = i;
    }
    if (cum[i] < minLenM) continue;

    // Rebound: climbed back up clearly above the lowest point → cut at the low.
    if (ele[i] - runMin > reboundM) {
      return cum[runMinI];
    }

    // Flatten: average grade over the next window is gentle, and we've already
    // descended a meaningful amount from the col → valley floor reached.
    if (colEle - ele[i] >= minDropM) {
      var j = i;
      while (j + 1 < n && cum[j] - cum[i] < flatWinM) {
        j++;
      }
      final run = cum[j] - cum[i];
      if (run > flatWinM * 0.5) {
        final drop = ele[i] - ele[j]; // positive if still descending
        final gradePct = drop / run * 100.0;
        if (gradePct < flatGradePct) {
          return cum[i];
        }
      }
    }
  }
  // No flatten/rebound within the cap: use the lowest point reached.
  var along = cum[runMinI];
  if (along < minLenM) along = math.min(minLenM, cum.last);
  return along;
}

// ───────────────────────── per-pass build ─────────────────────────

class _Seed {
  const _Seed(this.name, this.lat, this.lon, this.cantons, this.connects,
      this.osmId);
  final String name;
  final double lat;
  final double lon;
  final List<String> cantons;
  final List<String>? connects;
  final int osmId;
}

class _Built {
  _Built(this.json, this.log);
  final Map<String, dynamic> json;
  final String log;
}

double _round(double v, int dp) {
  final f = math.pow(10, dp);
  return (v * f).round() / f;
}

Future<_Built> _buildPass(_Seed s) async {
  // Reach the valley feet: most Swiss passes' ramps are < 16 km/side. A 20 km
  // box radius covers that with slack at junctions.
  final g = await _fetchGraph(s.lat, s.lon, 20000);
  final colPt = LatLng(s.lat, s.lon);

  var colNode = s.osmId;
  if (colNode == 0 || !g.nodeCoords.containsKey(colNode)) {
    final snapped = _nearestNode(g, colPt, maxM: 250);
    if (snapped == null) {
      throw Exception(
          'no drivable road within 250 m of col node ${s.osmId} '
          '(graph: ${g.ways.length} ways, ${g.nodeCoords.length} nodes)');
    }
    colNode = snapped;
  }
  final col = g.nodeCoords[colNode]!;
  // Record the node we actually anchored to (the seed id, or the snapped one
  // when the seed had no OSM mountain_pass node).
  final anchorOsmId = s.osmId != 0 ? s.osmId : colNode;

  // Two immediate neighbours of the col → seed both walk directions.
  final neighbours = <int>{};
  for (final wid in g.nodeToWays[colNode] ?? const <int>[]) {
    final w = g.ways[wid]!;
    for (var i = 0; i < w.nodes.length; i++) {
      if (w.nodes[i] != colNode) continue;
      if (i > 0) neighbours.add(w.nodes[i - 1]);
      if (i < w.nodes.length - 1) neighbours.add(w.nodes[i + 1]);
    }
  }
  if (neighbours.isEmpty) throw Exception('col node has no road neighbours');

  final nb = neighbours.toList();
  final seedA = nb.first;
  int? seedB;
  if (nb.length >= 2) {
    final bA = _bearing(col, g.nodeCoords[seedA]!);
    double oppScore(int c) {
      final b = _bearing(col, g.nodeCoords[c]!);
      return (180.0 - _bearingDelta(bA, b).abs()).abs();
    }
    final others = nb.where((c) => c != seedA).toList()
      ..sort((a, b) => oppScore(a).compareTo(oppScore(b)));
    seedB = others.first;
  }

  const sideCapM = 16000.0;
  final sideA = [col, ...(_walk(g, colNode, seedA, maxLenM: sideCapM)).map((e) => e.point)];
  final sideB = seedB == null
      ? <LatLng>[col]
      : [col, ...(_walk(g, colNode, seedB, maxLenM: sideCapM)).map((e) => e.point)];

  // Elevation along each side (sample at ~150 m so foot-finding is stable but
  // we stay well under the elevation API budget).
  final sampA = _resample(sideA, 150);
  final sampB = _resample(sideB, 150);
  final colEleList = await _elevations([col]);
  final eleA = sampA.length < 2 ? <double?>[colEleList.first] : await _elevations(sampA);
  final eleB = sampB.length < 2 ? <double?>[colEleList.first] : await _elevations(sampB);

  final colEle = (colEleList.first ?? eleA.first ?? eleB.first);

  final cumA = _cumulative(sampA);
  final cumB = _cumulative(sampB);
  final footAAlong = sideA.length < 2 ? 0.0 : _footAlong(sampA, eleA, cumA);
  final footBAlong = sideB.length < 2 ? 0.0 : _footAlong(sampB, eleB, cumB);

  // Summit = highest point actually on the ridden segment (col node + every
  // sampled point up to each foot). For a true pass this equals the col; for a
  // handful of minor cols whose OSM node isn't the local high point, this keeps
  // the summit at/above both feet so the climb is well-defined.
  double summitEle = colEle ?? -1e9;
  for (var i = 0; i < sampA.length; i++) {
    if (cumA[i] <= footAAlong && eleA[i] != null && eleA[i]! > summitEle) {
      summitEle = eleA[i]!;
    }
  }
  for (var i = 0; i < sampB.length; i++) {
    if (cumB[i] <= footBAlong && eleB[i] != null && eleB[i]! > summitEle) {
      summitEle = eleB[i]!;
    }
  }
  if (summitEle <= -1e8) summitEle = colEle ?? 0;

  // Elevation at each foot (interpolate index in the sampled side).
  double? eleAt(List<double?> ele, List<double> cum, double along) {
    if (ele.isEmpty) return null;
    var i = 0;
    while (i < cum.length - 1 && cum[i] < along) {
      i++;
    }
    return ele[i] ?? (i > 0 ? ele[i - 1] : null);
  }

  final footAPt = sideA.length < 2 ? col : _interpAt(sampA, cumA, footAAlong);
  final footBPt = sideB.length < 2 ? col : _interpAt(sampB, cumB, footBAlong);
  final footAEle = eleAt(eleA, cumA, footAAlong) ?? summitEle;
  final footBEle = eleAt(eleB, cumB, footBAlong) ?? summitEle;

  // Trim each raw side polyline to its foot, then stitch:
  //   foot(B) … col … foot(A)
  List<LatLng> trimTo(List<LatLng> side, double along) {
    if (side.length < 2) return side;
    final cum = _cumulative(side);
    final out = <LatLng>[];
    for (var i = 0; i < side.length; i++) {
      if (cum[i] <= along) {
        out.add(side[i]);
      } else {
        out.add(_interpAt(side, cum, along));
        break;
      }
    }
    if (out.isEmpty) out.add(side.first);
    return out;
  }

  final trimA = trimTo(sideA, footAAlong); // col → footA
  final trimB = trimTo(sideB, footBAlong); // col → footB
  // Full segment: footB … col … footA (B reversed so it ends at the col).
  final segment = <LatLng>[
    ...trimB.reversed,
    ...trimA.skip(1), // skip duplicate col
  ];

  // The "start" is foot B (the reversed side's far end), "end" is foot A.
  final startPt = segment.first;
  final endPt = segment.last;
  final startEle = (footBPt.lat == col.lat && footBPt.lon == col.lon)
      ? summitEle
      : footBEle;
  final endEle = (footAPt.lat == col.lat && footAPt.lon == col.lon)
      ? summitEle
      : footAEle;

  final lengthM = _pathLength(segment);
  final hairpins = _countHairpins(segment);
  final curviness = _curviness(segment);

  // Steepest sustained gradient: sample the trimmed segment at ~125 m, smooth
  // the SRTM profile (±1 sample) to tame 30 m-DEM jitter, then take the max
  // |rise/run| over a ~300 m sliding window. Clamp to 20 % — anything above is
  // DEM noise for a paved Swiss pass road.
  final gradSample = _resample(segment, 125);
  final gradEleRaw =
      gradSample.length < 2 ? <double?>[] : await _elevations(gradSample);
  double maxGrad = 0;
  if (gradEleRaw.length == gradSample.length && gradSample.length >= 2) {
    final gn = gradSample.length;
    final ge = List<double?>.filled(gn, null);
    for (var i = 0; i < gn; i++) {
      var sum = 0.0;
      var cnt = 0;
      for (var k = i - 1; k <= i + 1; k++) {
        if (k >= 0 && k < gn && gradEleRaw[k] != null) {
          sum += gradEleRaw[k]!;
          cnt++;
        }
      }
      if (cnt > 0) ge[i] = sum / cnt;
    }
    final gcum = _cumulative(gradSample);
    for (var i = 0; i < gn; i++) {
      if (ge[i] == null) continue;
      var j = i;
      while (j + 1 < gn && gcum[j] - gcum[i] < 300) {
        j++;
      }
      if (ge[j] == null) continue;
      final run = gcum[j] - gcum[i];
      if (run < 150) continue;
      final grad = (ge[j]! - ge[i]!).abs() / run * 100.0;
      if (grad > maxGrad && grad <= 20) maxGrad = grad;
    }
  }

  // heightGain = summit minus the LOWER foot; netDiff = end minus start.
  final lowerFoot = math.min(startEle, endEle);
  final heightGain = summitEle - lowerFoot;
  final netDiff = endEle - startEle;

  // Downsample geometry to ≤60 pts, keeping start, col, end.
  // Find the col's index in the segment.
  var colIdx = 0;
  var colBest = double.infinity;
  for (var i = 0; i < segment.length; i++) {
    final d = _haversine(segment[i], col);
    if (d < colBest) {
      colBest = d;
      colIdx = i;
    }
  }
  final geom = _downsample(segment, 60, {0, colIdx, segment.length - 1});

  final json = <String, dynamic>{
    'name': s.name,
    'lat': _round(col.lat, 6),
    'lon': _round(col.lon, 6),
    'cantons': s.cantons,
    'connects': s.connects,
    'osmId': anchorOsmId,
    'ele': summitEle.round(),
    'summitEle': summitEle.round(),
    'start': {
      'lat': _round(startPt.lat, 6),
      'lon': _round(startPt.lon, 6),
      'ele': startEle.round(),
    },
    'end': {
      'lat': _round(endPt.lat, 6),
      'lon': _round(endPt.lon, 6),
      'ele': endEle.round(),
    },
    'heightGainM': heightGain.round(),
    'netDiffM': netDiff.round(),
    'lengthKm': _round(lengthM / 1000.0, 2),
    'maxGradientPct': maxGrad == 0 ? null : _round(maxGrad, 1),
    'hairpins': hairpins,
    'curvinessScore': _round(curviness, 1),
    'geometry': [
      for (final p in geom) [_round(p.lat, 5), _round(p.lon, 5)],
    ],
  };

  final log = 'OK    ${s.name}  '
      'ele=${summitEle.round()} start=${startEle.round()} end=${endEle.round()} '
      'gain=${heightGain.round()}m net=${netDiff.round()}m '
      'len=${(lengthM / 1000).toStringAsFixed(1)}km '
      'hp=$hairpins cv=${curviness.round()} '
      'maxGrad=${maxGrad.toStringAsFixed(0)}% '
      'geom=${geom.length}pts';
  return _Built(json, log);
}

// ───────────────────────── main ─────────────────────────

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  Set<String>? only;
  final onlyIdx = args.indexOf('--only');
  if (onlyIdx >= 0 && onlyIdx + 1 < args.length) {
    only = args[onlyIdx + 1].split(',').map((s) => s.trim()).toSet();
  }
  int? limit;
  final limIdx = args.indexOf('--limit');
  if (limIdx >= 0 && limIdx + 1 < args.length) {
    limit = int.tryParse(args[limIdx + 1]);
  }

  var seeds = _seed;
  if (only != null) {
    seeds = seeds.where((s) => only!.contains(s.name)).toList();
  }
  if (limit != null) seeds = seeds.take(limit).toList();

  stdout.writeln('Building ${seeds.length} passes…\n');

  const attribution =
      'Pass data © OpenStreetMap contributors, ODbL (openstreetmap.org/copyright). '
      'Curated subset of paved through-road passes in Switzerland. '
      'Segment geometry, feet, elevations, height gain, length, gradient, '
      'hairpins & curviness are derived from OSM road geometry and SRTM '
      'elevation (opentopodata.org) — approximate.';
  final assetFile = File(_assetPath);

  // Resume: keep any v2 passes already in the asset (they have the new 'start'
  // + 'geometry' fields) so chunked / re-run generation never re-fetches a
  // finished pass and progress survives an interruption.
  final built = <String, Map<String, dynamic>>{};
  if (!dryRun && assetFile.existsSync()) {
    try {
      final prev = jsonDecode(assetFile.readAsStringSync()) as Map<String, dynamic>;
      for (final p in (prev['passes'] as List).cast<Map<String, dynamic>>()) {
        if (p.containsKey('start') && p.containsKey('geometry')) {
          built[p['name'] as String] = p;
        }
      }
    } catch (_) {/* corrupt/old asset → start fresh */}
  }

  void writeAsset() {
    final out = built.values.toList()
      ..sort((a, b) => ((b['ele'] as int?) ?? -1).compareTo((a['ele'] as int?) ?? -1));
    final doc = <String, dynamic>{
      '_attribution': attribution,
      '_count': out.length,
      'passes': out,
    };
    assetFile.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(doc)}\n');
  }

  var ok = 0, failed = 0, skipped = 0;
  for (final s in seeds) {
    if (built.containsKey(s.name)) {
      skipped++;
      continue;
    }
    try {
      final b = await _buildPass(s);
      built[s.name] = b.json;
      stdout.writeln(b.log);
      ok++;
      if (!dryRun) writeAsset(); // persist after every pass
    } catch (e) {
      stdout.writeln('FAIL  ${s.name} — $e');
      failed++;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  stdout.writeln(
      '\nDONE: $ok built, $skipped already present, $failed failed. total=${built.length}');
  if (dryRun) {
    stdout.writeln('(dry-run: no file written)');
    return;
  }
  writeAsset();
  stdout.writeln('Wrote $_assetPath (${built.length} passes)');
}

// ───────────────────────── curated seed list ─────────────────────────
//
// Curation rule: INCLUDE a pass only if it is a paved public through-road pass
// a motorcycle would ride (connects two valleys/roads) AND is significant by
// elevation and/or climb length / prominence / fame. EXCLUDE gravel/track-only,
// dead-end saddles, foot passes, and trivial low local cols.
//
// (name, colLat, colLon, [cantons], connects-or-null, osmNodeId)
//
// All 41 canonical Swiss road passes named in the task are present. Coords +
// osmId verified against the previous dataset / OSM mountain_pass nodes.
const List<_Seed> _seed = [
  // ── High Alpine road passes (the canon) ──
  _Seed('Pass Umbrail - Giogo di Santa Maria', 46.541645, 10.433177,
      ['IT', 'GR'], ['Santa Maria', 'Bormio'], 1847275612),
  _Seed('Nufenenpass / Passo della Novena', 46.477119, 8.387828, ['VS', 'TI'],
      ['Ulrichen', 'Airolo'], 1479101970),
  _Seed('Col du Grand Saint-Bernard', 45.869053, 7.170409, ['IT', 'VS'],
      ['Martigny', 'Aosta'], 2001818936),
  _Seed('Furkapass', 46.572685, 8.415184, ['VS', 'UR'], ['Realp', 'Gletsch'],
      1457531552),
  _Seed('Flüelapass', 46.7475, 9.950284, ['GR'], ['Davos', 'Susch'],
      1456730408),
  _Seed('Passo del Bernina', 46.410926, 10.02762, ['GR'],
      ['Pontresina', 'Poschiavo'], 80118203),
  _Seed('Albulapass', 46.582251, 9.837682, ['GR'], ['Tiefencastel', 'La Punt'],
      529654944),
  _Seed('Julierpass', 46.472214, 9.728146, ['GR'],
      ['Tiefencastel', 'Silvaplana'], 1604293770),
  _Seed('Col du Sanetsch', 46.331575, 7.286225, ['VS'], ['Sion', 'Gsteig'],
      485239200),
  _Seed('Sustenpass', 46.72912, 8.44652, ['BE', 'UR'],
      ['Innertkirchen', 'Wassen'], 1435921493),
  _Seed('Grimselpass', 46.561519, 8.337697, ['BE', 'VS'],
      ['Gletsch', 'Innertkirchen'], 1456026791),
  _Seed('Pass dal Fuorn', 46.639774, 10.292186, ['GR'], ['Zernez', 'Müstair'],
      82677753),
  _Seed('Passo dello Spluga - Splügenpass', 46.505616, 9.330336, ['IT', 'GR'],
      ['Splügen', 'Chiavenna'], 6038984981),
  _Seed('Passo del San Gottardo', 46.559309, 8.561154, ['TI'],
      ['Airolo', 'Andermatt'], 4936977615),
  _Seed('Passo del San Bernardino', 46.497149, 9.17114, ['GR'],
      ['Hinterrhein', 'Mesocco'], 1845679597),
  _Seed('Oberalppass', 46.658739, 8.671169, ['GR', 'UR'],
      ['Andermatt', 'Disentis'], 278908223),
  _Seed('Simplonpass', 46.250211, 8.031681, ['VS'], ['Brig', 'Domodossola'],
      1456020279),
  _Seed('Passo del Lucomagno', 46.574306, 8.801183, ['GR', 'TI'],
      ['Disentis', 'Olivone'], 1478875365),
  _Seed('Grosse Scheidegg', 46.655878, 8.101867, ['BE'],
      ['Grindelwald', 'Meiringen'], 281779660),
  _Seed('Klausenpass', 46.868191, 8.855442, ['UR', 'GL'],
      ['Altdorf', 'Linthal'], 1604293771),
  _Seed('Malojapass', 46.399936, 9.695807, ['GR'], ['Silvaplana', 'Chiavenna'],
      258384887),
  _Seed('Col de la Croix', 46.324702, 7.126718, ['VD'],
      ['Villars-sur-Ollon', 'Les Diablerets'], 2312731790),
  _Seed('Wolfgangpass', 46.832656, 9.853739, ['GR'], ['Davos', 'Klosters'],
      1456748165),
  _Seed('Glaubenbielen / Panoramastrasse', 46.81881, 8.093167, ['OW'],
      ['Giswil', 'Sörenberg'], 1256098859),
  _Seed('Pragelpass', 46.999368, 8.8695, ['SZ', 'GL'], ['Muotathal', 'Glarus'],
      1533696169),
  _Seed('Col du Pillon', 46.353429, 7.204597, ['VD'],
      ['Les Diablerets', 'Gstaad'], 83218210),
  _Seed('Glaubenbergpass', 46.892456, 8.107666, ['LU', 'OW'],
      ['Entlebuch', 'Sarnen'], 1417747629),
  _Seed('Col de la Forclaz', 46.057731, 7.001346, ['VS'],
      ['Martigny', 'Châtelard'], 945001634),
  _Seed('Jaunpass', 46.592159, 7.33908, ['BE', 'FR'], ['Bulle', 'Zweisimmen'],
      1434204855),
  _Seed('Lenzerheide / Passhöhe', 46.728, 9.5577, ['GR'], ['Chur', 'Tiefencastel'],
      0),
  // ── Mid-altitude Jura / Prealps / regional road passes ──
  _Seed('Col du Chasseral', 47.119423, 7.032299, ['BE', 'NE'],
      ['Saint-Imier', 'La Neuveville'], 275654404),
  _Seed('Col du Marchairuz', 46.552791, 6.250287, ['VD'],
      ['Le Brassus', 'Bière'], 2521699413),
  _Seed('Col des Mosses', 46.398976, 7.10263, ['VD'],
      ['Aigle', 'Château-d’Œx'], 1102704120),
  _Seed('Ibergeregg', 47.017428, 8.73321, ['SZ'], ['Schwyz', 'Oberiberg'],
      5254587716),
  _Seed("Passo dell'Alpe di Neggia", 46.110669, 8.845454, ['TI'],
      ['Vira', 'Indemini'], 264071175),
  _Seed('Pas de Morgins', 46.249702, 6.84589, ['VS'], ['Monthey', 'Châtel'],
      2501960454),
  _Seed('Kunkelspass', 46.85617, 9.411567, ['GR', 'SG'], ['Tamins', 'Vättis'],
      1390050648),
  _Seed('Schwägalp Passhöhe', 47.253545, 9.303714, ['AR', 'SG'],
      ['Urnäsch', 'Nesslau'], 3098387428),
  _Seed('Vue des Alpes', 47.072722, 6.869822, ['NE'],
      ['Neuchâtel', 'La Chaux-de-Fonds'], 282843029),
  _Seed('Saanenmöser', 46.514448, 7.304696, ['BE'], ['Gstaad', 'Zweisimmen'],
      2888050506),
  _Seed('Sattelegg', 47.127334, 8.846823, ['SZ'], ['Einsiedeln', 'Vorderthal'],
      5254588463),
  _Seed('Schallenbergpass', 46.826153, 7.796857, ['BE'],
      ['Schangnau', 'Eggiwil'], 1589707950),
  _Seed('Gurnigel / Gurnigelpass', 46.732035, 7.447882, ['BE'],
      ['Riggisberg', 'Gantrisch'], 2108923833),
  _Seed('Glaspass', 46.676747, 9.345247, ['GR'], ['Thusis', 'Vals'],
      1883248347),
  _Seed('Col du Mollendruz', 46.649907, 6.365888, ['VD'],
      ['L’Isle', 'Le Pont'], 286440973),
  _Seed('Col du Mont Crosin', 47.190622, 7.039912, ['BE'],
      ['Saint-Imier', 'Tramelan'], 9028718417),
  _Seed('Scheltenpass', 47.335839, 7.581817, ['BE', 'SO'],
      ['Mümliswil', 'Bärschwil'], 1269622930),
  _Seed('Ruppenpass', 47.396096, 9.502612, ['AR', 'SG'],
      ['Altstätten', 'Trogen'], 795059948),
  _Seed('Brünigpass', 46.756863, 8.136986, ['BE', 'OW'],
      ['Meiringen', 'Lungern'], 1456037442),
  _Seed('Col de la Givrine', 46.456004, 6.088444, ['VD'],
      ['Saint-Cergue', 'La Cure'], 2498035793),
  _Seed('Stoss', 47.360848, 9.494888, ['AR', 'SG'], ['Altstätten', 'Gais'],
      1475352806),
  _Seed('Col des Etroits', 46.829866, 6.495036, ['VD'],
      ['Sainte-Croix', 'Buttes'], 275803553),
  _Seed('Col de Pierre Pertuis', 47.210017, 7.194226, ['BE'],
      ['Tavannes', 'Sonceboz'], 1864803668),
  _Seed('Wasserfluh', 47.326049, 9.114565, ['SG'], ['Wattwil', 'Brunnadern'],
      1612338085),
  _Seed('Hulftegg', 47.362166, 8.966646, ['SG', 'ZH'], ['Bauma', 'Mühlrüti'],
      6501190121),
  _Seed('Monte Ceneri', 46.139177, 8.907085, ['TI'], ['Bellinzona', 'Lugano'],
      1485137013),
  _Seed('Col du Chalet-à-Gobet', 46.566465, 6.696612, ['VD'],
      ['Lausanne', 'Moudon'], 3434255909),
  _Seed('Albispass', 47.276007, 8.521143, ['ZH'], ['Zürich', 'Hausen am Albis'],
      243076765),
  _Seed('Ricken', 47.273236, 9.027605, ['SG'], ['Wattwil', 'Rapperswil'],
      1827330485),
  _Seed('Col de la Tourne', 46.98372, 6.778859, ['NE'],
      ['Neuchâtel', 'Les Ponts-de-Martel'], 13346799842),
  _Seed('Salhöhe', 47.428926, 7.985968, ['AG', 'SO'], ['Aarau', 'Erlinsbach'],
      298678777),
  _Seed('Oberer Hauenstein', 47.351658, 7.763983, ['BL', 'SO'],
      ['Waldenburg', 'Balsthal'], 1604293772),
  _Seed('Unterer Hauenstein', 47.381343, 7.86898, ['BL', 'SO'],
      ['Läufelfingen', 'Olten'], 1496658778),
  _Seed('Benkerjoch', 47.435436, 8.030087, ['AG'], ['Küttigen', 'Densbüren'],
      286011956),
  _Seed('Staffelegg', 47.433821, 8.060461, ['AG'], ['Aarau', 'Frick'],
      268830023),
  _Seed('Col des Rangiers', 47.384817, 7.219149, ['JU'],
      ['Delémont', 'Saint-Ursanne'], 1480933404),
  _Seed('Sankt Luzisteig', 47.029606, 9.528192, ['GR'], ['Maienfeld', 'Balzers'],
      410060036),
  _Seed('Mutschellenpass', 47.362404, 8.366992, ['AG'], ['Bremgarten', 'Berikon'],
      436385442),
  _Seed('Etzelpass', 47.173448, 8.772272, ['SZ'], ['Pfäffikon', 'Einsiedeln'],
      1639345922),
];
