import 'package:flutter_test/flutter_test.dart';

import 'package:motorider/services/maneuvers.dart';
import 'package:motorider/services/voice_guidance.dart';

void main() {
  // VoiceGuide constructs a FlutterTts, which registers a method-call handler on
  // a platform channel — that needs the test binding initialised. (No real TTS
  // engine runs headlessly; we observe cues via the onSpeak hook with muted:true,
  // so no plugin method is actually invoked.)
  TestWidgetsFlutterBinding.ensureInitialized();

  group('spokenDistance', () {
    test('snaps metres to readable steps', () {
      expect(spokenDistance(287), '300 Metern');
      expect(spokenDistance(45), '50 Metern');
      expect(spokenDistance(12), '10 Metern');
      expect(spokenDistance(5), '10 Metern'); // never below 10 m
    });

    test('switches to kilometres with German comma', () {
      expect(spokenDistance(1000), 'einem Kilometer');
      expect(spokenDistance(2000), '2 Kilometern');
      expect(spokenDistance(1500), '1,5 Kilometern');
      expect(spokenDistance(1350), '1,4 Kilometern'); // 1.35 -> 1.4
    });
  });

  group('maneuverPhrase', () {
    test('maps the common turn commands', () {
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 2)),
          'links abbiegen');
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 5)),
          'rechts abbiegen');
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 3)),
          'leicht links abbiegen');
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 7)),
          'scharf rechts abbiegen');
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 8)),
          'links halten');
      expect(maneuverPhrase(const Maneuver(geometryIndex: 0, command: 10)),
          'wenden');
    });

    test('roundabout names the exit naturally', () {
      expect(
        maneuverPhrase(
            const Maneuver(geometryIndex: 0, command: 13, exitNumber: 2)),
        'im Kreisverkehr die 2. Ausfahrt nehmen',
      );
      expect(
        maneuverPhrase(const Maneuver(geometryIndex: 0, command: 14)),
        'in den Kreisverkehr fahren',
      );
    });
  });

  group('buildPhrase', () {
    test('pre-cue prefixes the distance and capitalises', () {
      final m = const Maneuver(geometryIndex: 0, command: 5); // right
      expect(buildPhrase(m, CueKind.pre, meters: 300),
          'In 300 Metern rechts abbiegen');
      expect(buildPhrase(m, CueKind.pre, meters: 1500),
          'In 1,5 Kilometern rechts abbiegen');
    });

    test('final cue says "Jetzt …"', () {
      final m = const Maneuver(geometryIndex: 0, command: 2); // left
      expect(buildPhrase(m, CueKind.now), 'Jetzt links abbiegen');
    });

    test('roundabout reads as a full sentence', () {
      final m = const Maneuver(geometryIndex: 0, command: 13, exitNumber: 3);
      expect(buildPhrase(m, CueKind.pre, meters: 200),
          'In 200 Metern im Kreisverkehr die 3. Ausfahrt nehmen');
    });
  });

  group('dueCue', () {
    test('pre-cue fires within the pre radius, once', () {
      expect(dueCue(280, preFired: false, nowFired: false), CueKind.pre);
      // Already fired → nothing.
      expect(dueCue(280, preFired: true, nowFired: false), isNull);
    });

    test('no pre-cue when still far away', () {
      expect(dueCue(500, preFired: false, nowFired: false), isNull);
    });

    test('final cue fires within the now radius and takes priority', () {
      expect(dueCue(30, preFired: false, nowFired: false), CueKind.now);
      expect(dueCue(30, preFired: true, nowFired: false), CueKind.now);
      // Already fired → nothing.
      expect(dueCue(30, preFired: true, nowFired: true), isNull);
    });

    test('no pre-cue once inside the now radius (only the now cue)', () {
      // At 40 m the pre-cue should not fire belatedly; only the now cue does.
      expect(dueCue(40, preFired: false, nowFired: false), CueKind.now);
    });
  });

  group('VoiceGuide de-dupe (muted, observed via onSpeak)', () {
    // muted:true suppresses the real plugin call but onSpeak still records what
    // WOULD be spoken, so we can assert the firing logic headlessly.
    List<String> capture(void Function(VoiceGuide) drive) {
      final spoken = <String>[];
      final v = VoiceGuide(muted: true)..onSpeak = spoken.add;
      drive(v);
      return spoken;
    }

    final right = const Maneuver(geometryIndex: 4, command: 5);
    final left = const Maneuver(geometryIndex: 8, command: 2);

    test('each maneuver speaks its pre-cue once and now-cue once', () {
      final spoken = capture((v) {
        // Approach the right turn over several ticks.
        v.maybeAnnounce(right, 400); // too far — nothing
        v.maybeAnnounce(right, 290); // pre
        v.maybeAnnounce(right, 250); // already pre'd — nothing
        v.maybeAnnounce(right, 120); // still nothing (between radii)
        v.maybeAnnounce(right, 40); // now
        v.maybeAnnounce(right, 20); // already now'd — nothing
      });
      expect(spoken, [
        'In 300 Metern rechts abbiegen',
        'Jetzt rechts abbiegen',
      ]);
    });

    test('does not repeat the same cue every tick', () {
      final spoken = capture((v) {
        for (final d in [290.0, 280.0, 270.0, 260.0, 250.0]) {
          v.maybeAnnounce(right, d);
        }
      });
      expect(spoken, ['In 300 Metern rechts abbiegen']); // exactly once
    });

    test('resets cues when the next maneuver becomes active', () {
      final spoken = capture((v) {
        v.maybeAnnounce(right, 290); // pre right
        v.maybeAnnounce(right, 40); // now right
        v.maybeAnnounce(left, 290); // pre left (fresh maneuver)
        v.maybeAnnounce(left, 40); // now left
      });
      expect(spoken, [
        'In 300 Metern rechts abbiegen',
        'Jetzt rechts abbiegen',
        'In 300 Metern links abbiegen',
        'Jetzt links abbiegen',
      ]);
    });

    test('a turn already close when it becomes active skips the pre-cue', () {
      final spoken = capture((v) {
        v.maybeAnnounce(right, 50); // active at 50 m < pre floor → only now
        v.maybeAnnounce(right, 40);
      });
      expect(spoken, ['Jetzt rechts abbiegen']);
    });

    test('arrival is spoken exactly once', () {
      final spoken = capture((v) {
        v.announceArrival();
        v.announceArrival();
      });
      expect(spoken, ['Ziel erreicht']);
    });

    test('non-turn maneuvers (continue) are never announced', () {
      final spoken = capture((v) {
        v.maybeAnnounce(const Maneuver(geometryIndex: 2, command: 1), 100);
        v.maybeAnnounce(null, 100);
      });
      expect(spoken, isEmpty);
    });
  });

  group('VoiceGuide mute', () {
    test('onSpeak fires regardless of mute, but muted suppresses the engine', () {
      // We cannot reach the real plugin in a headless test, so this asserts the
      // observable contract: the de-dupe/firing pipeline runs (onSpeak fires)
      // even while muted, which is what lets the UI flip mute without replaying
      // stale cues. The plugin call itself is gated by `muted` inside _speak.
      final spoken = <String>[];
      final v = VoiceGuide(muted: true)..onSpeak = spoken.add;
      v.maybeAnnounce(const Maneuver(geometryIndex: 4, command: 5), 290);
      expect(spoken, ['In 300 Metern rechts abbiegen']);
      expect(v.muted, isTrue);
    });
  });
}
