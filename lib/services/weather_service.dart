import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/ride_repository.dart';
import '../models/ride_point.dart';

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

/// Number of points sampled along the polyline for multi-location queries.
/// 5 is a sweet spot for Swiss-scale rides: a 100 km Pässe-tour gets samples
/// every ~20 km, enough to catch a valley-vs-alpine weather split. Bumping
/// this higher hits Open-Meteo's free-tier rate limit faster.
const _maxSamplePoints = 5;

/// Weather conditions captured at one sample point along the ride. The
/// timestamp is the rider's clock at that location; we look up the matching
/// hourly forecast for it.
class _SamplePointWeather {
  const _SamplePointWeather({
    required this.tempC,
    required this.precipitationMm,
    required this.windKmh,
    required this.weatherCode,
  });
  final double? tempC;
  final double? precipitationMm;
  final double? windKmh;
  final int? weatherCode;
}

/// Fetches weather along the ride and aggregates it into a single summary.
///
/// Strategy: sample up to [_maxSamplePoints] points evenly through the GPS
/// trace, hit Open-Meteo concurrently for each, pick the hour at each
/// location that matches the rider's actual timestamp there, then aggregate.
/// This captures geographic variance — a Sustenpass climb where the bottom
/// is 22°C and the top is 8°C — that single-location sampling misses.
class WeatherService {
  /// Public entry point. Pulls the ride + its points from [repo], runs the
  /// enrichment, and persists the result. Returns true on successful update.
  ///
  /// Also used by the detail screen's "Wetter abrufen" retry button — same
  /// code path either way, so a retry behaves identically to first-time
  /// enrichment.
  static Future<bool> enrichRide({
    required RideRepository repo,
    required String rideId,
  }) async {
    final ride = await repo.getById(rideId);
    if (ride == null) return false;
    final points = await repo.getPoints(rideId);
    if (points.isEmpty) {
      debugPrint('[motorider] enrichRide: $rideId has no points, skipping');
      return false;
    }

    final summary = await fetchForRide(points);
    if (summary == null) return false;

    final enriched = ride.copyWith(
      tempMinC: summary.tempMinC,
      tempMaxC: summary.tempMaxC,
      tempAvgC: summary.tempAvgC,
      precipitationMm: summary.precipitationMm,
      windMaxKmh: summary.windMaxKmh,
      weatherCode: summary.weatherCode,
      weatherFetchedAt: DateTime.now(),
    );
    await repo.upsert(enriched);
    debugPrint(
      '[motorider] enrichRide $rideId: '
      'temp ${summary.tempMinC?.toStringAsFixed(0)}–${summary.tempMaxC?.toStringAsFixed(0)}°C, '
      'precip ${summary.precipitationMm?.toStringAsFixed(1)}mm, '
      'wind ${summary.windMaxKmh?.toStringAsFixed(0)}km/h, '
      'code ${summary.weatherCode}',
    );
    return true;
  }

  /// Core multi-location fetch. Exposed for testability + so the tracker can
  /// call it directly without the repo round-trip.
  static Future<WeatherSummary?> fetchForRide(List<RidePoint> points) async {
    final samples = _pickSamplePoints(points);
    final futures = samples.map(_fetchAtPoint).toList();
    final results = await Future.wait(futures);

    final valid = results.whereType<_SamplePointWeather>().toList();
    if (valid.isEmpty) {
      debugPrint('[motorider] WeatherService: all ${samples.length} samples failed');
      return null;
    }
    return _aggregate(valid);
  }

  /// Pick up to [_maxSamplePoints] evenly spaced points (by sequence index)
  /// from the polyline. If the ride is shorter than that, sample every point.
  static List<RidePoint> _pickSamplePoints(List<RidePoint> points) {
    if (points.length <= _maxSamplePoints) return points;
    final samples = <RidePoint>[];
    for (var i = 0; i < _maxSamplePoints; i++) {
      // Evenly spaced including both endpoints.
      final idx =
          ((i / (_maxSamplePoints - 1)) * (points.length - 1)).round();
      samples.add(points[idx]);
    }
    return samples;
  }

  static Future<_SamplePointWeather?> _fetchAtPoint(RidePoint point) async {
    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast').replace(
      queryParameters: {
        'latitude': point.lat.toStringAsFixed(4),
        'longitude': point.lon.toStringAsFixed(4),
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
      debugPrint('[motorider] WeatherService timed out for ${point.lat},${point.lon}');
      return null;
    } on SocketException catch (e) {
      debugPrint('[motorider] WeatherService network error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[motorider] WeatherService unexpected error: $e');
      return null;
    }
    if (resp.statusCode != 200) {
      debugPrint('[motorider] WeatherService HTTP ${resp.statusCode}');
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

    // Find the closest hour to this sample's actual timestamp. Open-Meteo
    // serves UTC hours when timezone=UTC.
    final targetUtc = point.ts.toUtc();
    int? bestIdx;
    Duration bestGap = const Duration(days: 999);
    for (var i = 0; i < times.length; i++) {
      final t = DateTime.parse('${times[i]}Z');
      final gap = (t.difference(targetUtc)).abs();
      if (gap < bestGap) {
        bestGap = gap;
        bestIdx = i;
      }
    }
    if (bestIdx == null) return null;
    // If even the closest hour is more than 90 min away, the API doesn't
    // have data for this window yet (recent ride, hourly slot not published).
    if (bestGap > const Duration(minutes: 90)) {
      debugPrint('[motorider] WeatherService: closest hour ${bestGap.inMinutes}min off for ${point.lat},${point.lon}');
      return null;
    }
    final i = bestIdx;

    return _SamplePointWeather(
      tempC: (i < temps.length) ? (temps[i] as num?)?.toDouble() : null,
      precipitationMm: (i < precs.length) ? (precs[i] as num?)?.toDouble() : null,
      windKmh: (i < winds.length) ? (winds[i] as num?)?.toDouble() : null,
      weatherCode: (i < codes.length) ? (codes[i] as num?)?.toInt() : null,
    );
  }

  static WeatherSummary _aggregate(List<_SamplePointWeather> samples) {
    double? tempMin, tempMax;
    double tempSum = 0;
    var tempCount = 0;
    double precMax = 0;
    double? windMax;
    int worstCode = 0;

    for (final s in samples) {
      final t = s.tempC;
      if (t != null) {
        tempMin = tempMin == null ? t : math.min(tempMin, t);
        tempMax = tempMax == null ? t : math.max(tempMax, t);
        tempSum += t;
        tempCount++;
      }
      // Precipitation: "worst encountered" across the ride is the most
      // useful summary for "did I get rained on" — summing would
      // double-count overlapping hours across nearby samples.
      final p = s.precipitationMm;
      if (p != null && p > precMax) precMax = p;
      final w = s.windKmh;
      if (w != null) {
        windMax = windMax == null ? w : math.max(windMax, w);
      }
      final c = s.weatherCode;
      if (c != null && weatherSeverity(c) > weatherSeverity(worstCode)) {
        worstCode = c;
      }
    }

    return WeatherSummary(
      tempMinC: tempMin,
      tempMaxC: tempMax,
      tempAvgC: tempCount > 0 ? tempSum / tempCount : null,
      precipitationMm: precMax,
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
