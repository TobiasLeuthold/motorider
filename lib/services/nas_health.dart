import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

class NasPingResult {
  const NasPingResult.ok({required this.latency, required this.body})
      : ok = true,
        error = null;

  const NasPingResult.failure({required this.error})
      : ok = false,
        latency = null,
        body = null;

  final bool ok;
  final Duration? latency;
  final String? body;
  final String? error;
}

/// Hits PocketBase's `/api/health` endpoint. Returns a structured result —
/// no exceptions thrown, the UI can render the failure inline.
Future<NasPingResult> pingNas(String baseUrl) async {
  final uri = Uri.parse('$baseUrl/api/health');
  final stopwatch = Stopwatch()..start();
  try {
    final resp = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 5));
    stopwatch.stop();
    if (resp.statusCode != 200) {
      return NasPingResult.failure(
        error: 'HTTP ${resp.statusCode}: ${resp.reasonPhrase ?? ""}',
      );
    }
    // PocketBase health endpoint returns { "code": 200, "message": "API is healthy.", ... }
    String body = resp.body;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['message'] is String) {
        body = decoded['message'] as String;
      }
    } catch (_) {
      // Non-JSON response is fine — surface the raw body.
    }
    return NasPingResult.ok(latency: stopwatch.elapsed, body: body);
  } on TimeoutException {
    return const NasPingResult.failure(error: 'Timeout (NAS unreachable?)');
  } on SocketException catch (e) {
    return NasPingResult.failure(error: 'Network error: ${e.message}');
  } catch (e) {
    return NasPingResult.failure(error: '$e');
  }
}
