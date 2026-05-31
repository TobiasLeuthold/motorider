/// A single GPS sample within a [Ride]. Many of these compose into a track.
///
/// Stored as a child row in `ride_points` (composite PK on `ride_id`+`sequence`).
/// For sync to PocketBase, all points of a ride are serialized into a single
/// JSON array on the parent ride record — pushing thousands of individual
/// records over REST would be brutal.
class RidePoint {
  const RidePoint({
    required this.rideId,
    required this.sequence,
    required this.ts,
    required this.lat,
    required this.lon,
    this.altitudeM,
    this.speedMs,
    this.accuracyM,
    this.heading,
  });

  final String rideId;
  final int sequence;
  final DateTime ts;
  final double lat;
  final double lon;
  final double? altitudeM;
  final double? speedMs;
  final double? accuracyM;
  final double? heading;

  Map<String, Object?> toMap() {
    return {
      'ride_id': rideId,
      'sequence': sequence,
      'ts': ts.toIso8601String(),
      'lat': lat,
      'lon': lon,
      'altitude_m': altitudeM,
      'speed_ms': speedMs,
      'accuracy_m': accuracyM,
      'heading': heading,
    };
  }

  factory RidePoint.fromMap(Map<String, Object?> m) {
    return RidePoint(
      rideId: m['ride_id'] as String,
      sequence: (m['sequence'] as num).toInt(),
      ts: DateTime.parse(m['ts'] as String),
      lat: (m['lat'] as num).toDouble(),
      lon: (m['lon'] as num).toDouble(),
      altitudeM: (m['altitude_m'] as num?)?.toDouble(),
      speedMs: (m['speed_ms'] as num?)?.toDouble(),
      accuracyM: (m['accuracy_m'] as num?)?.toDouble(),
      heading: (m['heading'] as num?)?.toDouble(),
    );
  }

  /// Compact JSON tuple used inside the parent ride record's `points_json`.
  /// Order: [seq, ts_iso, lat, lon, alt_or_null, speed_or_null, acc_or_null, heading_or_null].
  /// Tuples beat verbose key/value maps for 7000+ point rides — payload size
  /// drops by ~3-4x.
  List<Object?> toJsonTuple() => [
        sequence,
        ts.toIso8601String(),
        lat,
        lon,
        altitudeM,
        speedMs,
        accuracyM,
        heading,
      ];

  static RidePoint fromJsonTuple(String rideId, List<dynamic> t) {
    return RidePoint(
      rideId: rideId,
      sequence: (t[0] as num).toInt(),
      ts: DateTime.parse(t[1] as String),
      lat: (t[2] as num).toDouble(),
      lon: (t[3] as num).toDouble(),
      altitudeM: (t[4] as num?)?.toDouble(),
      speedMs: (t[5] as num?)?.toDouble(),
      accuracyM: (t[6] as num?)?.toDouble(),
      heading: t.length > 7 ? (t[7] as num?)?.toDouble() : null,
    );
  }
}
