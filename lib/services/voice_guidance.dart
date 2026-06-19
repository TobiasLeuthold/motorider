// Spoken German turn-by-turn guidance.
//
// The phrase-building and "what should I say now?" decision are PURE Dart (no
// Flutter, no plugin) so they're trivially unit-testable. [VoiceGuide] is a thin
// wrapper that drives the flutter_tts plugin around those pure helpers, tracks
// which cues have already fired for the current maneuver (so nothing repeats
// every GPS tick), and honours a mute toggle.

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'maneuvers.dart';

/// The two cues we speak per maneuver: an early heads-up ("In 300 Metern rechts
/// abbiegen") and a final one right at the turn ("Jetzt rechts abbiegen").
enum CueKind { pre, now }

/// Distance (m) at which the early pre-announcement fires. Tuned for motorcycle
/// speeds: ~300 m gives a rider time to react at country-road pace without being
/// so early it's forgotten. We announce the first time the rider is *within*
/// this radius (and still comfortably before the turn).
const double kPreAnnounceM = 300;

/// Don't pre-announce a turn that's already closer than this when it first
/// becomes the active maneuver — at that range only the final cue makes sense
/// (avoids a useless "In 300 Metern …" when the turn is right there).
const double kPreAnnounceMinM = 80;

/// Distance (m) at which the final "Jetzt …" cue fires.
const double kNowAnnounceM = 45;

/// Round a distance to a natural spoken value: tens below 100 m, fifties below
/// 1 km, then "ein Kilometer" / "1,5 Kilometer". German uses a comma decimal.
@visibleForTesting
String spokenDistance(double meters) {
  if (meters >= 1000) {
    final km = meters / 1000.0;
    // One decimal, German comma. Whole kilometres read without the ",0".
    final rounded = (km * 10).round() / 10.0;
    if (rounded == rounded.roundToDouble()) {
      final n = rounded.round();
      return n == 1 ? 'einem Kilometer' : '$n Kilometern';
    }
    final txt = rounded.toStringAsFixed(1).replaceAll('.', ',');
    return '$txt Kilometern';
  }
  // Snap to a readable step so we don't say "In 287 Metern".
  final step = meters < 100 ? 10 : 50;
  final r = (meters / step).round() * step;
  final n = r < 10 ? 10 : r; // never announce 0 m as a pre-cue
  return '$n Metern';
}

/// The bare maneuver instruction, phrased for speech. Reuses the same command
/// classification as the visual banner but says roundabouts more naturally
/// ("die 2. Ausfahrt nehmen") and avoids the colon in [Maneuver.label].
@visibleForTesting
String maneuverPhrase(Maneuver m) {
  switch (m.command) {
    case 2:
      return 'links abbiegen';
    case 3:
      return 'leicht links abbiegen';
    case 4:
      return 'scharf links abbiegen';
    case 5:
      return 'rechts abbiegen';
    case 6:
      return 'leicht rechts abbiegen';
    case 7:
      return 'scharf rechts abbiegen';
    case 8:
      return 'links halten';
    case 9:
      return 'rechts halten';
    case 10:
    case 11:
      return 'wenden';
    case 13:
    case 14:
      return m.exitNumber > 0
          ? 'im Kreisverkehr die ${m.exitNumber}. Ausfahrt nehmen'
          : 'in den Kreisverkehr fahren';
    default:
      return 'der Straße folgen';
  }
}

/// Full German sentence for a [cue] about [m]. The pre-cue prefixes the distance
/// ("In 300 Metern …"); the final cue says "Jetzt …". Capitalises the first
/// letter so it reads as a sentence.
///
/// This is the single PURE phrase builder the requirement calls for: command +
/// distance → spoken German string.
String buildPhrase(Maneuver m, CueKind cue, {double? meters}) {
  final instruction = maneuverPhrase(m);
  final String sentence;
  switch (cue) {
    case CueKind.pre:
      final d = meters ?? 0;
      sentence = 'In ${spokenDistance(d)} $instruction';
    case CueKind.now:
      sentence = 'Jetzt $instruction';
  }
  // Capitalise the first character (instructions are lower-case fragments).
  return sentence[0].toUpperCase() + sentence.substring(1);
}

/// Spoken arrival cue.
const String kArrivalPhrase = 'Ziel erreicht';

/// PURE decision: given the live distance to the next maneuver and which cues
/// have already fired for it, which cue (if any) should be spoken now? Returns
/// null when nothing new should be said.
///
/// - [pre] fires once when the rider is within [kPreAnnounceM] (but the turn
///   wasn't already closer than [kPreAnnounceMinM] when it became active).
/// - [now] fires once when within [kNowAnnounceM].
///
/// [preFired]/[nowFired] track per-maneuver state the caller resets when the
/// active maneuver changes.
CueKind? dueCue(
  double metersToTurn, {
  required bool preFired,
  required bool nowFired,
}) {
  if (!nowFired && metersToTurn <= kNowAnnounceM) return CueKind.now;
  if (!preFired &&
      metersToTurn <= kPreAnnounceM &&
      metersToTurn > kNowAnnounceM &&
      metersToTurn >= kPreAnnounceMinM) {
    return CueKind.pre;
  }
  return null;
}

/// Thin flutter_tts wrapper: German voice, mute toggle, per-maneuver de-dupe of
/// cues, and one-shot arrival. All the *decisions* live in the pure helpers
/// above; this just tracks firing state and calls the plugin.
class VoiceGuide {
  VoiceGuide({FlutterTts? tts, this.muted = false}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// When true, [maybeAnnounce]/[announceArrival] become no-ops (no speech).
  /// Default false → audio on (the requirement's default-ON behaviour, with the
  /// UI toggle inverting this).
  bool muted;

  bool _ready = false;
  bool _disposed = false;

  // Per-maneuver de-dupe. Identity of the "current" maneuver is its geometry
  // index + command; when that changes, the fired flags reset so the next turn
  // gets its own pre/now cues.
  int? _curKey;
  bool _preFired = false;
  bool _nowFired = false;
  bool _arrivalSpoken = false;

  /// Hook so tests / the emulator can observe what would be spoken without a
  /// real voice. Always called (even when muted is false) right before speak().
  @visibleForTesting
  void Function(String phrase)? onSpeak;

  Future<void> init() async {
    if (_ready || _disposed) return;
    try {
      await _tts.setLanguage('de-DE');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      // Don't queue a backlog of stale cues; the newest instruction wins.
      await _tts.awaitSpeakCompletion(true);
      _ready = true;
    } catch (e) {
      // TTS unavailable (e.g. no engine) — guidance silently degrades; the
      // visual banner still works.
      if (kDebugMode) debugPrint('VoiceGuide init failed: $e');
    }
  }

  /// Tell the guide which maneuver is currently the active "next turn" and how
  /// far away it is, then speak any cue that's now due (once each). [meters] is
  /// the live distance to the maneuver. No-op while muted (apart from tracking
  /// firing state, so unmuting mid-turn doesn't suddenly replay an old cue).
  void maybeAnnounce(Maneuver? maneuver, double meters) {
    if (maneuver == null || !maneuver.isTurn) return;
    final key = maneuver.geometryIndex * 100 + maneuver.command;
    if (key != _curKey) {
      _curKey = key;
      _preFired = false;
      _nowFired = false;
      // If the turn is already closer than the pre-cue floor when it becomes
      // active, suppress the pre-cue entirely (only the "Jetzt …" makes sense).
      if (meters < kPreAnnounceMinM) _preFired = true;
    }
    final cue = dueCue(meters, preFired: _preFired, nowFired: _nowFired);
    if (cue == null) return;
    if (cue == CueKind.pre) _preFired = true;
    if (cue == CueKind.now) _nowFired = true;
    _speak(buildPhrase(maneuver, cue, meters: meters));
  }

  /// Speak "Ziel erreicht" exactly once.
  void announceArrival() {
    if (_arrivalSpoken) return;
    _arrivalSpoken = true;
    _speak(kArrivalPhrase);
  }

  void _speak(String phrase) {
    onSpeak?.call(phrase);
    if (kDebugMode) debugPrint('VoiceGuide speak: "$phrase" (muted=$muted)');
    if (muted || _disposed) return;
    if (!_ready) {
      // Initialise lazily, then speak.
      init().then((_) {
        if (!_disposed && !muted) _tts.speak(phrase);
      });
      return;
    }
    _tts.speak(phrase);
  }

  /// Stop any in-flight speech (e.g. when muting). Safe to call repeatedly.
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }
}
