import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Per-ride weather summary computed by [WeatherService] from the hours that
/// overlap the ride window. All fields are nullable so we can serialize
/// "data was fetched, that field happened to be missing" distinctly from
/// "never fetched".
class WeatherSummary {
  const WeatherSummary({
    this.tempMinC,
    this.tempMaxC,
    this.tempAvgC,
    this.precipitationMm,
    this.windMaxKmh,
    this.weatherCode,
  });

  final double? tempMinC;
  final double? tempMaxC;
  final double? tempAvgC;
  final double? precipitationMm;
  final double? windMaxKmh;
  final int? weatherCode;
}

/// Fetches weather along the ride and aggregates it into a single summary.
///
/// Uses Open-Meteo's forecast endpoint (which serves both `past_days` and
/// near-future) so a ride that just ended a minute ago resolves on the same
/// call as one from last week. No API key required.
///
/// Spatial resolution is one location (the ride's starting GPS fix) — fine
/// for typical Swiss rides under ~100 km radius; the grid is ~10 km wide.
/// Adding multi-point sampling is a one-line change to use the comma-list
/// form of `latitude`/`longitude` parameters.
class WeatherService {
  static Future<WeatherSummary?> fetch({
    required double lat,
    required double lon,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast').replace(
      queryParameters: {
        'latitude': lat.toStringAsFixed(4),
        'longitude': lon.toStringAsFixed(4),
        'hourly':
            'temperature_2m,precipitation,wind_speed_10m,weathercode',
        'past_days': '14',
        'forecast_days': '1',
        'timezone': 'UTC',
        'wind_speed_unit': 'kmh',
        'temperature_unit': 'celsius',
        'precipitation_unit': 'mm',
      },
    );

    final http.Response resp;
    try {
      resp = await http.get(uri).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      debugPrint('[motorider] WeatherService timed out for $lat,$lon');
      return null;
    } on SocketException catch (e) {
      debugPrint('[motorider] WeatherService network error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[motorider] WeatherService unexpected error: $e');
      return null;
    }
    if (resp.statusCode != 200) {
      debugPrint('[motorider] WeatherService HTTP ${resp.statusCode}: '
          '${resp.body.substring(0, math.min(120, resp.body.length))}');
      return null;
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final hourly = json['hourly'] as Map<String, dynamic>?;
    if (hourly == null) return null;

    final times = (hourly['time'] as List?)?.cast<String>() ?? const [];
    final temps = (hourly['temperature_2m'] as List?) ?? const [];
    final precs = (hourly['precipitation'] as List?) ?? const [];
    final winds = (hourly['wind_speed_10m'] as List?) ?? const [];
    final codes = (hourly['weathercode'] as List?) ?? const [];

    // Open-Meteo timestamps are in UTC when timezone=UTC. Match against the
    // ride window with one-hour slack on each side (so a ride starting at
    // 14:55 still sees the 14:00 row).
    final windowStart = startUtc.subtract(const Duration(hours: 1));
    final windowEnd = endUtc.add(const Duration(hours: 1));

    double? tempMin, tempMax;
    double tempSum = 0;
    var tempCount = 0;
    var precSum = 0.0;
    double? windMax;
    int worstCode = 0;
    var matched = 0;

    for (var i = 0; i < times.length; i++) {
      final t = DateTime.parse('${times[i]}Z');
      if (t.isBefore(windowStart) || t.isAfter(windowEnd)) continue;
      matched++;

      final temp = (i < temps.length) ? (temps[i] as num?)?.toDouble() : null;
      final prec = (i < precs.length) ? (precs[i] as num?)?.toDouble() : null;
      final wind = (i < winds.length) ? (winds[i] as num?)?.toDouble() : null;
      final code = (i < codes.length) ? (codes[i] as num?)?.toInt() : null;

      if (temp != null) {
        tempMin = tempMin == null ? temp : math.min(tempMin, temp);
        tempMax = tempMax == null ? temp : math.max(tempMax, temp);
        tempSum += temp;
        tempCount++;
      }
      if (prec != null) precSum += prec;
      if (wind != null) {
        windMax = windMax == null ? wind : math.max(windMax, wind);
      }
      if (code != null && weatherSeverity(code) > weatherSeverity(worstCode)) {
        worstCode = code;
      }
    }

    if (matched == 0) {
      debugPrint('[motorider] WeatherService: no hours matched ride window '
          '($startUtc..$endUtc)');
      return null;
    }

    return WeatherSummary(
      tempMinC: tempMin,
      tempMaxC: tempMax,
      tempAvgC: tempCount > 0 ? tempSum / tempCount : null,
      precipitationMm: precSum,
      windMaxKmh: windMax,
      weatherCode: worstCode,
    );
  }

  /// Higher = worse. Used to pick the most-noteworthy weather code across
  /// the hours of a ride (raw WMO codes aren't ordered by severity).
  static int weatherSeverity(int code) {
    if (code >= 95) return 100; // thunderstorm
    if (code >= 80) return 70; // rain/snow showers
    if (code >= 71) return 60; // snow
    if (code >= 61) return 50; // rain
    if (code >= 51) return 30; // drizzle
    if (code >= 45) return 20; // fog
    if (code >= 1) return 10; // clouds
    return 0; // clear
  }

  /// German label for a WMO weather code.
  static String labelForCode(int code) {
    return switch (code) {
      0 => 'Klar',
      1 => 'Überwiegend klar',
      2 => 'Teils bewölkt',
      3 => 'Bewölkt',
      45 || 48 => 'Nebel',
      51 || 53 || 55 => 'Nieselregen',
      56 || 57 => 'Gefrierender Niesel',
      61 || 63 || 65 => 'Regen',
      66 || 67 => 'Gefrierender Regen',
      71 || 73 || 75 => 'Schnee',
      77 => 'Schneegriesel',
      80 || 81 || 82 => 'Regenschauer',
      85 || 86 => 'Schneeschauer',
      95 => 'Gewitter',
      96 || 99 => 'Gewitter mit Hagel',
      _ => 'Unbekannt',
    };
  }

  static IconData iconForCode(int code) {
    if (code >= 95) return Icons.thunderstorm_rounded;
    if (code >= 71 && code <= 77) return Icons.ac_unit_rounded;
    if (code >= 85 && code <= 86) return Icons.ac_unit_rounded;
    if (code >= 80 && code <= 82) return Icons.water_drop_rounded;
    if (code >= 51 && code <= 67) return Icons.water_drop_rounded;
    if (code == 45 || code == 48) return Icons.foggy;
    if (code == 3) return Icons.cloud_rounded;
    if (code == 1 || code == 2) return Icons.cloud_outlined;
    return Icons.wb_sunny_rounded;
  }
}
