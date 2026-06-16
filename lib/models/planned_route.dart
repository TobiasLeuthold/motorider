import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import 'curviness.dart';
import 'fillup.dart' show SyncState;

const _uuid = Uuid();

/// A user-planned tour: an ordered list of [waypoints] the rider placed, plus
/// the [geometry] BRouter produced to connect them and the cached summary
/// stats. Stored in the `planned_routes` table; sync-ready (same
/// `updated_at` / `deleted_at` / `sync_state` shape as [Ride] / [FillUp]).
class PlannedRoute {
  PlannedRoute({
    String? id,
    required this.name,
    required this.waypoints,
    this.geometry = const [],
    this.curviness = Curviness.balanced,
    this.legCurviness = const [],
    this.distanceM = 0,
    this.durationS = 0,
    this.ascentM,
    this.curvinessScore = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.pending,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String name;

  /// The control points the rider placed (start, vias…, end). At least 2 for
  /// a routable tour.
  final List<LatLng> waypoints;

  /// The routed line connecting [waypoints]. Empty until routed.
  final List<LatLng> geometry;

  final Curviness curviness;

  /// Per-leg curviness levels — one entry per leg (`waypoints.length - 1`). A
  /// rider can dial each segment of the tour separately. Empty means "no
  /// per-leg choices" and every leg falls back to the scalar [curviness]; this
  /// keeps tours saved before per-leg curviness existed loading unchanged. Use
  /// [effectiveLegCurviness] to read a fully-resolved, per-leg list.
  final List<Curviness> legCurviness;

  final double distanceM;
  final int durationS;
  final double? ascentM;

  /// Cached [curvinessScore] of [geometry] (degrees of turning per km).
  final double curvinessScore;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SyncState syncState;

  bool get isDeleted => deletedAt != null;
  double get distanceKm => distanceM / 1000.0;
  Duration get duration => Duration(seconds: durationS);

  /// Per-leg curviness resolved against [waypoints]: a list of length
  /// `max(0, waypoints.length - 1)`, where any leg not explicitly set (incl.
  /// every leg of an old saved tour with empty [legCurviness]) falls back to
  /// the scalar [curviness].
  List<Curviness> effectiveLegCurviness() {
    final legs = waypoints.length <= 1 ? 0 : waypoints.length - 1;
    return [
      for (var i = 0; i < legs; i++)
        i < legCurviness.length ? legCurviness[i] : curviness,
    ];
  }

  PlannedRoute copyWith({
    String? name,
    List<LatLng>? waypoints,
    List<LatLng>? geometry,
    Curviness? curviness,
    List<Curviness>? legCurviness,
    double? distanceM,
    int? durationS,
    Object? ascentM = _sentinel,
    double? curvinessScore,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? deletedAt = _sentinel,
    SyncState? syncState,
  }) {
    return PlannedRoute(
      id: id,
      name: name ?? this.name,
      waypoints: waypoints ?? this.waypoints,
      geometry: geometry ?? this.geometry,
      curviness: curviness ?? this.curviness,
      legCurviness: legCurviness ?? this.legCurviness,
      distanceM: distanceM ?? this.distanceM,
      durationS: durationS ?? this.durationS,
      ascentM: identical(ascentM, _sentinel) ? this.ascentM : ascentM as double?,
      curvinessScore: curvinessScore ?? this.curvinessScore,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt:
          identical(deletedAt, _sentinel) ? this.deletedAt : deletedAt as DateTime?,
      syncState: syncState ?? this.syncState,
    );
  }

  static String encodePoints(List<LatLng> pts) =>
      jsonEncode([for (final p in pts) [p.latitude, p.longitude]]);

  static List<LatLng> decodePoints(Object? raw) {
    if (raw == null) return const [];
    final s = raw as String;
    if (s.isEmpty) return const [];
    final decoded = jsonDecode(s);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is List && e.length >= 2)
          LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()),
    ];
  }

  /// Per-leg curviness as a JSON array of enum indices, e.g. `[0,2,3]`.
  static String encodeCurviness(List<Curviness> levels) =>
      jsonEncode([for (final c in levels) c.index]);

  static List<Curviness> decodeCurviness(Object? raw) {
    if (raw == null) return const [];
    final s = raw as String;
    if (s.isEmpty) return const [];
    final decoded = jsonDecode(s);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is num) Curviness.fromIndex(e.toInt()),
    ];
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'waypoints_json': encodePoints(waypoints),
      'geometry_json': encodePoints(geometry),
      'curviness': curviness.index,
      'leg_curviness_json': encodeCurviness(legCurviness),
      'distance_m': distanceM,
      'duration_s': durationS,
      'ascent_m': ascentM,
      'curviness_score': curvinessScore,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  factory PlannedRoute.fromMap(Map<String, Object?> m) {
    String? str(Object? v) => v as String?;
    final deletedRaw = str(m['deleted_at']);
    return PlannedRoute(
      id: m['id'] as String,
      name: (m['name'] as String?) ?? 'Tour',
      waypoints: decodePoints(m['waypoints_json']),
      geometry: decodePoints(m['geometry_json']),
      curviness: Curviness.fromIndex(((m['curviness'] as num?) ?? 1).toInt()),
      legCurviness: decodeCurviness(m['leg_curviness_json']),
      distanceM: ((m['distance_m'] as num?) ?? 0).toDouble(),
      durationS: ((m['duration_s'] as num?) ?? 0).toInt(),
      ascentM: (m['ascent_m'] as num?)?.toDouble(),
      curvinessScore: ((m['curviness_score'] as num?) ?? 0).toDouble(),
      createdAt: DateTime.parse(m['created_at'] as String),
      updatedAt: DateTime.parse(m['updated_at'] as String),
      deletedAt:
          deletedRaw == null || deletedRaw.isEmpty ? null : DateTime.parse(deletedRaw),
      syncState: (m['sync_state'] as String?) == 'synced'
          ? SyncState.synced
          : SyncState.pending,
    );
  }

  /// PocketBase wire format — mirrors [Ride.toPocketBaseJson] so a future sync
  /// collection can adopt it without model changes.
  Map<String, Object?> toPocketBaseJson() {
    return {
      'client_id': id,
      'name': name,
      'waypoints_json': encodePoints(waypoints),
      'geometry_json': encodePoints(geometry),
      'curviness': curviness.index,
      'distance_m': distanceM,
      'duration_s': durationS,
      if (ascentM != null) 'ascent_m': ascentM,
      'curviness_score': curvinessScore,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (deletedAt != null) 'deleted_at': deletedAt!.toIso8601String(),
    };
  }

  factory PlannedRoute.fromPocketBaseJson(Map<String, Object?> j) {
    String? optStr(Object? v) {
      if (v == null) return null;
      final s = v as String;
      return s.isEmpty ? null : s;
    }

    final deletedRaw = optStr(j['deleted_at']);
    return PlannedRoute(
      id: j['client_id'] as String,
      name: (j['name'] as String?) ?? 'Tour',
      waypoints: decodePoints(j['waypoints_json']),
      geometry: decodePoints(j['geometry_json']),
      curviness: Curviness.fromIndex(((j['curviness'] as num?) ?? 1).toInt()),
      distanceM: ((j['distance_m'] as num?) ?? 0).toDouble(),
      durationS: ((j['duration_s'] as num?) ?? 0).toInt(),
      ascentM: (j['ascent_m'] as num?)?.toDouble(),
      curvinessScore: ((j['curviness_score'] as num?) ?? 0).toDouble(),
      createdAt: DateTime.parse(j['created_at'] as String),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      deletedAt: deletedRaw == null ? null : DateTime.parse(deletedRaw),
      syncState: SyncState.synced,
    );
  }
}

const Object _sentinel = Object();
