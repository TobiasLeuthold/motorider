import 'package:uuid/uuid.dart';

const _uuid = Uuid();

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
  }) : id = id ?? _uuid.v4();

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
    };
  }

  factory FillUp.fromMap(Map<String, Object?> m) {
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
    );
  }
}
