import 'dart:async';

import 'package:offline_tasks/data/api/remote_api.dart';

typedef PushCall = ({String opId, int baseVersion, Map<String, Object?> task});

/// In-memory server implementing the [RemoteApi] contract, with knobs to
/// simulate network failures, lost acks and edits from other devices.
class FakeRemoteApi implements RemoteApi {
  FakeRemoteApi({this.userId = 'user-1'});

  @override
  String? userId;

  /// Server rows by id. Shared by every device's engine in a test.
  final rows = <String, Map<String, Object?>>{};

  final pushCalls = <PushCall>[];
  final pullCalls = <DateTime?>[];

  /// Every push and pull throws a retryable network error.
  bool offline = false;

  /// Thrown (one per call) by the next pushes, before anything is applied.
  final failures = <RemoteException>[];

  /// The next push is applied, then the response is lost (timeout).
  bool loseNextAck = false;

  /// Runs while a push is "on the wire", after the client marked it in flight.
  Future<void> Function(PushCall call)? onPush;

  var _clock = DateTime.utc(2026, 1, 1);

  DateTime _tick() => _clock = _clock.add(const Duration(seconds: 1));

  @override
  Future<PushResult> push({
    required String opId,
    required Map<String, Object?> task,
    required int baseVersion,
  }) async {
    final call = (opId: opId, baseVersion: baseVersion, task: task);
    pushCalls.add(call);
    if (offline) throw const RemoteException('offline', retryable: true);
    if (failures.isNotEmpty) throw failures.removeAt(0);
    await onPush?.call(call);

    final result = _apply(opId, task, baseVersion);
    if (loseNextAck) {
      loseNextAck = false;
      throw const RemoteException('Request timed out', retryable: true);
    }
    return result;
  }

  PushResult _apply(String opId, Map<String, Object?> task, int baseVersion) {
    final id = task['id'] as String;
    final current = rows[id];
    if (current == null) {
      // Unknown id, tombstones included: insert at version 1.
      return PushApplied(rows[id] = _row(task, 1, opId));
    }
    if (current['last_op_id'] == opId) return PushApplied({...current});
    if (current['version'] != baseVersion) return PushConflict({...current});
    return PushApplied(
      rows[id] = _row(task, (current['version'] as int) + 1, opId),
    );
  }

  Map<String, Object?> _row(
    Map<String, Object?> t,
    int version,
    String? op,
  ) => {
    for (final e in t.entries)
      if (e.key != 'version' && e.key != 'server_updated_at') e.key: e.value,
    'version': version,
    'server_updated_at': _tick().toIso8601String(),
    'last_op_id': op,
  };

  /// Another device (or the dashboard) changes a row directly.
  void serverEdit(String id, Map<String, Object?> changes, {DateTime? at}) {
    final current = rows[id]!;
    rows[id] = _row(
      {
        ...current,
        ...changes,
        'updated_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      },
      (current['version'] as int) + 1,
      null,
    );
  }

  @override
  Future<List<Map<String, Object?>>> pullSince(
    DateTime? since, {
    int limit = 500,
  }) async {
    pullCalls.add(since);
    if (offline) throw const RemoteException('offline', retryable: true);
    final sorted =
        rows.values
            .where(
              (r) =>
                  since == null ||
                  DateTime.parse(r['server_updated_at'] as String)
                      .isAfter(since),
            )
            .toList()
          ..sort(
            (a, b) => (a['server_updated_at'] as String).compareTo(
              b['server_updated_at'] as String,
            ),
          );
    return sorted.take(limit).map((r) => {...r}).toList();
  }
}
