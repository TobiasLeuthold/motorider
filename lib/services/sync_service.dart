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
  /// [backend] defaults to a real [PocketBaseClient]; tests inject a fake.
  /// [autoSync] wires the connectivity + local-write triggers — disabled in
  /// tests so we don't touch the `connectivity_plus` platform channel and so
  /// syncs only run when the test explicitly calls [syncOnce].
  SyncService(
    this._fillUpRepo,
    this._rideRepo,
    this._settings, {
    SyncBackend? backend,
    bool autoSync = true,
  }) : _client = backend ?? PocketBaseClient(_settings) {
    if (autoSync) _attachAutoTriggers();
  }

  final FillUpRepository _fillUpRepo;
  final RideRepository _rideRepo;
  final NasSettings _settings;
  final SyncBackend _client;

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
      final (pulledFills, fillHighWater) = await _pullFillups();
      final (pulledRides, rideHighWater) = await _pullRides();
      await _advanceWatermark(fillHighWater, rideHighWater);
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
      final existing = await _client.findByClientId('fillups', row.id);
      if (existing == null) {
        await _client.createRecord('fillups', row.toPocketBaseJson());
        await _fillUpRepo.markSynced(row.id);
        pushed++;
        continue;
      }
      // Last-write-wins guard: never let a local row overwrite a server copy
      // that is newer or equal. This is what keeps a reinstall from losing
      // data: the CSV seed re-creates rows as `pending` with updated_at = the
      // fill date (older than any real edit), and without this guard the stale
      // seed row would PATCH the server, regress its updated_at, and the pull's
      // LWW would then skip the genuine edit — silently dropping e.g. a
      // location the user added before reinstalling.
      final serverTs = _serverUpdatedAt(existing);
      if (serverTs != null && !row.updatedAt.isAfter(serverTs)) {
        // Server copy is newer or equal — don't clobber it. Leave the row
        // pending and let the pull reconcile it (adopt the server copy and mark
        // it synced). This includes the exact-tie case, which is how a row
        // whose server timestamp was regressed by the old push bug gets its
        // data back — see FillUpRepository.applyServerRecord.
        continue;
      }
      await _client.updateRecord(
          'fillups', existing['id'] as String, row.toPocketBaseJson());
      await _fillUpRepo.markSynced(row.id);
      pushed++;
    }
    return pushed;
  }

  /// Returns `(rows applied locally, max server updated_at seen)`. The caller
  /// folds the high-water timestamp into the shared watermark — see
  /// [_advanceWatermark].
  Future<(int, DateTime?)> _pullFillups() async {
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
    return (applied, highWater);
  }

  // ── Rides ───────────────────────────────────────────────────────────────

  Future<int> _pushRides() async {
    final pending = await _rideRepo.getPendingForSync();
    var pushed = 0;
    for (final row in pending) {
      final existing = await _client.findByClientId('rides', row.id);
      if (existing == null) {
        final pointsJson = await _rideRepo.serializePointsForSync(row.id);
        await _client.createRecord(
            'rides', row.toPocketBaseJson(pointsJson: pointsJson));
        await _rideRepo.markSynced(row.id);
        pushed++;
        continue;
      }
      // Same last-write-wins guard as _pushFillups — don't clobber a newer (or
      // equal) server copy with a stale local (e.g. re-seeded) row; leave it
      // pending for the pull to reconcile.
      final serverTs = _serverUpdatedAt(existing);
      if (serverTs != null && !row.updatedAt.isAfter(serverTs)) {
        continue;
      }
      final pointsJson = await _rideRepo.serializePointsForSync(row.id);
      await _client.updateRecord(
          'rides', existing['id'] as String, row.toPocketBaseJson(pointsJson: pointsJson));
      await _rideRepo.markSynced(row.id);
      pushed++;
    }
    return pushed;
  }

  /// Returns `(rows applied locally, max server updated_at seen)`.
  Future<(int, DateTime?)> _pullRides() async {
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
    return (applied, highWater);
  }

  /// Parse the server record's app-level `updated_at` (an ISO-8601 string the
  /// client wrote and the server stores verbatim). Returns null if absent or
  /// unparseable, in which case the push falls back to writing.
  static DateTime? _serverUpdatedAt(Map<String, dynamic> record) {
    final raw = record['updated_at'];
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  /// Advance the shared high-water mark to the latest `updated_at` actually
  /// seen from the server across BOTH collections. Deliberately never bumps to
  /// `DateTime.now()`: the mark is only ever compared against server-sourced
  /// timestamps, so using the local clock here would skip records under any
  /// client/server clock skew. When nothing new was pulled (both null) the
  /// mark is left untouched — re-querying "since <mark>" next time is cheap and
  /// returns nothing.
  Future<void> _advanceWatermark(DateTime? a, DateTime? b) async {
    DateTime? hw = a;
    if (b != null && (hw == null || b.isAfter(hw))) hw = b;
    if (hw != null) await _settings.setLastPullTs(hw);
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
