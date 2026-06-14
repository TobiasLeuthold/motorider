// Turn-by-turn guidance derived from BRouter voice hints, plus the
// speed-adaptive zoom curve. Pure Dart (no Flutter) so it's easy to test;
// the UI maps Maneuver to icons.

enum TurnSide { left, right, straight }

/// A single turn instruction along a route.
///
/// BRouter returns these as `voicehints`: tuples of
/// `[geometryIndex, command, exitNumber, distance, angle]`. We keep the index
/// (so navigation can measure the live distance to it from the cumulative
/// route length) and the command (which classifies the turn).
class Maneuver {
  const Maneuver({
    required this.geometryIndex,
    required this.command,
    this.exitNumber = 0,
  });

  /// Index into the route geometry where the maneuver happens.
  final int geometryIndex;

  /// BRouter voice-hint command code. The ones we care about:
  /// 1 continue · 2 left · 3 slight-left · 4 sharp-left · 5 right ·
  /// 6 slight-right · 7 sharp-right · 8 keep-left · 9 keep-right ·
  /// 10/11 U-turn · 12 off-route · 13/14 roundabout.
  final int command;

  /// Roundabout exit number (only meaningful for roundabout commands).
  final int exitNumber;

  /// True for an announceable turn (excludes "continue" and "off route").
  bool get isTurn => command != 1 && command != 12;

  TurnSide get side {
    switch (command) {
      case 2:
      case 3:
      case 4:
      case 8:
      case 10:
        return TurnSide.left;
      case 5:
      case 6:
      case 7:
      case 9:
      case 11:
        return TurnSide.right;
      default:
        return TurnSide.straight;
    }
  }

  /// Short German instruction text.
  String get label {
    switch (command) {
      case 2:
        return 'Links abbiegen';
      case 3:
        return 'Leicht links';
      case 4:
        return 'Scharf links';
      case 5:
        return 'Rechts abbiegen';
      case 6:
        return 'Leicht rechts';
      case 7:
        return 'Scharf rechts';
      case 8:
        return 'Links halten';
      case 9:
        return 'Rechts halten';
      case 10:
      case 11:
        return 'Wenden';
      case 13:
      case 14:
        return exitNumber > 0
            ? 'Kreisverkehr: $exitNumber. Ausfahrt'
            : 'Kreisverkehr';
      default:
        return 'Geradeaus';
    }
  }
}

/// Parse a BRouter `voicehints` array into [Maneuver]s. Tolerant of missing
/// fields and non-list input.
List<Maneuver> parseVoicehints(Object? raw) {
  if (raw is! List) return const [];
  final out = <Maneuver>[];
  for (final e in raw) {
    if (e is List && e.length >= 2) {
      final idx = (e[0] as num?)?.toInt();
      final cmd = (e[1] as num?)?.toInt();
      if (idx == null || cmd == null) continue;
      final exit = e.length >= 3 ? ((e[2] as num?)?.toInt() ?? 0) : 0;
      out.add(Maneuver(geometryIndex: idx, command: cmd, exitNumber: exit));
    }
  }
  return out;
}

/// Speed-adaptive map zoom for navigation: zoom out as you go faster (see
/// further ahead), zoom in when slow (more detail). Piecewise-linear between
/// a few calibrated stops, clamped to the end values.
double navZoomForSpeed(double kmh) {
  const stops = <List<double>>[
    [0, 16.5],
    [30, 15.6],
    [60, 14.8],
    [90, 14.1],
    [120, 13.6],
    [160, 13.1],
  ];
  if (kmh <= stops.first[0]) return stops.first[1];
  for (var i = 1; i < stops.length; i++) {
    if (kmh <= stops[i][0]) {
      final a = stops[i - 1];
      final b = stops[i];
      final t = (kmh - a[0]) / (b[0] - a[0]);
      return a[1] + (b[1] - a[1]) * t;
    }
  }
  return stops.last[1];
}
