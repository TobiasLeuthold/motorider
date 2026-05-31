import 'package:uuid/uuid.dart';

import 'fillup.dart' show SyncState;

const _uuid = Uuid();

/// A single recorded motorcycle ride.
///
/// Stats (distance, durations, max/avg speed, elevation gain) are computed
/// from the [RidePoint]s and cached here so the history list doesn't have to
/// re-stream thousands of points just to show a summary row. They're
/// recomputed on each [RideTracker.stopRide] (and on each NAS pull) so they
/// stay consistent with the points table.
class Ride {
  Ride({
    String? id,
    required this.startedAt,
    this.endedAt,
    this.distanceKm = 0,
    this.totalDuration = Duration.zero,
    this.movingDuration = Duration.zero,
    this.maxSpeedKmh = 0,
    this.avgMovingSpeedKmh = 0,
    this.elevationGainM,
    this.title,
    this.notes,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.pending,
  })  : id = id ?? _uuid.v4(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;

  final double distanceKm;
  final Duration totalDuration;
  final Duration movingDuration;
  final double maxSpeedKmh;
  final double avgMovingSpeedKmh;
  final double? elevationGainM;

  final String? title;
  final String? notes;

  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SyncState syncState;

  bool get isDeleted => deletedAt != null;
  bool get isActive => endedAt == null;

  Ride copyWith({
    DateTime? startedAt,
    Object? endedAt = _sentinel,
    double? distanceKm,
    Duration? totalDuration,
    Duration? movingDuration,
    double? maxSpeedKmh,
    double? avgMovingSpeedKmh,
    Object? elevationGainM = _sentinel,
    Object? title = _sentinel,
    Object? notes = _sentinel,
    DateTime? updatedAt,
    Object? deletedAt = _sentinel,
    SyncState? syncState,
  }) {
    return Ride(
      id: id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: identical(endedAt, _sentinel)
          ? this.endedAt
          : endedAt as DateTime?,
      distanceKm: distanceKm ?? this.distanceKm,
      totalDuration: totalDuration ?? this.totalDuration,
      movingDuration: movingDuration ?? this.movingDuration,
      maxSpeedKmh: maxSpeedKmh ?? this.maxSpeedKmh,
      avgMovingSpeedKmh: avgMovingSpeedKmh ?? this.avgMovingSpeedKmh,
      elevationGainM: identical(elevationGainM, _sentinel)
          ? this.elevationGainM
          : elevationGainM as double?,
      title: identical(title, _sentinel) ? this.title : title as String?,
      notes: identical(notes, _sentinel) ? this.notes : notes as String?,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: identical(deletedAt, _sentinel)
          ? this.deletedAt
          : deletedAt as DateTime?,
      syncState: syncState ?? this.syncState,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt?.toIso8601String(),
      'distance_km': distanceKm,
      'total_duration_s': totalDuration.inSeconds,
      'moving_duration_s': movingDuration.inSeconds,
      'max_speed_kmh': maxSpeedKmh,
      'avg_moving_speed_kmh': avgMovingSpeedKmh,
      'elevation_gain_m': elevationGainM,
      'title': title,
      'notes': notes,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  factory Ride.fromMap(Map<String, Object?> m) {
    String? str(Object? v) => v as String?;
    final endedAtRaw = str(m['ended_at']);
    final deletedAtRaw = str(m['deleted_at']);
    return Ride(
      id: m['id'] as String,
      startedAt: DateTime.parse(m['started_at'] as String),
      endedAt: endedAtRaw == null || endedAtRaw.isEmpty
          ? null
          : DateTime.parse(endedAtRaw),
      distanceKm: ((m['distance_km'] as num?) ?? 0).toDouble(),
      totalDuration: Duration(seconds: ((m['total_duration_s'] as num?) ?? 0).toInt()),
      movingDuration: Duration(seconds: ((m['moving_duration_s'] as num?) ?? 0).toInt()),
      maxSpeedKmh: ((m['max_speed_kmh'] as num?) ?? 0).toDouble(),
      avgMovingSpeedKmh: ((m['avg_moving_speed_kmh'] as num?) ?? 0).toDouble(),
      elevationGainM: (m['elevation_gain_m'] as num?)?.toDouble(),
      title: str(m['title']),
      notes: str(m['notes']),
      updatedAt: DateTime.parse(m['updated_at'] as String),
      deletedAt: deletedAtRaw == null || deletedAtRaw.isEmpty
          ? null
          : DateTime.parse(deletedAtRaw),
      syncState: (m['sync_state'] as String?) == 'synced'
          ? SyncState.synced
          : SyncState.pending,
    );
  }

  /// PocketBase wire format. `points_json` is filled in by the sync layer
  /// (which serializes the matching ride_points rows), not by the model.
  Map<String, Object?> toPocketBaseJson({required String pointsJson}) {
    return {
      'client_id': id,
      'started_at': startedAt.toIso8601String(),
      if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
      'distance_km': distanceKm,
      'total_duration_s': totalDuration.inSeconds,
      'moving_duration_s': movingDuration.inSeconds,
      'max_speed_kmh': maxSpeedKmh,
      'avg_moving_speed_kmh': avgMovingSpeedKmh,
      if (elevationGainM != null) 'elevation_gain_m': elevationGainM,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      'points_json': pointsJson,
      'updated_at': updatedAt.toIso8601String(),
      if (deletedAt != null) 'deleted_at': deletedAt!.toIso8601String(),
    };
  }

  factory Ride.fromPocketBaseJson(Map<String, Object?> j) {
    String? optStr(Object? v) {
      if (v == null) return null;
      final s = v as String;
      return s.isEmpty ? null : s;
    }

    final endedAtRaw = optStr(j['ended_at']);
    final deletedAtRaw = optStr(j['deleted_at']);
    return Ride(
      id: j['client_id'] as String,
      startedAt: DateTime.parse(j['started_at'] as String),
      endedAt: endedAtRaw == null ? null : DateTime.parse(endedAtRaw),
      distanceKm: ((j['distance_km'] as num?) ?? 0).toDouble(),
      totalDuration: Duration(seconds: ((j['total_duration_s'] as num?) ?? 0).toInt()),
      movingDuration: Duration(seconds: ((j['moving_duration_s'] as num?) ?? 0).toInt()),
      maxSpeedKmh: ((j['max_speed_kmh'] as num?) ?? 0).toDouble(),
      avgMovingSpeedKmh: ((j['avg_moving_speed_kmh'] as num?) ?? 0).toDouble(),
      elevationGainM: (j['elevation_gain_m'] as num?)?.toDouble(),
      title: optStr(j['title']),
      notes: optStr(j['notes']),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      deletedAt: deletedAtRaw == null ? null : DateTime.parse(deletedAtRaw),
      syncState: SyncState.synced,
    );
  }
}

const Object _sentinel = Object();
