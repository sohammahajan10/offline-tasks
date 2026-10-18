import 'package:drift/drift.dart';

import '../data/db/database.dart';

/// A queued change as shown on the Sync log screen.
class QueuedChange {
  const QueuedChange({
    required this.seq,
    required this.taskId,
    required this.title,
    required this.opType,
    required this.status,
    required this.attempts,
    this.nextRetryAt,
    this.lastError,
  });

  final int seq;
  final String taskId;
  final String title;
  final String opType;
  final String status;
  final int attempts;
  final DateTime? nextRetryAt;
  final String? lastError;

  bool get failed => status == OpStatus.failed;
}

/// Read side of the outbox and the sync history, for the UI.
class SyncLogRepository {
  SyncLogRepository(this._db);

  final AppDatabase _db;

  Stream<List<SyncLogEntry>> watchLog({int limit = 300}) =>
      (_db.select(_db.syncLog)
            ..orderBy([(l) => OrderingTerm.desc(l.id)])
            ..limit(limit))
          .watch();

  Stream<List<QueuedChange>> watchQueue() {
    final q = _db.select(_db.syncQueue).join([
      innerJoin(_db.tasks, _db.tasks.id.equalsExp(_db.syncQueue.taskId)),
    ])..orderBy([OrderingTerm.asc(_db.syncQueue.seq)]);
    return q.watch().map(
      (rows) => [
        for (final r in rows)
          _toChange(r.readTable(_db.syncQueue), r.readTable(_db.tasks)),
      ],
    );
  }

  Stream<int> watchFailedCount() {
    final count = _db.syncQueue.seq.count();
    return (_db.selectOnly(_db.syncQueue)
          ..addColumns([count])
          ..where(_db.syncQueue.status.equals(OpStatus.failed)))
        .map((r) => r.read(count)!)
        .watchSingle();
  }

  /// When the earliest entry waiting out its backoff becomes due, if any.
  Future<DateTime?> nextRetryAt() async {
    final min = _db.syncQueue.nextRetryAt.min();
    final row =
        await (_db.selectOnly(_db.syncQueue)
              ..addColumns([min])
              ..where(_db.syncQueue.status.equals(OpStatus.pending)))
            .getSingle();
    return row.read(min);
  }

  Future<void> clearLog() => _db.delete(_db.syncLog).go();

  static QueuedChange _toChange(SyncOp op, TaskRow task) => QueuedChange(
    seq: op.seq,
    taskId: op.taskId,
    title: task.title,
    opType: op.opType,
    status: op.status,
    attempts: op.attempts,
    nextRetryAt: op.nextRetryAt,
    lastError: op.lastError,
  );
}
