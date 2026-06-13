import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'nas_settings.dart';

class NasSyncException implements Exception {
  NasSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The narrow surface [SyncService] needs from a sync backend. Real syncs use
/// [PocketBaseClient]; tests inject an in-memory fake so the push/pull/seed
/// orchestration can be exercised without a live PocketBase.
abstract class SyncBackend {
  Future<Map<String, dynamic>?> findByClientId(String collection, String clientId);
  Future<Map<String, dynamic>> createRecord(String collection, Map<String, Object?> body);
  Future<Map<String, dynamic>> updateRecord(
    String collection,
    String serverId,
    Map<String, Object?> body,
  );
  Future<List<Map<String, dynamic>>> listUpdatedSince(String collection, DateTime? since);
}

/// Thin wrapper over PocketBase's REST API scoped to the `fillups` collection.
///
/// Caches the auth token in [NasSettings] and re-logs in transparently when a
/// request returns 401. All network errors are normalized to
/// [NasSyncException] so the sync layer doesn't have to know about
/// `SocketException` / `TimeoutException`.
class PocketBaseClient implements SyncBackend {
  PocketBaseClient(this._settings);

  final NasSettings _settings;
  static const _timeout = Duration(seconds: 15);

  String get _base => _settings.baseUrl;

  /// Force a fresh login. Returns the new token.
  Future<String> login() async {
    final email = _settings.email;
    final password = _settings.password;
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      throw NasSyncException('Email/Passwort fehlt — bitte in Einstellungen eintragen.');
    }
    final uri = Uri.parse('$_base/api/collections/users/auth-with-password');
    final http.Response resp;
    try {
      resp = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'identity': email, 'password': password}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw NasSyncException('Timeout beim Login (NAS erreichbar?)');
    } on SocketException catch (e) {
      throw NasSyncException('Netzwerkfehler beim Login: ${e.message}');
    }
    if (resp.statusCode != 200) {
      throw NasSyncException('Login fehlgeschlagen: HTTP ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = body['token'] as String;
    await _settings.setToken(token);
    return token;
  }

  Future<String> _ensureToken() async {
    final cached = _settings.token;
    if (cached != null && cached.isNotEmpty) return cached;
    return await login();
  }

  /// Find a server-side record by its `client_id` (our local UUID).
  /// Returns null if not present on the server.
  @override
  Future<Map<String, dynamic>?> findByClientId(
    String collection,
    String clientId,
  ) async {
    final uri = Uri.parse('$_base/api/collections/$collection/records').replace(
      queryParameters: {
        'filter': 'client_id="$clientId"',
        'perPage': '1',
      },
    );
    final data = await _getJson(uri);
    final items = (data['items'] as List).cast<Map<String, dynamic>>();
    return items.isEmpty ? null : items.first;
  }

  @override
  Future<Map<String, dynamic>> createRecord(
    String collection,
    Map<String, Object?> body,
  ) async {
    final uri = Uri.parse('$_base/api/collections/$collection/records');
    return await _postOrPatchJson(uri, body, isPatch: false);
  }

  @override
  Future<Map<String, dynamic>> updateRecord(
    String collection,
    String serverId,
    Map<String, Object?> body,
  ) async {
    final uri = Uri.parse('$_base/api/collections/$collection/records/$serverId');
    return await _postOrPatchJson(uri, body, isPatch: true);
  }

  /// Server-side records updated after [since]. `since == null` returns every
  /// record on the server (used on first sync).
  @override
  Future<List<Map<String, dynamic>>> listUpdatedSince(
    String collection,
    DateTime? since,
  ) async {
    final all = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final params = <String, String>{
        'perPage': '200',
        'page': '$page',
        'sort': 'updated_at',
      };
      if (since != null) {
        params['filter'] = 'updated_at>"${since.toIso8601String()}"';
      }
      final uri = Uri.parse('$_base/api/collections/$collection/records')
          .replace(queryParameters: params);
      final data = await _getJson(uri);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      all.addAll(items);
      final totalPages = (data['totalPages'] as num).toInt();
      if (page >= totalPages || items.isEmpty) break;
      page++;
    }
    return all;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Low-level HTTP helpers
  // ──────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    return await _withAuthRetry((token) async {
      final http.Response resp;
      try {
        resp = await http.get(uri, headers: _authHeaders(token)).timeout(_timeout);
      } on TimeoutException {
        throw NasSyncException('Timeout — NAS hat nicht geantwortet.');
      } on SocketException catch (e) {
        throw NasSyncException('Netzwerkfehler: ${e.message}');
      }
      if (resp.statusCode == 401) return null; // signal retry
      if (resp.statusCode != 200) {
        throw NasSyncException('GET ${uri.path} → ${resp.statusCode}: ${resp.body}');
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    });
  }

  Future<Map<String, dynamic>> _postOrPatchJson(
    Uri uri,
    Map<String, Object?> body, {
    required bool isPatch,
  }) async {
    return await _withAuthRetry((token) async {
      final headers = {
        ..._authHeaders(token),
        'Content-Type': 'application/json',
      };
      final encoded = jsonEncode(body);
      final http.Response resp;
      try {
        resp = await (isPatch
                ? http.patch(uri, headers: headers, body: encoded)
                : http.post(uri, headers: headers, body: encoded))
            .timeout(_timeout);
      } on TimeoutException {
        throw NasSyncException('Timeout — NAS hat nicht geantwortet.');
      } on SocketException catch (e) {
        throw NasSyncException('Netzwerkfehler: ${e.message}');
      }
      if (resp.statusCode == 401) return null;
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        throw NasSyncException(
          '${isPatch ? "PATCH" : "POST"} ${uri.path} → ${resp.statusCode}: ${resp.body}',
        );
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    });
  }

  /// Runs [op], passing it the current token. If [op] returns null (signaling
  /// 401), clears the token and retries once after a fresh login. This avoids
  /// every endpoint having to implement its own retry.
  Future<Map<String, dynamic>> _withAuthRetry(
    Future<Map<String, dynamic>?> Function(String token) op,
  ) async {
    var token = await _ensureToken();
    final result = await op(token);
    if (result != null) return result;
    await _settings.setToken(null);
    token = await login();
    final retry = await op(token);
    if (retry == null) {
      throw NasSyncException('Auth wiederholt fehlgeschlagen (401 nach Neu-Login).');
    }
    return retry;
  }

  Map<String, String> _authHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };
}
