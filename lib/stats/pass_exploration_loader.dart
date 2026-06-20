import 'package:latlong2/latlong.dart';

import '../data/ride_repository.dart';
import '../models/ride_point.dart';
import 'pass_explorer.dart';

/// Glue between the persistence layer and the pure [explorePasses] detector.
///
/// Kept out of `pass_explorer.dart` so that module stays free of repository /
/// I/O dependencies and trivially unit-testable. This one reads the bundled
/// pass dataset and every ride's full track, then runs detection.
///
/// Detection uses the FULL point trace (no downsampling) deliberately: a
/// 250 m crossing window is easy to step over with a coarse stride, and a
/// personal log has only a handful of rides, so the O(passes × points) scan —
/// already bbox-pruned per pass — is cheap enough to just do exactly.
class PassExplorationLoader {
  PassExplorationLoader(this._rideRepo);

  final RideRepository _rideRepo;

  /// Load passes + all ride tracks and compute the full exploration result.
  Future<PassExplorationResult> compute() async {
    final passes = await loadPasses();
    final tracks = await _loadTracks();
    return explorePasses(passes, tracks);
  }

  Future<List<RideTrack>> _loadTracks() async {
    final rides = await _rideRepo.getAll();
    final tracks = <RideTrack>[];
    for (final r in rides) {
      final pts = await _rideRepo.getPoints(r.id);
      if (pts.isEmpty) continue;
      tracks.add(_toTrack(r.id, pts));
    }
    return tracks;
  }

  static RideTrack _toTrack(String rideId, List<RidePoint> pts) {
    return RideTrack(
      rideId: rideId,
      points: [for (final p in pts) LatLng(p.lat, p.lon)],
      times: [for (final p in pts) p.ts],
      // Recorded GPS speeds feed the preferred per-crossing average speed; the
      // detector falls back to corridor distance ÷ time where they're missing.
      speedsMs: [for (final p in pts) p.speedMs],
    );
  }
}
