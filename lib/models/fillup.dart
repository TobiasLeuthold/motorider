import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Sync state of a row vs. the NAS backend.
///
/// `pending` rows are owed an outbound push; they were either created/edited
/// locally or arrived back from the server with a later push still queued.
/// `synced` rows match the server's last-known state.
enum SyncState { pending, synced }

class FillUp {
  FillUp({
    String? id,
    required this.date,
    required this.odometerKm,
    required this.liters,
    required this.totalChf,
    this.latitude,
    this.longitude,
    this.station,
    this.notes,
    this.fullTank = true,
    DateTime? updatedAt,
    this.deletedAt,
    this.syncState = SyncState.pending,
  })  : id = id ?? _uuid.v4(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final DateTime date;
  final int odometerKm;
  final double liters;
  final double totalChf;
  final double? latitude;
  final double? longitude;
  final String? station;
  final String? notes;
  final bool fullTank;

  /// Wall-clock time of the last LOCAL write to this row. Drives last-write-
  /// wins comparisons during sync. The server stores this value verbatim;
  /// don't bump it for sync-housekeeping writes (e.g. marking synced).
  final DateTime updatedAt;

  /// Non-null = tombstone. The row stays in the DB so the deletion can sync,
  /// but [FillUpRepository.getAll] filters it out of normal queries.
  final DateTime? deletedAt;

  final SyncState syncState;

  bool get isDeleted => deletedAt != null;
  double get pricePerLiter => liters > 0 ? totalChf / liters : 0;

  FillUp copyWith({
    DateTime? date,
    int? odometerKm,
    double? liters,
    double? totalChf,
    double? latitude,
    double? longitude,
    String? station,
    String? notes,
    bool? fullTank,
    DateTime? updatedAt,
    Object? deletedAt = _sentinel,
    SyncState? syncState,
  }) {
    return FillUp(
      id: id,
      date: date ?? this.date,
      odometerKm: odometerKm ?? this.odometerKm,
      liters: liters ?? this.liters,
      totalChf: totalChf ?? this.totalChf,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      station: station ?? this.station,
      notes: notes ?? this.notes,
      fullTank: fullTank ?? this.fullTank,
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
      'date_iso': date.toIso8601String(),
      'odometer_km': odometerKm,
      'liters': liters,
      'total_chf': totalChf,
      'latitude': latitude,
      'longitude': longitude,
      'station': station,
      'notes': notes,
      'full_tank': fullTank ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  /// Serialize for a `POST` / `PATCH` to PocketBase. The local UUID is sent
  /// as `client_id`; PocketBase generates its own opaque server-side id.
  /// Null optional fields are omitted so PocketBase doesn't reject the
  /// payload (its number-type fields don't accept JSON null).
  Map<String, Object?> toPocketBaseJson() {
    return {
      'client_id': id,
      'date_iso': date.toIso8601String(),
      'odometer_km': odometerKm,
      'liters': liters,
      'total_chf': totalChf,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (station != null) 'station': station,
      if (notes != null) 'notes': notes,
      'full_tank': fullTank,
      'updated_at': updatedAt.toIso8601String(),
      if (deletedAt != null) 'deleted_at': deletedAt!.toIso8601String(),
    };
  }

  /// Build a FillUp from a PocketBase record JSON. The server's own `id` is
  /// discarded — we key everything on `client_id` (our UUID) so the same row
  /// has a stable identity across devices.
  factory FillUp.fromPocketBaseJson(Map<String, Object?> j) {
    String? optionalString(Object? v) {
      if (v == null) return null;
      final s = v as String;
      return s.isEmpty ? null : s;
    }

    final deletedAtRaw = optionalString(j['deleted_at']);
    return FillUp(
      id: j['client_id'] as String,
      date: DateTime.parse(j['date_iso'] as String),
      odometerKm: (j['odometer_km'] as num).toInt(),
      liters: (j['liters'] as num).toDouble(),
      totalChf: (j['total_chf'] as num).toDouble(),
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      station: optionalString(j['station']),
      notes: optionalString(j['notes']),
      fullTank: (j['full_tank'] as bool?) ?? true,
      updatedAt: DateTime.parse(j['updated_at'] as String),
      deletedAt: deletedAtRaw == null ? null : DateTime.parse(deletedAtRaw),
      syncState: SyncState.synced,
    );
  }

  factory FillUp.fromMap(Map<String, Object?> m) {
    final updatedAtRaw = m['updated_at'] as String?;
    final deletedAtRaw = m['deleted_at'] as String?;
    return FillUp(
      id: m['id'] as String,
      date: DateTime.parse(m['date_iso'] as String),
      odometerKm: (m['odometer_km'] as num).toInt(),
      liters: (m['liters'] as num).toDouble(),
      totalChf: (m['total_chf'] as num).toDouble(),
      latitude: (m['latitude'] as num?)?.toDouble(),
      longitude: (m['longitude'] as num?)?.toDouble(),
      station: m['station'] as String?,
      notes: m['notes'] as String?,
      fullTank: (m['full_tank'] as int? ?? 1) == 1,
      updatedAt:
          updatedAtRaw != null && updatedAtRaw.isNotEmpty
              ? DateTime.parse(updatedAtRaw)
              : DateTime.parse(m['date_iso'] as String),
      deletedAt:
          deletedAtRaw != null && deletedAtRaw.isNotEmpty
              ? DateTime.parse(deletedAtRaw)
              : null,
      syncState: (m['sync_state'] as String?) == 'synced'
          ? SyncState.synced
          : SyncState.pending,
    );
  }
}

// copyWith needs to distinguish "caller didn't pass deletedAt" (keep current)
// from "caller passed null" (clear the tombstone). A sentinel object is the
// idiomatic way to do that in Dart without nullable-of-nullable gymnastics.
const Object _sentinel = Object();
