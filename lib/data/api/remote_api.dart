/// Result of pushing one queue entry.
sealed class PushResult {
  const PushResult(this.serverRow);

  /// The server's row after the call, as raw JSON.
  final Map<String, Object?> serverRow;
}

/// The server applied the change, or had already applied this op id.
class PushApplied extends PushResult {
  const PushApplied(super.serverRow);
}

/// The server row has moved past our base version; [serverRow] is its
/// current state. Nothing was written.
class PushConflict extends PushResult {
  const PushConflict(super.serverRow);
}

class RemoteException implements Exception {
  const RemoteException(this.message, {required this.retryable});

  final String message;

  /// Network errors, timeouts and 5xx are retryable. Validation and
  /// permission errors fail the same way every time, so they are not.
  final bool retryable;

  @override
  String toString() => message;
}

/// What the sync engine needs from a backend. `SupabaseRemoteApi` implements
/// it in phase 3; tests use `FakeRemoteApi`.
///
/// Server contract for [push] (implemented atomically on the server):
/// 1. No row with this id → insert it at version 1, tombstones included,
///    so a delete for an id the server never saw succeeds.
/// 2. The row's `last_op_id` equals [opId] → this op was already applied
///    (the ack was lost); return [PushApplied] with the current row.
/// 3. The row's version ≠ [baseVersion] → return [PushConflict].
/// 4. Otherwise update it, bump the version, store [opId] as `last_op_id`.
/// Every write sets `server_updated_at`, which [pullSince] filters on.
abstract interface class RemoteApi {
  Future<PushResult> push({
    required String opId,
    required Map<String, Object?> task,
    required int baseVersion,
  });

  /// Rows with `server_updated_at` after [since] (all rows if null), oldest
  /// first, at most [limit].
  Future<List<Map<String, Object?>>> pullSince(DateTime? since, {int limit});

  /// Account the data belongs to, or null when signed out (sync is skipped).
  String? get userId;
}
