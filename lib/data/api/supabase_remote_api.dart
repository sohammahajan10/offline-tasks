import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'remote_api.dart';

/// [RemoteApi] backed by Supabase: pushes go through the atomic
/// `apply_task_change` function, pulls read `tasks` (RLS limits them to the
/// signed-in user). See supabase/migrations for the server side.
class SupabaseRemoteApi implements RemoteApi {
  SupabaseRemoteApi(this._client, {this.timeout = const Duration(seconds: 15)});

  final SupabaseClient _client;
  final Duration timeout;

  /// SQLSTATE raised by apply_task_change for a stale base version.
  /// PostgREST maps `PTxyz` to HTTP status xyz, so this arrives as a 409.
  static const staleVersionCode = 'PT409';

  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  Future<PushResult> push({
    required String opId,
    required Map<String, Object?> task,
    required int baseVersion,
  }) => _guard(() async {
    try {
      final res = await _client
          .rpc(
            'apply_task_change',
            params: {
              'p_op_id': opId,
              'p_task': task,
              'p_base_version': baseVersion,
            },
          )
          .timeout(timeout);
      // 'applied' and 'duplicate' both mean the server has this op.
      final body = Map<String, Object?>.from(res as Map);
      return PushApplied(Map<String, Object?>.from(body['row'] as Map));
    } on PostgrestException catch (e) {
      if (e.code != staleVersionCode) rethrow;
      return PushConflict(await _rowFromStale(e, task['id'] as String));
    }
  });

  /// The server's current row, sent in the 409's `details`, so merging costs
  /// no extra request. If it is missing or unreadable, fetch the task.
  Future<Map<String, Object?>> _rowFromStale(
    PostgrestException e,
    String taskId,
  ) async {
    try {
      final details = e.details;
      final decoded = details is String ? jsonDecode(details) : details;
      if (decoded is Map && decoded['version'] != null) {
        return Map<String, Object?>.from(decoded);
      }
    } on FormatException {
      // fall through to a fetch
    }
    final rows = await _client
        .from('tasks')
        .select()
        .eq('id', taskId)
        .limit(1)
        .timeout(timeout);
    if (rows.isEmpty) {
      throw const RemoteException(
        'Stale version reported for a task that cannot be read',
        retryable: true,
      );
    }
    return Map<String, Object?>.from(rows.first);
  }

  @override
  Future<List<Map<String, Object?>>> pullSince(
    DateTime? since, {
    int limit = 500,
  }) => _guard(() async {
    var query = _client.from('tasks').select();
    if (since != null) {
      query = query.gt('server_updated_at', since.toUtc().toIso8601String());
    }
    final rows = await query
        .order('server_updated_at', ascending: true)
        .limit(limit)
        .timeout(timeout);
    return [for (final r in rows) Map<String, Object?>.from(r)];
  });

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PostgrestException catch (e) {
      throw RemoteException(
        'Server: ${e.message} (${e.code ?? 'no code'})',
        retryable: isRetryable(e.code),
      );
    } on AuthException catch (e) {
      // Usually an expired session that the client refreshes; if the user was
      // signed out instead, userId turns null and sync stops anyway.
      throw RemoteException('Auth: ${e.message}', retryable: true);
    } on SocketException catch (e) {
      throw RemoteException('Network: ${e.message}', retryable: true);
    } on HandshakeException catch (e) {
      throw RemoteException('Network: ${e.message}', retryable: true);
    } on ClientException catch (e) {
      throw RemoteException('Network: ${e.message}', retryable: true);
    } on TimeoutException {
      throw const RemoteException('Request timed out', retryable: true);
    }
  }

  /// Whether an error with this PostgREST/Postgres code can succeed later.
  ///
  /// Permanent (fail at once): invalid data (22xxx), constraint violations
  /// (23xxx), permission/RLS (42501) and other 42xxx such as a missing
  /// function, PL/pgSQL `raise` (P0001), malformed requests (PGRST1xx),
  /// schema cache errors (PGRST2xx), and HTTP 4xx other than 401/408/429.
  /// Everything else (JWT expiry PGRST3xx, serialization failures, timeouts,
  /// 5xx, unknown) is retried with backoff.
  static bool isRetryable(String? code) {
    if (code == null) return true;
    // A bare HTTP status (non-JSON error body) is 3 digits. SQLSTATEs are 5
    // characters and can be all digits too (23514), so check the length.
    final status = code.length == 3 ? int.tryParse(code) : null;
    if (status != null) {
      return status >= 500 || status == 401 || status == 408 || status == 429;
    }
    const permanentPrefixes = ['22', '23', '42', 'P0', 'PGRST1', 'PGRST2'];
    return !permanentPrefixes.any(code.startsWith);
  }
}
