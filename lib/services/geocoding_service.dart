import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A single place returned by [GeocodingService].
class GeoPlace {
  const GeoPlace({
    required this.position,
    required this.primary,
    this.secondary,
  });

  final LatLng position;

  /// Bold first line (place / street name).
  final String primary;

  /// Muted context line (city, region, country) — may be empty.
  final String? secondary;

  String get label =>
      secondary == null || secondary!.isEmpty ? primary : '$primary, $secondary';
}

/// Thrown when a geocoding lookup fails. [message] is safe to show the user.
class GeocodingException implements Exception {
  const GeocodingException(this.message);
  final String message;
  @override
  String toString() => 'GeocodingException: $message';
}

/// Forward geocoding (place name → coordinates) via the public Photon server
/// (https://photon.komoot.io). Photon is OSM-based and built for
/// autocomplete-as-you-type, so it's safe to call on each (debounced)
/// keystroke — unlike Nominatim's public server. No API key needed.
///
/// Swap [baseUrl] to a self-hosted Photon instance later without touching
/// callers.
class GeocodingService {
  GeocodingService({http.Client? client, this.baseUrl = _defaultBase})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const _defaultBase = 'https://photon.komoot.io/api';

  /// Don't bother querying for very short fragments — they return noise and
  /// waste requests.
  static const minQueryLength = 3;

  final http.Client _client;
  final bool _ownsClient;
  final String baseUrl;

  /// Look up [query]. [bias] (typically the map centre) nudges results toward
  /// that area so a search for "Bahnhof" prefers the nearby one. Returns an
  /// empty list for too-short queries.
  Future<List<GeoPlace>> search(
    String query, {
    LatLng? bias,
    int limit = 6,
    String lang = 'de',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final q = query.trim();
    if (q.length < minQueryLength) return const [];

    final params = <String, String>{
      'q': q,
      'limit': '$limit',
      'lang': lang,
    };
    if (bias != null) {
      params['lat'] = bias.latitude.toString();
      params['lon'] = bias.longitude.toString();
    }
    final uri = Uri.parse(baseUrl).replace(queryParameters: params);

    final http.Response res;
    try {
      res = await _client.get(uri).timeout(timeout);
    } catch (e) {
      throw GeocodingException('Suche nicht erreichbar ($e).');
    }
    if (res.statusCode != 200) {
      throw GeocodingException('Suchdienst: HTTP ${res.statusCode}.');
    }
    return parsePhoton(res.body);
  }

  /// Parse a Photon GeoJSON FeatureCollection into [GeoPlace]s. Exposed for
  /// testing. Bad/incomplete features are skipped rather than throwing.
  static List<GeoPlace> parsePhoton(String body) {
    final Map<String, Object?> json;
    try {
      json = jsonDecode(body) as Map<String, Object?>;
    } catch (_) {
      throw const GeocodingException('Antwort des Suchdienstes unlesbar.');
    }
    final features = json['features'] as List? ?? const [];
    final out = <GeoPlace>[];
    for (final f in features) {
      if (f is! Map) continue;
      final geom = f['geometry'] as Map?;
      final coords = geom?['coordinates'] as List?;
      if (coords == null || coords.length < 2) continue;
      final lon = (coords[0] as num?)?.toDouble();
      final lat = (coords[1] as num?)?.toDouble();
      if (lat == null || lon == null) continue;

      final props = (f['properties'] as Map?) ?? const {};
      final place = _labelFromProps(props.cast<String, Object?>());
      if (place == null) continue;
      out.add(GeoPlace(
        position: LatLng(lat, lon),
        primary: place.$1,
        secondary: place.$2,
      ));
    }
    return out;
  }

  /// Build a (primary, secondary) label pair from Photon properties.
  /// primary = the place/street name; secondary = a deduped context trail
  /// (city · postcode · region · country). Returns null if there's nothing
  /// usable to show.
  static (String, String)? _labelFromProps(Map<String, Object?> p) {
    String? s(String k) {
      final v = p[k];
      if (v == null) return null;
      final str = v.toString().trim();
      return str.isEmpty ? null : str;
    }

    final name = s('name');
    final street = s('street');
    final houseNumber = s('housenumber');
    final streetLine = street == null
        ? null
        : (houseNumber == null ? street : '$street $houseNumber');

    final primary = name ?? streetLine;
    if (primary == null) return null;

    final city = s('city') ?? s('town') ?? s('village') ?? s('district');
    final context = <String?>[
      if (primary != streetLine) streetLine,
      s('postcode'),
      city,
      s('state'),
      s('country'),
    ];
    final seen = <String>{primary};
    final secondary = context
        .whereType<String>()
        .where((e) => seen.add(e))
        .join(', ');

    return (primary, secondary);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
