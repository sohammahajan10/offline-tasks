import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/backoff.dart';
import '../../domain/merge.dart';
import '../../domain/task.dart';
import '../api/remote_api.dart';
import '../db/database.dart';
import '../db/task_mapper.dart';

class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int conflicts = 0;
  int failed = 0;

  /// Why the run stopped early (e.g. offline), or null if it completed.
  String? error;

  /// True when sync was not attempted (signed out).
  bool skipped = false;

  @override
  String toString() => skipped
      ? 'skipped'
      : 'pushed $pushed, pulled $pulled, conflicts $conflicts, '
            'failed $failed${error == null ? '' : ', error: $error'}';
}

/// Pushes the outbox, then pulls server changes since the stored cursor.
///
/// Correctness rests on a few invariants:
/// * A queue entry is deleted only after the server acknowledged it.
/// * An entry keeps its op id across retries, so a retry after a lost ack is
///   recognised by the server and not applied twice.
/// * Every reconciliation with a server row (ack, conflict, pull) runs in one
///   transaction that updates the task, its snapshot and its waiting entries
///   together.
class SyncEngine {
  SyncEngine(
    this._db,
    this._api, {
    this.backoff = const Backoff(),
    DateTime Function()? clock,
    Random? random,
    String Function()? newId,
    this.pageSize = 500,
    this.cursorOverlap = const Duration(seconds: 5),
    this.maxConflictRetries = 3,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random(),
       _newId = newId ?? const Uuid().v4;

  final AppDatabase _db;
  final RemoteApi _api;
  final Backoff backoff;
  final DateTime Function() _clock;
  final Random _random;
  final String Function() _newId;
  final int pageSize;

  /// Each pull re-reads this much before the cursor. A transaction that
  /// commits late can carry an older `server_updated_at` than rows already
  /// pulled; re-reading is harmless because applying a row is idempotent.
  final Duration cursorOverlap;

  /// Guards against two devices editing the same task in a tight loop.
  final int maxConflictRetries;

  Future<SyncReport>? _running;

  /// Runs one sync. Concurrent calls share the run in progress.
  Future<SyncReport> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  /// Makes a failed entry eligible again, with a fresh set of attempts.
  Future<void> retry(int seq) => _resetFailed((q) => q.seq.equals(seq));

  Future<void> retryAllFailed() => _resetFailed((q) => const Constant(true));

  // --------------------------------------------------------------- run

  Future<SyncReport> _sync() async {
    final report = SyncReport();
    final userId = _api.userId;
    if (userId == null) return report..skipped = true;

    await _recoverInFlight();
    try {
      await _push(report);
      await _pull(userId, report);
    } on RemoteException catch (e) {
      report.error = e.message;
    }
    if (report.pushed + report.pulled + report.failed > 0 ||
        report.error != null) {
      await _log(
        report.error == null ? LogLevel.info : LogLevel.error,
        report.error == null
            ? 'Sync finished: $report'
            : 'Sync stopped: ${report.error} '
                  '(pushed ${report.pushed}, pulled ${report.pulled})',
      );
    }
    return report;
  }

  /// An `in_flight` entry at the start of a run was interrupted (app killed
  /// mid-push). Sending it again is safe: same op id, so the server either
  /// applies it or recognises it as already applied.
  Future<void> _recoverInFlight() async {
    final n =
        await (_db.update(_db.syncQueue)
              ..where((q) => q.status.equals(OpStatus.inFlight)))
            .write(const SyncQueueCompanion(status: Value(OpStatus.pending)));
    if (n > 0) {
      await _log(LogLevel.info, 'Recovered $n interrupted upload(s)');
    }
  }

  // -------------------------------------------------------------- push

  Future<void> _push(SyncReport report) async {
    final conflictRounds = <String, int>{};
    while (true) {
      final op = await _nextOp(conflictRounds);
      if (op == null) return;

      await (_db.update(_db.syncQueue)..where((q) => q.seq.equals(op.seq)))
          .write(const SyncQueueCompanion(status: Value(OpStatus.inFlight)));
      final payload = canonicalWire(
        Map<String, Object?>.from(jsonDecode(op.payloadJson) as Map),
      );

      final PushResult result;
      try {
        result = await _api.push(
          opId: op.opId,
          task: payload,
          baseVersion: op.baseVersion,
        );
      } on RemoteException catch (e) {
        await _recordFailure(op, payload, e, report);
        // Retryable usually means offline or server down: every other entry
        // would fail the same way, so stop instead of burning their attempts.
        if (e.retryable) rethrow;
        continue;
      } catch (e) {
        final error = RemoteException('Unexpected: $e', retryable: true);
        await _recordFailure(op, payload, error, report);
        throw error;
      }

      switch (result) {
        case PushApplied(:final serverRow):
          await _db.transaction(() async {
            await (_db.delete(
              _db.syncQueue,
            )..where((q) => q.seq.equals(op.seq))).go();
            await _reconcile(
              op.taskId,
              base: payload,
              remote: canonicalWire(serverRow),
              report: report,
            );
          });
          report.pushed++;
          await _log(
            LogLevel.info,
            'Uploaded “${payload[TaskFields.title]}” '
            '(${op.opType}, now v${serverRow['version']})',
            taskId: op.taskId,
          );
        case PushConflict(:final serverRow):
          conflictRounds.update(op.taskId, (n) => n + 1, ifAbsent: () => 1);
          await _log(
            LogLevel.info,
            '“${payload[TaskFields.title]}” changed on the server '
            '(v${op.baseVersion} → v${serverRow['version']}); merging',
            taskId: op.taskId,
          );
          await _db.transaction(() async {
            // Not a failure: back to pending without using up an attempt.
            await (_db.update(
              _db.syncQueue,
            )..where((q) => q.seq.equals(op.seq))).write(
              const SyncQueueCompanion(status: Value(OpStatus.pending)),
            );
            final row = await _task(op.taskId);
            await _reconcile(
              op.taskId,
              base: decodeSnapshot(row?.serverSnapshot),
              remote: canonicalWire(serverRow),
              report: report,
            );
          });
      }
    }
  }

  /// Oldest sendable entry by `seq`. Entries of a task are sent strictly in
  /// order: one waiting for its backoff, failed, or stuck in conflicts blocks
  /// the task's later entries, but not other tasks.
  Future<SyncOp?> _nextOp(Map<String, int> conflictRounds) async {
    final now = _clock();
    final ops =
        await (_db.select(_db.syncQueue)
              ..where((q) => q.status.equals(OpStatus.inFlight).not())
              ..orderBy([(q) => OrderingTerm.asc(q.seq)]))
            .get();
    final blocked = <String>{};
    for (final op in ops) {
      if (blocked.contains(op.taskId)) continue;
      final waiting = op.nextRetryAt != null && op.nextRetryAt!.isAfter(now);
      if (op.status == OpStatus.failed ||
          waiting ||
          (conflictRounds[op.taskId] ?? 0) >= maxConflictRetries) {
        blocked.add(op.taskId);
        continue;
      }
      return op;
    }
    return null;
  }

  Future<void> _recordFailure(
    SyncOp op,
    Map<String, Object?> payload,
    RemoteException e,
    SyncReport report,
  ) async {
    final attempts = op.attempts + 1;
    final giveUp = !e.retryable || backoff.exhausted(attempts);
    final delay = giveUp ? null : backoff.delayFor(attempts, _random);
    await (_db.update(_db.syncQueue)..where((q) => q.seq.equals(op.seq))).write(
      SyncQueueCompanion(
        status: Value(giveUp ? OpStatus.failed : OpStatus.pending),
        attempts: Value(attempts),
        nextRetryAt: Value(delay == null ? null : _clock().add(delay)),
        lastError: Value(e.message),
      ),
    );
    final title = payload[TaskFields.title];
    if (giveUp) {
      report.failed++;
      await _log(
        LogLevel.error,
        'Gave up on “$title” after $attempts attempt(s): ${e.message}',
        taskId: op.taskId,
      );
    } else {
      await _log(
        LogLevel.error,
        'Upload of “$title” failed (attempt $attempts/${backoff.maxAttempts}):'
        ' ${e.message}. Retrying in ${delay!.inSeconds}s',
        taskId: op.taskId,
      );
    }
  }

  // -------------------------------------------------------------- pull

  Future<void> _pull(String userId, SyncReport report) async {
    final cursorKey = 'pull_cursor:$userId';
    final stored = await _db.readState(cursorKey);
    var newest = stored == null ? null : DateTime.parse(stored);
    var since = newest?.subtract(cursorOverlap);

    while (true) {
      final rows = await _api.pullSince(since, limit: pageSize);
      for (final raw in rows) {
        final remote = canonicalWire(raw);
        final applied = await _db.transaction(() async {
          final row = await _task(remote['id'] as String);
          // Already have this version (our own echo, or the overlap window).
          if (row != null && row.version >= (remote['version'] as int)) {
            return false;
          }
          return _reconcile(
            remote['id'] as String,
            base: decodeSnapshot(row?.serverSnapshot),
            remote: remote,
            report: report,
          );
        });
        if (applied) report.pulled++;
        final at = DateTime.parse(remote['server_updated_at'] as String);
        if (newest == null || at.isAfter(newest)) newest = at;
      }
      // Saved per page, so an interrupted pull resumes instead of restarting.
      if (newest != null) {
        await _db.writeState(cursorKey, newest.toUtc().toIso8601String());
      }
      if (rows.length < pageSize) return;
      since = DateTime.parse(rows.last['server_updated_at'] as String);
    }
  }

  // --------------------------------------------------------- reconcile

  /// Brings the local task in line with [remote], the server's current row.
  /// Must run inside a transaction. Returns false if nothing was written.
  ///
  /// * No local row: insert it (unless it is a tombstone).
  /// * No waiting local changes: take the server state as is.
  /// * Waiting local changes: three-way merge against [base], write the
  ///   result locally and re-target the waiting entry at the new server
  ///   version so the next push applies cleanly.
  Future<bool> _reconcile(
    String taskId, {
    required Map<String, Object?>? base,
    required Map<String, Object?> remote,
    required SyncReport report,
  }) async {
    final row = await _task(taskId);
    final remoteVersion = remote['version'] as int;

    if (row == null) {
      if (remote[TaskFields.isDeleted] == true) return false;
      await _db
          .into(_db.tasks)
          .insert(
            wireToCompanion(remote).copyWith(
              id: Value(taskId),
              version: Value(remoteVersion),
              serverSnapshot: Value(encodeSnapshot(remote)),
              dirty: const Value(false),
            ),
          );
      return true;
    }

    final waiting =
        await (_db.select(_db.syncQueue)
              ..where(
                (q) =>
                    q.taskId.equals(taskId) &
                    q.status.equals(OpStatus.inFlight).not(),
              )
              ..orderBy([(q) => OrderingTerm.asc(q.seq)]))
            .get();

    if (waiting.isEmpty) {
      await _writeTask(taskId, remote, remote, remoteVersion, dirty: false);
      return true;
    }

    final local = canonicalWire(rowToWire(row));
    final result = mergeTask(base: base, local: local, remote: remote);
    final merged = result.merged;
    final title = merged[TaskFields.title];

    for (final c in result.conflicts) {
      report.conflicts++;
      await _log(LogLevel.conflict, 'Conflict on “$title”: $c', taskId: taskId);
    }

    final waitingSeqs = waiting.map((o) => o.seq).toList();
    if (sameFields(merged, remote)) {
      // The server already has everything: nothing left to send.
      await (_db.delete(
        _db.syncQueue,
      )..where((q) => q.seq.isIn(waitingSeqs))).go();
      await _writeTask(taskId, remote, remote, remoteVersion, dirty: false);
      if (!sameFields(local, remote)) {
        await _log(
          LogLevel.info,
          'Took server version of “$title”',
          taskId: taskId,
        );
      }
      return true;
    }

    await _writeTask(taskId, merged, remote, remoteVersion, dirty: true);
    final updated = (await _task(taskId))!;
    // One entry carries the merged state; any others (crash leftovers) go.
    final keep = waiting.first;
    await (_db.update(
      _db.syncQueue,
    )..where((q) => q.seq.equals(keep.seq))).write(
      SyncQueueCompanion(
        opId: Value(_newId()),
        opType: Value(opTypeFor(updated)),
        payloadJson: Value(jsonEncode(rowToWire(updated))),
        baseVersion: Value(remoteVersion),
      ),
    );
    await (_db.delete(_db.syncQueue)..where(
          (q) => q.taskId.equals(taskId) & q.seq.isIn(waitingSeqs.skip(1)),
        ))
        .go();
    if (!sameFields(merged, local)) {
      await _log(
        LogLevel.info,
        'Merged server changes into “$title”',
        taskId: taskId,
      );
    }
    return true;
  }

  Future<void> _writeTask(
    String taskId,
    Map<String, Object?> fields,
    Map<String, Object?> snapshot,
    int version, {
    required bool dirty,
  }) => (_db.update(_db.tasks)..where((t) => t.id.equals(taskId))).write(
    wireToCompanion(fields).copyWith(
      version: Value(version),
      serverSnapshot: Value(encodeSnapshot(snapshot)),
      dirty: Value(dirty),
    ),
  );

  // ----------------------------------------------------------- helpers

  Future<TaskRow?> _task(String id) =>
      (_db.select(_db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> _resetFailed(
    Expression<bool> Function($SyncQueueTable q) filter,
  ) async {
    final n =
        await (_db.update(
          _db.syncQueue,
        )..where((q) => q.status.equals(OpStatus.failed) & filter(q))).write(
          const SyncQueueCompanion(
            status: Value(OpStatus.pending),
            attempts: Value(0),
            nextRetryAt: Value(null),
            lastError: Value(null),
          ),
        );
    if (n > 0) await _log(LogLevel.info, 'Manual retry of $n upload(s)');
  }

  Future<void> _log(String level, String message, {String? taskId}) =>
      _db.log(level, message, taskId: taskId, at: _clock());
}
