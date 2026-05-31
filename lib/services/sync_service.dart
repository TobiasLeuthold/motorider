import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../data/fillup_repository.dart';
import '../data/ride_repository.dart';
import '../models/fillup.dart';
import '../models/ride.dart';
import 'nas_settings.dart';
import 'pocketbase_client.dart';

/// Outcome of a single [SyncService.syncOnce] run.
class SyncResult {
  const SyncResult.ok({
    required this.at,
    required this.pushed,
    required this.pulled,
  })  : ok = true,
        error = null;

  const SyncResult.error({required this.at, required this.error})
      : ok = false,
        pushed = 0,
        pulled = 0;

  final bool ok;
  final DateTime? at;
  final int pushed;
  final int pulled;
  final String? error;
}

/// Orchestrates push + pull between the local SQLite DB and PocketBase for
/// both `fillups` and `rides`.
///
/// Sync semantics (single-user, append-mostly):
///   • PUSH every local row marked `pending` (creates or updates by
///     client_id).
///   • PULL every server row with `updated_at` newer than the last successful
///     pull's high-water mark, per-collection.
///   • Conflict resolution is last-write-wins on the `updated_at` column,
///     handled in each repo's applyServerRecord.
///   • Rides bundle their GPS points into a single `points_json` field on
///     the push, and rebuild the local `ride_points` table from it on pull.
///
/// Failures (network, auth, 5xx) leave pending rows pending — they retry next
/// time. No partial-success rollback needed: each row's POST/PATCH is its own
/// transaction, and `markSynced` only runs after the server acked.
class SyncService {
  SyncService(this._fillUpRepo, this._rideRepo, this._settings)
      : _client = PocketBaseClient(_settings) {
    _attachAutoTriggers();
  }

  final FillUpRepository _fillUpRepo;
  final RideRepository _rideRepo;
  final NasSettings _settings;
  final PocketBaseClient _client;

  final _controller = StreamController<SyncState>.broadcast();
  SyncState _state = const SyncState.idle();
  SyncState get state => _state;
  Stream<SyncState> get changes => _controller.stream;

  bool _inFlight = false;

  // Auto-trigger state ───────────────────────────────────────────────────
  final List<StreamSubscription<void>> _localWritesSubs = [];
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _writeDebounce;
  bool _wasOnline = true;
  static const _debounce = Duration(milliseconds: 1500);

  void _attachAutoTriggers() {
    // Either repo's writes trigger a debounced sync.
    void scheduleSync() {
      _writeDebounce?.cancel();
      _writeDebounce = Timer(_debounce, () {
        if (_settings.hasCredentials) syncOnce();
      });
    }

    _localWritesSubs.add(_fillUpRepo.localWrites.listen((_) => scheduleSync()));
    _localWritesSubs.add(_rideRepo.localWrites.listen((_) => scheduleSync()));

    // When connectivity flips from "none" back to anything else, fire a
    // sync — covers the phone-came-out-of-airplane-mode case.
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && !_wasOnline && _settings.hasCredentials) {
        syncOnce();
      }
      _wasOnline = online;
    });
  }

  Future<SyncResult> syncOnce() async {
    if (_inFlight) {
      return _state.lastResult ??
          const SyncResult.error(at: null, error: 'Sync läuft bereits');
    }
    if (!_settings.hasCredentials) {
      final r = SyncResult.error(
        at: DateTime.now(),
        error: 'Keine Zugangsdaten gespeichert.',
      );
      _emit(SyncState(running: false, lastResult: r));
      return r;
    }

    _inFlight = true;
    _emit(SyncState(running: true, lastResult: _state.lastResult));

    SyncResult result;
    try {
      final pushedFills = await _pushFillups();
      final pushedRides = await _pushRides();
      final pulledFills = await _pullFillups();
      final pulledRides = await _pullRides();
      result = SyncResult.ok(
        at: DateTime.now(),
        pushed: pushedFills + pushedRides,
        pulled: pulledFills + pulledRides,
      );
    } on NasSyncException catch (e) {
      result = SyncResult.error(at: DateTime.now(), error: e.message);
    } catch (e) {
      result = SyncResult.error(at: DateTime.now(), error: '$e');
    } finally {
      _inFlight = false;
    }
    _emit(SyncState(running: false, lastResult: result));
    return result;
  }

  // ── Fillups ─────────────────────────────────────────────────────────────

  Future<int> _pushFillups() async {
    final pending = await _fillUpRepo.getPendingForSync();
    var pushed = 0;
    for (final row in pending) {
      final body = row.toPocketBaseJson();
      final existing = await _client.findByClientId('fillups', row.id);
      if (existing == null) {
        await _client.createRecord('fillups', body);
      } else {
        await _client.updateRecord('fillups', existing['id'] as String, body);
      }
      await _fillUpRepo.markSynced(row.id);
      pushed++;
    }
    return pushed;
  }

  Future<int> _pullFillups() async {
    final since = _settings.lastPullTs;
    final items = await _client.listUpdatedSince('fillups', since);
    var applied = 0;
    DateTime? highWater;
    for (final item in items) {
      final FillUp fu;
      try {
        fu = FillUp.fromPocketBaseJson(item);
      } catch (_) {
        continue; // skip malformed
      }
      final changed = await _fillUpRepo.applyServerRecord(fu);
      if (changed) applied++;
      if (highWater == null || fu.updatedAt.isAfter(highWater)) {
        highWater = fu.updatedAt;
      }
    }
    // last_pull_ts is shared across both collections — taking the per-pull
    // max would deadlock pulls of one collection when the other lags. The
    // simpler invariant: any successful sync moves the watermark forward to
    // "now" once both collections are done. So we set it AFTER pull-rides.
    return applied;
  }

  // ── Rides ───────────────────────────────────────────────────────────────

  Future<int> _pushRides() async {
    final pending = await _rideRepo.getPendingForSync();
    var pushed = 0;
    for (final row in pending) {
      final pointsJson = await _rideRepo.serializePointsForSync(row.id);
      final body = row.toPocketBaseJson(pointsJson: pointsJson);
      final existing = await _client.findByClientId('rides', row.id);
      if (existing == null) {
        await _client.createRecord('rides', body);
      } else {
        await _client.updateRecord('rides', existing['id'] as String, body);
      }
      await _rideRepo.markSynced(row.id);
      pushed++;
    }
    return pushed;
  }

  Future<int> _pullRides() async {
    final since = _settings.lastPullTs;
    final items = await _client.listUpdatedSince('rides', since);
    var applied = 0;
    DateTime? highWater;
    for (final item in items) {
      final Ride ride;
      try {
        ride = Ride.fromPocketBaseJson(item);
      } catch (_) {
        continue;
      }
      final pointsJson = item['points_json'] as String?;
      final changed = await _rideRepo.applyServerRecord(ride, pointsJson);
      if (changed) applied++;
      if (highWater == null || ride.updatedAt.isAfter(highWater)) {
        highWater = ride.updatedAt;
      }
    }
    if (highWater != null) {
      await _settings.setLastPullTs(highWater);
    } else {
      // No new server data at all this round. Still bump the watermark so
      // we don't re-fetch the same "nothing" indefinitely.
      await _settings.setLastPullTs(DateTime.now());
    }
    return applied;
  }

  void _emit(SyncState s) {
    _state = s;
    _controller.add(s);
  }

  Future<void> dispose() async {
    _writeDebounce?.cancel();
    for (final s in _localWritesSubs) {
      await s.cancel();
    }
    await _connSub?.cancel();
    await _controller.close();
  }
}

class SyncState {
  const SyncState({required this.running, required this.lastResult});
  const SyncState.idle()
      : running = false,
        lastResult = null;

  final bool running;
  final SyncResult? lastResult;
}
