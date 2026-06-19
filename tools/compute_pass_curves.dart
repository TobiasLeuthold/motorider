// Computes real hairpin counts + curviness for every Swiss pass in
// assets/data/passes_ch.json, from OpenStreetMap road geometry.
//
// For each pass we already store `osmId` — the OSM *node* id of the col, which
// sits on a `highway` way. This tool:
//   1. asks the Overpass API for the drivable road network in a box around the
//      col (~9 km radius),
//   2. walks the connected road outward from the col node in both directions
//      (up to ~7 km each side — far enough to reach the switchback-dense ramps
//      that often sit well below the summit), greedily staying on the same road
//      at junctions,
//   3. resamples that polyline to a constant spacing and runs a hysteresis
//      hairpin detector (signed bearing change over a short ~110 m window
//      crossing ~140°, with the road required to straighten or reverse between
//      counts so one switchback is never double-counted), and
//   4. computes `curvinessScore` (degrees of turning per km) over the same
//      geometry — matching lib/services/geo.dart::curvinessScore.
//
// The results are written back into the JSON (`hairpins`, `curvinessScore`).
// A pass we cannot analyse (no way found, network error) keeps null.
//
// Run from the package root:
//   dart run tools/compute_pass_curves.dart                 # all passes
//   dart run tools/compute_pass_curves.dart --only Furkapass,Grimselpass
//   dart run tools/compute_pass_curves.dart --dry-run       # don't write file
//
// Reproducible: re-running produces the same numbers (OSM geometry permitting).
// Hairpin counts are approximate — derived from geometry, not surveyed.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

const String _assetPath = 'assets/data/passes_ch.json';

// A couple of public Overpass mirrors; we round-robin / fail over between them
// to be polite and resilient.
const List<String> _overpassEndpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

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

/// Resample a polyline to ~[stepM] spacing so the detector sees a uniform
/// stream of points regardless of how densely OSM happened to digitise the
/// road. Keeps the first and last vertices.
List<LatLng> _resample(List<LatLng> pts, double stepM) {
  if (pts.length < 2) return List.of(pts);
  final out = <LatLng>[pts.first];
  // `nextAt` is the along-distance (from start) of the next point to emit.
  var travelled = 0.0; // along-distance at the start of the current segment
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

// ───────────────────────── hairpin detector ─────────────────────────

/// Count hairpin switchbacks along [poly].
///
/// A hairpin is a stretch where the road bends, in a *single* direction, by
/// more than [thresholdDeg] within a short along-distance window (~[windowM]) —
/// it nearly doubles back. We resample to a uniform [stepM] spacing and slide a
/// signed-bearing-change window along the road. When the running turn (in the
/// dominant direction) crosses the threshold we count one switchback, then
/// **disarm**.
///
/// Re-arming uses hysteresis, exactly so one switchback is never counted twice:
/// after a hit we wait until the road has *settled* — either it straightens out
/// (a stretch with little turning) OR it reverses into the opposite-handed bend
/// of the next switchback. Stacked switchbacks alternate left/right, so the
/// signed turn swinging back through ~0 is the clean, geometry-driven signal
/// that one hairpin has ended and the next begun. That reversal-based re-arm is
/// what lets a tightly-stacked serpentine (Albula, Tremola) count every bend
/// while still collapsing a single long, finely-digitised hairpin to one.
int _countHairpins(
  List<LatLng> poly, {
  double windowM = 110.0,
  double thresholdDeg = 140.0,
  double stepM = 12.0,
  void Function(double alongM, String msg)? debug,
}) {
  if (poly.length < 4) return 0;
  final rs = _resample(poly, stepM);
  if (rs.length < 4) return 0;

  // Per-step signed bearing change and step length.
  final n = rs.length;
  final delta = List<double>.filled(n, 0.0); // delta[i] = turn at vertex i
  final segLen = List<double>.filled(n, 0.0); // length of segment i-1 -> i
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
  // Signed sliding window (lo..i], along-distance <= windowM.
  var lo = 1;
  var winTurn = 0.0;
  var winLen = 0.0;
  var along = 0.0;

  // After a hit, the signed turn that fired it (its sign), and the running
  // signed turn accumulated *since* the hit — used to detect settle/reversal.
  var hitSign = 0.0;
  var sinceHit = 0.0;
  // Trailing absolute-turn window for the "straightened out" re-arm.
  const straightenM = 80.0;
  const straightenMaxTurnDeg = 45.0;
  var clo = 1;
  var calmTurn = 0.0;
  var calmLen = 0.0;

  for (var i = 1; i < n - 1; i++) {
    along += segLen[i];
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
        debug?.call(along,
            'HAIRPIN #$count  winTurn=${winTurn.toStringAsFixed(0)}');
        // Reset signed window so the hairpin's own tail can't re-fire it.
        winTurn = 0.0;
        winLen = 0.0;
        lo = i;
      }
    } else {
      sinceHit += delta[i];
      // Reversal re-arm: the road has begun turning the *other* way by a clear
      // margin → the previous switchback is over; ready for the next.
      final reversed = hitSign != 0 &&
          sinceHit.sign != hitSign &&
          sinceHit.abs() >= thresholdDeg * 0.45;
      // Straightened re-arm: a calm stretch with little net turning.
      final straightened =
          calmLen >= straightenM * 0.8 && calmTurn <= straightenMaxTurnDeg;
      if (reversed || straightened) {
        armed = true;
        // Keep the just-accumulated opposite turn in the signed window so an
        // immediately-following reverse hairpin is still detected promptly.
      }
    }
  }
  return count;
}

// ───────────────────────── Overpass fetch ─────────────────────────

/// One OSM way: ordered node ids + their coordinates, plus whether it's a
/// road we want to follow.
class _Way {
  _Way(this.id, this.nodes, this.coords);
  final int id;
  final List<int> nodes;
  final Map<int, LatLng> coords;
}

class _RoadGraph {
  _RoadGraph(this.ways, this.nodeCoords, this.nodeToWays);
  final Map<int, _Way> ways;
  final Map<int, LatLng> nodeCoords;
  final Map<int, List<int>> nodeToWays; // node id -> way ids through it
}

Future<String> _overpassPost(String query) async {
  Object? lastErr;
  for (var attempt = 0; attempt < _overpassEndpoints.length * 2; attempt++) {
    final ep = _overpassEndpoints[attempt % _overpassEndpoints.length];
    try {
      final resp = await http
          .post(Uri.parse(ep), body: {'data': query})
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode == 200) return resp.body;
      lastErr = 'HTTP ${resp.statusCode} from $ep';
      // 429/504 -> back off and try next mirror.
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
  // Drivable, non-motorway road classes a pass road would use.
  const filter =
      '[highway~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|road|service)\$"]';
  final query = '''
[out:json][timeout:90];
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
    final nodeIds = (el['nodes'] as List).map((e) => (e as num).toInt()).toList();
    final geom = (el['geometry'] as List?)?.cast<Map<String, dynamic>>();
    if (geom == null || geom.length != nodeIds.length) continue;
    final coords = <int, LatLng>{};
    for (var i = 0; i < nodeIds.length; i++) {
      final g = geom[i];
      final p = LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble());
      coords[nodeIds[i]] = p;
      nodeCoords[nodeIds[i]] = p;
      (nodeToWays[nodeIds[i]] ??= []).add(id);
    }
    ways[id] = _Way(id, nodeIds, coords);
  }
  return _RoadGraph(ways, nodeCoords, nodeToWays);
}

// ───────────────────────── road walking ─────────────────────────

/// Walk the road outward from [startNode] in one direction, following the
/// straightest continuation at each junction, until [maxLenM] is covered or
/// the road runs out. Returns the ordered polyline (excluding the start point,
/// which the caller stitches in).
List<LatLng> _walk(
  _RoadGraph g,
  int startNode,
  int? firstNextNode, {
  required double maxLenM,
}) {
  final out = <LatLng>[];
  final visitedEdges = <String>{}; // "a-b" undirected
  var current = startNode;
  int? prev;
  // Seed the first hop if requested (to force a starting direction).
  int? forcedNext = firstNextNode;
  var length = 0.0;
  var guard = 0;

  while (length < maxLenM && guard++ < 5000) {
    final here = g.nodeCoords[current];
    if (here == null) break;

    // Candidate next nodes: neighbours along any way through `current`,
    // excluding where we came from.
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
      // Junction: pick the continuation that bends the least (stay on road).
      final inBearing = prev == null
          ? null
          : _bearing(g.nodeCoords[prev]!, here);
      double scoreOf(int cand) {
        final candP = g.nodeCoords[cand]!;
        if (inBearing == null) {
          // No incoming direction yet: prefer the longest-looking edge.
          return -_haversine(here, candP);
        }
        final outB = _bearing(here, candP);
        return _bearingDelta(inBearing, outB).abs();
      }
      final sorted = neighbours.toList()
        ..sort((a, b) => scoreOf(a).compareTo(scoreOf(b)));
      next = sorted.first;
    }

    final edgeKey = current < next
        ? '$current-$next'
        : '$next-$current';
    if (!visitedEdges.add(edgeKey)) break; // avoid loops

    final nextP = g.nodeCoords[next]!;
    out.add(nextP);
    length += _haversine(here, nextP);
    prev = current;
    current = next;
  }
  return out;
}

/// Find the graph node nearest to [pt] within [maxM], or null. Used when the
/// stored col node isn't itself a vertex of any drivable way (some cols are
/// mapped as a standalone `mountain_pass`/`saddle` point beside the road).
int? _nearestNode(_RoadGraph g, LatLng pt, {double maxM = 150}) {
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

/// Build the full pass polyline: walk both directions from the col node and
/// stitch them head-to-tail with the col in the middle.
///
/// [colNode] is the stored OSM node id; [colPt] are its coordinates. If the
/// node isn't a vertex of any fetched road we snap to the nearest road node
/// (within ~150 m) and walk from there instead, so a col mapped slightly off
/// the carriageway still yields geometry.
List<LatLng>? _passPolyline(_RoadGraph g, int colNode, LatLng colPt,
    {double sideM = 7000}) {
  var startNode = colNode;
  if (!g.nodeCoords.containsKey(startNode)) {
    final snapped = _nearestNode(g, colPt);
    if (snapped == null) return null;
    startNode = snapped;
  }
  final col = g.nodeCoords[startNode];
  if (col == null) return null;

  // The col node usually sits on exactly one through-road; find its two
  // immediate neighbours to seed both directions.
  final neighbours = <int>{};
  for (final wid in g.nodeToWays[startNode] ?? const <int>[]) {
    final w = g.ways[wid]!;
    for (var i = 0; i < w.nodes.length; i++) {
      if (w.nodes[i] != startNode) continue;
      if (i > 0) neighbours.add(w.nodes[i - 1]);
      if (i < w.nodes.length - 1) neighbours.add(w.nodes[i + 1]);
    }
  }
  if (neighbours.isEmpty) return null;

  final nb = neighbours.toList();
  // Direction A: toward nb[0]. Direction B: toward a neighbour roughly
  // opposite nb[0] if one exists, else any other / reuse.
  final seedA = nb.first;
  int? seedB;
  if (nb.length >= 2) {
    final bA = _bearing(col, g.nodeCoords[seedA]!);
    // Pick the neighbour whose bearing is closest to opposite of A.
    double oppScore(int c) {
      final b = _bearing(col, g.nodeCoords[c]!);
      final diff = _bearingDelta(bA, b).abs();
      return (180.0 - diff).abs(); // 0 when exactly opposite
    }
    final others = nb.where((c) => c != seedA).toList()
      ..sort((a, b) => oppScore(a).compareTo(oppScore(b)));
    seedB = others.first;
  }

  final fwd = _walk(g, startNode, seedA, maxLenM: sideM);
  final bwd = seedB == null
      ? <LatLng>[]
      : _walk(g, startNode, seedB, maxLenM: sideM);

  final poly = <LatLng>[
    ...bwd.reversed,
    col,
    ...fwd,
  ];
  return poly.length >= 4 ? poly : null;
}

// ───────────────────────── main ─────────────────────────

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  Set<String>? only;
  final onlyIdx = args.indexOf('--only');
  if (onlyIdx >= 0 && onlyIdx + 1 < args.length) {
    only = args[onlyIdx + 1].split(',').map((s) => s.trim()).toSet();
  }
  String? debugName;
  final dbgIdx = args.indexOf('--debug');
  if (dbgIdx >= 0 && dbgIdx + 1 < args.length) {
    debugName = args[dbgIdx + 1].trim();
    only = {debugName};
  }

  final file = File(_assetPath);
  if (!file.existsSync()) {
    stderr.writeln('Cannot find $_assetPath — run from the package root.');
    exit(2);
  }
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final passes = (doc['passes'] as List).cast<Map<String, dynamic>>();

  var done = 0, failed = 0, skipped = 0;
  for (final p in passes) {
    final name = p['name'] as String;
    if (only != null && !only.contains(name)) {
      skipped++;
      continue;
    }
    final osmId = (p['osmId'] as num?)?.toInt();
    final lat = (p['lat'] as num).toDouble();
    final lon = (p['lon'] as num).toDouble();
    if (osmId == null) {
      stdout.writeln('SKIP  $name (no osmId)');
      skipped++;
      continue;
    }

    try {
      // ~9 km radius gives ~7 km each side plus slack at junctions, enough to
      // reach the switchback-dense ramps that often sit well below the col.
      final g = await _fetchGraph(lat, lon, 9000);
      final colPt = LatLng(lat, lon);
      final poly = _passPolyline(g, osmId, colPt, sideM: 7000);
      if (poly == null || poly.length < 4) {
        stdout.writeln(
            'MISS  $name — no drivable road found at col node $osmId');
        p['hairpins'] = null;
        p['curvinessScore'] = null;
        failed++;
      } else {
        final dbg = (name == debugName)
            ? (double a, String m) =>
                stdout.writeln('      @${a.toStringAsFixed(0)}m  $m')
            : null;
        final hp = _countHairpins(poly, debug: dbg);
        final cv = _curviness(poly);
        final lenKm = _pathLength(poly) / 1000.0;
        p['hairpins'] = hp;
        p['curvinessScore'] = double.parse(cv.toStringAsFixed(1));
        stdout.writeln(
            'OK    $name  hairpins=$hp  curviness=${cv.toStringAsFixed(0)}°/km  (${lenKm.toStringAsFixed(1)} km, ${poly.length} pts)');
        if (name == debugName) {
          // Dump the walked polyline for visual inspection.
          final f = File(
              'tools/_debug_${name.replaceAll(RegExp(r"[^A-Za-z0-9]"), "_")}.csv');
          final sb = StringBuffer('idx,lat,lon\n');
          for (var k = 0; k < poly.length; k++) {
            sb.writeln('$k,${poly[k].lat},${poly[k].lon}');
          }
          f.writeAsStringSync(sb.toString());
          stdout.writeln('      wrote ${f.path}');
        }
        done++;
      }
    } catch (e) {
      stdout.writeln('ERR   $name — $e');
      failed++;
    }
    // Be polite to the public Overpass servers.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  stdout.writeln('\nDONE: $done ok, $failed failed/missed, $skipped skipped.');

  if (!dryRun) {
    // Note in the attribution that hairpins are computed from geometry.
    final attr = doc['_attribution'];
    if (attr is String && !attr.contains('hairpin')) {
      doc['_attribution'] =
          '$attr Hairpin counts & curviness computed from OSM road geometry (approximate).';
    }
    const encoder = JsonEncoder.withIndent(' ');
    file.writeAsStringSync('${encoder.convert(doc)}\n');
    stdout.writeln('Wrote $_assetPath');
  } else {
    stdout.writeln('(dry-run: no file written)');
  }
}
