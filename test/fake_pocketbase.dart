// In-memory stand-in for the PocketBase backend on the NAS, used by the sync
// tests. Models exactly the behaviour the sync logic depends on:
//   • records keyed by `client_id` (our stable local id),
//   • updateRecord doing a PARTIAL merge (PATCH) so fields omitted from the
//     body are left untouched on the server,
//   • listUpdatedSince doing a strict `updated_at > since` filter.
//
// It intentionally does NOT enforce a column schema — schema coverage is
// checked separately by nas_schema_completeness_test.dart.
import 'package:motorider/services/pocketbase_client.dart';

class FakePocketBase implements SyncBackend {
  // collection -> serverId -> record JSON
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};
  int _seq = 0;

  Map<String, Map<String, dynamic>> _col(String c) =>
      _store.putIfAbsent(c, () => {});

  /// Test helper: how many records a collection currently holds.
  int count(String collection) => _col(collection).length;

  @override
  Future<Map<String, dynamic>?> findByClientId(
      String collection, String clientId) async {
    for (final rec in _col(collection).values) {
      if (rec['client_id'] == clientId) {
        return Map<String, dynamic>.from(rec);
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> createRecord(
      String collection, Map<String, Object?> body) async {
    final id = 'srv${_seq++}';
    final rec = <String, dynamic>{...body, 'id': id};
    _col(collection)[id] = rec;
    return Map<String, dynamic>.from(rec);
  }

  @override
  Future<Map<String, dynamic>> updateRecord(
      String collection, String serverId, Map<String, Object?> body) async {
    final existing = _col(collection)[serverId];
    if (existing == null) {
      throw StateError('updateRecord: no $collection record $serverId');
    }
    // PATCH semantics: only fields present in [body] are overwritten.
    existing.addAll(body);
    return Map<String, dynamic>.from(existing);
  }

  @override
  Future<List<Map<String, dynamic>>> listUpdatedSince(
      String collection, DateTime? since) async {
    final items = _col(collection)
        .values
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    final filtered = since == null
        ? items
        : items.where((r) {
            final ts = DateTime.tryParse(r['updated_at'] as String? ?? '');
            return ts != null && ts.isAfter(since);
          }).toList();
    filtered.sort((a, b) =>
        (a['updated_at'] as String).compareTo(b['updated_at'] as String));
    return filtered;
  }
}
