import 'package:shared_preferences/shared_preferences.dart';

import 'nas_config.dart';

/// Typed wrapper around SharedPreferences for NAS / sync configuration.
///
/// Stores the NAS base URL, the app user's email + password, the cached
/// PocketBase JWT, and the high-water-mark timestamp of the last successful
/// pull. The password lives in plain SharedPreferences — fine for a personal
/// app behind Tailscale; if this ever stops being a one-bike toy, switch to
/// `flutter_secure_storage` (encrypted by the Android keystore).
class NasSettings {
  NasSettings._(this._prefs);

  final SharedPreferences _prefs;

  static const _kBaseUrl = 'nas.base_url';
  static const _kEmail = 'nas.email';
  static const _kPassword = 'nas.password';
  static const _kToken = 'nas.token';
  static const _kLastPullTs = 'nas.last_pull_ts';

  static Future<NasSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return NasSettings._(prefs);
  }

  String get baseUrl => _prefs.getString(_kBaseUrl) ?? NasConfig.defaultBaseUrl;
  Future<void> setBaseUrl(String v) async {
    await _prefs.setString(_kBaseUrl, v.trim());
    // URL change invalidates the cached token (it was issued by the old host).
    await _prefs.remove(_kToken);
  }

  String? get email => _prefs.getString(_kEmail);
  String? get password => _prefs.getString(_kPassword);

  Future<void> setCredentials({required String email, required String password}) async {
    await _prefs.setString(_kEmail, email.trim());
    await _prefs.setString(_kPassword, password);
    await _prefs.remove(_kToken);
  }

  Future<void> clearCredentials() async {
    await _prefs.remove(_kEmail);
    await _prefs.remove(_kPassword);
    await _prefs.remove(_kToken);
  }

  String? get token => _prefs.getString(_kToken);
  Future<void> setToken(String? v) async {
    if (v == null) {
      await _prefs.remove(_kToken);
    } else {
      await _prefs.setString(_kToken, v);
    }
  }

  DateTime? get lastPullTs {
    final iso = _prefs.getString(_kLastPullTs);
    if (iso == null) return null;
    return DateTime.tryParse(iso);
  }

  Future<void> setLastPullTs(DateTime? v) async {
    if (v == null) {
      await _prefs.remove(_kLastPullTs);
    } else {
      await _prefs.setString(_kLastPullTs, v.toIso8601String());
    }
  }

  bool get hasCredentials => (email?.isNotEmpty ?? false) && (password?.isNotEmpty ?? false);
}
