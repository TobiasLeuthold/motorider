import 'dart:async';

import '../data/fillup_repository.dart';
import '../models/fillup.dart';
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

/// Orchestrates push + pull between the local SQLite DB and PocketBase.
///
/// Sync semantics (single-user, append-mostly):
///   • PUSH every local row marked `pending` (creates or updates by
///     client_id).
///   • PULL every server row with `updated_at` newer than the last successful
///     pull's high-water mark.
///   • Conflict resolution is last-write-wins on the `updated_at` column,
///     handled in [FillUpRepository.applyServerRecord].
///
/// Failures (network, auth, 5xx) leave pending rows pending — they retry next
/// time. No partial-success rollback needed: each row's POST/PATCH is its own
/// transaction, and `markSynced` only runs after the server acked.
class SyncService {
  SyncService(this._repo, this._settings)
      : _client = PocketBaseClient(_settings);

  final FillUpRepository _repo;
  final NasSettings _settings;
  final PocketBaseClient _client;

  final _controller = StreamController<SyncState>.broadcast();
  SyncState _state = const SyncState.idle();
  SyncState get state => _state;
  Stream<SyncState> get changes => _controller.stream;

  bool _inFlight = false;

  Future<SyncResult> syncOnce() async {
    if (_inFlight) {
      return _state.lastResult ?? const SyncResult.error(at: null, error: 'Sync läuft bereits');
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
      final pushed = await _push();
      final pulled = await _pull();
      result = SyncResult.ok(at: DateTime.now(), pushed: pushed, pulled: pulled);
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

  Future<int> _push() async {
    final pending = await _repo.getPendingForSync();
    var pushed = 0;
    for (final row in pending) {
      final body = row.toPocketBaseJson();
      final existing = await _client.findByClientId(row.id);
      if (existing == null) {
        await _client.createRecord(body);
      } else {
        await _client.updateRecord(existing['id'] as String, body);
      }
      await _repo.markSynced(row.id);
      pushed++;
    }
    return pushed;
  }

  Future<int> _pull() async {
    final since = _settings.lastPullTs;
    final items = await _client.listUpdatedSince(since);
    var applied = 0;
    DateTime? highWater;
    for (final item in items) {
      final FillUp fu;
      try {
        fu = FillUp.fromPocketBaseJson(item);
      } catch (e) {
        // Bad row on the server (probably manually edited with a missing
        // field). Skip but don't fail the whole pull.
        continue;
      }
      final changed = await _repo.applyServerRecord(fu);
      if (changed) applied++;
      if (highWater == null || fu.updatedAt.isAfter(highWater)) {
        highWater = fu.updatedAt;
      }
    }
    if (highWater != null) {
      await _settings.setLastPullTs(highWater);
    }
    return applied;
  }

  void _emit(SyncState s) {
    _state = s;
    _controller.add(s);
  }

  Future<void> dispose() async {
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
