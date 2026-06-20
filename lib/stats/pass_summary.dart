import 'package:intl/intl.dart';

import 'pass_explorer.dart';

/// Pure formatting + aggregation helpers for the Pässe UI (Stage C).
///
/// Everything here is side-effect free and Flutter-binding free so it can be
/// exercised headlessly in `test/pass_summary_test.dart` — the detail screen
/// and the "Meine Pässe" overview only render what these functions return.

/// Format a duration in seconds the way the pass UI shows it:
/// `'0:42'` (m:ss) under a minute-of-display, `'12:05'` for minutes,
/// `'1:03:20'` once it crosses an hour. Negative/zero → `'–'`.
String formatPassDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '–';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mm:$ss';
  return '$m:$ss';
}

/// Compact "time spent on passes" label for the overview hero stat. Rolls up
/// into hours once there's enough: `'48 min'`, `'2,5 h'`. Zero → `'–'`.
String formatTotalTimeOnPasses(int seconds, {String locale = 'de_CH'}) {
  if (seconds <= 0) return '–';
  if (seconds < 3600) {
    final mins = (seconds / 60).round();
    return '$mins min';
  }
  final hours = seconds / 3600.0;
  final fmt = NumberFormat('#,##0.#', locale);
  return '${fmt.format(hours)} h';
}

/// Speed rounded to a whole km/h with a unit, e.g. `'87 km/h'`. Null → `'–'`.
String formatSpeedKmh(double? kmh) {
  if (kmh == null || kmh <= 0) return '–';
  return '${kmh.round()} km/h';
}

/// One-line headline for the single fastest crossing in the collection, e.g.
/// `'Furkapass · 92 km/h'`. Null when there is no measured crossing yet.
String? fastestCrossingHeadline(FastestCrossing? fastest) {
  if (fastest == null) return null;
  return '${fastest.pass.name} · ${formatSpeedKmh(fastest.avgSpeedKmh)}';
}

/// A short German recap line for ONE pass's personal history, used as the
/// detail-screen subtitle and elsewhere. Examples:
///   not crossed        → `'Noch nicht erkundet'`
///   crossed once       → `'1× erkundet'`
///   crossed, best known → `'3× erkundet · Ø-Bestzeit 88 km/h'`
String passHistorySummary(PassProgress p) {
  if (!p.crossed) return 'Noch nicht erkundet';
  final times = '${p.count}× erkundet';
  final best = p.bestSpeedKmh;
  if (best == null) return times;
  return '$times · Bestschnitt ${formatSpeedKmh(best)}';
}

/// The set of headline facts shown as stat tiles on the detail screen, in the
/// order they should appear. Each entry is (label, value-or-dash). Pulling this
/// out keeps the widget dumb and lets a test pin the wording/units down.
List<({String label, String value})> passFactTiles(
  Pass p, {
  String locale = 'de_CH',
}) {
  final dec = NumberFormat.decimalPattern(locale);
  String m(int? v) => v == null ? '–' : '${dec.format(v)} m';
  String km(double? v) =>
      v == null ? '–' : '${NumberFormat('#,##0.0', locale).format(v)} km';
  String pct(double? v) =>
      v == null ? '–' : '${NumberFormat('#,##0', locale).format(v)} %';
  String degKm(double? v) =>
      v == null ? '–' : '${v.round()} °/km';
  String count(int? v) => v == null ? '–' : dec.format(v);

  return [
    (label: 'Höhe', value: m(p.ele)),
    (label: 'Anstieg', value: m(p.heightGainM)),
    (label: 'Länge', value: km(p.lengthKm)),
    (label: 'Max. Steigung', value: pct(p.maxGradientPct)),
    (label: 'Kehren', value: count(p.hairpins)),
    (label: 'Kurvigkeit', value: degKm(p.curvinessScore)),
  ];
}

/// Human label for the highest crossed/uncrossed pass card on the overview,
/// e.g. `'Nufenenpass · 2478 m'`. Null when there is no such pass.
String? highestPassLabel(PassProgress? p) {
  if (p == null) return null;
  final ele = p.pass.ele;
  return ele == null ? p.pass.name : '${p.pass.name} · $ele m';
}

/// Favourite (most-crossed) pass label, e.g. `'Sustenpass · 5×'`. Null when
/// nothing has been crossed yet.
String? favouritePassLabel(PassProgress? p) {
  if (p == null || !p.crossed) return null;
  return '${p.pass.name} · ${p.count}×';
}

/// Sum of every canton's done counts (a multi-canton pass thus contributes to
/// more than one) — used only as a denominator-free "regions touched" feel-good
/// number on the overview. Counts cantons with at least one explored pass.
int cantonsWithProgress(Map<String, CantonProgress> perCanton) {
  var n = 0;
  for (final c in perCanton.values) {
    if (c.done > 0) n++;
  }
  return n;
}
