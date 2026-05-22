import 'package:geolocator/geolocator.dart';

class LocationResult {
  const LocationResult({this.position, this.error});
  final Position? position;
  final String? error;

  bool get ok => position != null;
}

class LocationService {
  /// Returns a current GPS position or an error string suitable for display.
  static Future<LocationResult> getCurrent({
    LocationAccuracy accuracy = LocationAccuracy.medium,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      return const LocationResult(error: 'Standortdienste sind deaktiviert');
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      return const LocationResult(error: 'Standortzugriff verweigert');
    }
    if (perm == LocationPermission.deniedForever) {
      return const LocationResult(
          error: 'Standortzugriff dauerhaft verweigert (in den Einstellungen erlauben)');
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy, timeLimit: timeout),
      );
      return LocationResult(position: pos);
    } catch (e) {
      return LocationResult(error: 'Standort nicht verfügbar: $e');
    }
  }
}
