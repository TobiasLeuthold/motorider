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
    this.tempMinC,
    this.tempMaxC,
    this.tempAvgC,
    this.precipitationMm,
    this.windMaxKmh,
    this.weatherCode,
    this.weatherFetchedAt,
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

  // Post-ride weather enrichment. Null until [WeatherService] has filled it
  // in (typically a few seconds after stopRide). `weatherFetchedAt` is the
  // marker that distinguishes "no data yet" from "data fetched, was clear
  // with no precipitation".
  final double? tempMinC;
  final double? tempMaxC;
  final double? tempAvgC;
  final double? precipitationMm;
  final double? windMaxKmh;
  final int? weatherCode;
  final DateTime? weatherFetchedAt;

  final DateTime updatedAt;
  final DateTime? deletedAt;
  final SyncState syncState;

  bool get isDeleted => deletedAt != null;
  bool get isActive => endedAt == null;
  bool get hasWeather => weatherFetchedAt != null;

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
    Object? tempMinC = _sentinel,
    Object? tempMaxC = _sentinel,
    Object? tempAvgC = _sentinel,
    Object? precipitationMm = _sentinel,
    Object? windMaxKmh = _sentinel,
    Object? weatherCode = _sentinel,
    Object? weatherFetchedAt = _sentinel,
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
      tempMinC: identical(tempMinC, _sentinel)
          ? this.tempMinC
          : tempMinC as double?,
      tempMaxC: identical(tempMaxC, _sentinel)
          ? this.tempMaxC
          : tempMaxC as double?,
      tempAvgC: identical(tempAvgC, _sentinel)
          ? this.tempAvgC
          : tempAvgC as double?,
      precipitationMm: identical(precipitationMm, _sentinel)
          ? this.precipitationMm
          : precipitationMm as double?,
      windMaxKmh: identical(windMaxKmh, _sentinel)
          ? this.windMaxKmh
          : windMaxKmh as double?,
      weatherCode: identical(weatherCode, _sentinel)
          ? this.weatherCode
          : weatherCode as int?,
      weatherFetchedAt: identical(weatherFetchedAt, _sentinel)
          ? this.weatherFetchedAt
          : weatherFetchedAt as DateTime?,
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
      'temp_min_c': tempMinC,
      'temp_max_c': tempMaxC,
      'temp_avg_c': tempAvgC,
      'precipitation_mm': precipitationMm,
      'wind_max_kmh': windMaxKmh,
      'weather_code': weatherCode,
      'weather_fetched_at': weatherFetchedAt?.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  factory Ride.fromMap(Map<String, Object?> m) {
    String? str(Object? v) => v as String?;
    final endedAtRaw = str(m['ended_at']);
    final deletedAtRaw = str(m['deleted_at']);
    final weatherFetchedRaw = str(m['weather_fetched_at']);
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
      tempMinC: (m['temp_min_c'] as num?)?.toDouble(),
      tempMaxC: (m['temp_max_c'] as num?)?.toDouble(),
      tempAvgC: (m['temp_avg_c'] as num?)?.toDouble(),
      precipitationMm: (m['precipitation_mm'] as num?)?.toDouble(),
      windMaxKmh: (m['wind_max_kmh'] as num?)?.toDouble(),
      weatherCode: (m['weather_code'] as num?)?.toInt(),
      weatherFetchedAt: weatherFetchedRaw == null || weatherFetchedRaw.isEmpty
          ? null
          : DateTime.parse(weatherFetchedRaw),
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
      if (tempMinC != null) 'temp_min_c': tempMinC,
      if (tempMaxC != null) 'temp_max_c': tempMaxC,
      if (tempAvgC != null) 'temp_avg_c': tempAvgC,
      if (precipitationMm != null) 'precipitation_mm': precipitationMm,
      if (windMaxKmh != null) 'wind_max_kmh': windMaxKmh,
      if (weatherCode != null) 'weather_code': weatherCode,
      if (weatherFetchedAt != null)
        'weather_fetched_at': weatherFetchedAt!.toIso8601String(),
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
    final weatherFetchedRaw = optStr(j['weather_fetched_at']);
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
      tempMinC: (j['temp_min_c'] as num?)?.toDouble(),
      tempMaxC: (j['temp_max_c'] as num?)?.toDouble(),
      tempAvgC: (j['temp_avg_c'] as num?)?.toDouble(),
      precipitationMm: (j['precipitation_mm'] as num?)?.toDouble(),
      windMaxKmh: (j['wind_max_kmh'] as num?)?.toDouble(),
      weatherCode: (j['weather_code'] as num?)?.toInt(),
      weatherFetchedAt:
          weatherFetchedRaw == null ? null : DateTime.parse(weatherFetchedRaw),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      deletedAt: deletedAtRaw == null ? null : DateTime.parse(deletedAtRaw),
      syncState: SyncState.synced,
    );
  }
}

const Object _sentinel = Object();
