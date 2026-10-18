import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/db/database.dart';
import '../data/db/task_mapper.dart';
import 'task.dart';

/// All task writes go through here. Each one updates `tasks` and `sync_queue`
/// in a single SQLite transaction, so a change can never exist without the
/// outbox entry that will sync it (and vice versa), even if the app is killed.
class TaskRepository {
  TaskRepository(
    this._db, {
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  final AppDatabase _db;
  final DateTime Function() _clock;
  final String Function() _newId;

  // ---------------------------------------------------------------- reads

  Stream<List<TaskItem>> watchAll() {
    final q = _db.select(_db.tasks)
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.asc(t.completed),
        (t) => OrderingTerm(
          expression: t.dueAt,
          mode: OrderingMode.asc,
          nulls: NullsOrder.last,
        ),
        (t) => OrderingTerm.desc(t.updatedAt),
      ]);
    return q.map(rowToItem).watch();
  }

  Stream<TaskItem?> watchById(String id) => (_db.select(
    _db.tasks,
  )..where((t) => t.id.equals(id))).map(rowToItem).watchSingleOrNull();

  Future<TaskItem?> getById(String id) => (_db.select(
    _db.tasks,
  )..where((t) => t.id.equals(id))).map(rowToItem).getSingleOrNull();

  /// Number of tasks with changes not yet acknowledged by the server.
  Stream<int> watchPendingCount() {
    // Distinct tasks: one task can have an in-flight entry and a waiting one.
    final count = _db.syncQueue.taskId.count(distinct: true);
    return (_db.selectOnly(
      _db.syncQueue,
    )..addColumns([count])).map((r) => r.read(count)!).watchSingle();
  }

  // --------------------------------------------------------------- writes

  /// Creates a task with a client-generated UUID and returns its id.
  Future<String> create({
    required String title,
    String notes = '',
    Priority priority = Priority.medium,
    DateTime? dueAt,
    String? category,
    List<String> tags = const [],
  }) {
    final id = _newId();
    return _db.transaction(() async {
      await _db
          .into(_db.tasks)
          .insert(
            TasksCompanion.insert(
              id: id,
              title: _validTitle(title),
              notes: Value(notes.trim()),
              priority: Value(priority.index),
              dueAt: Value(dueAt),
              category: Value(_blankToNull(category)),
              tags: Value(encodeTags(_cleanTags(tags))),
              updatedAt: _clock(),
              dirty: const Value(true),
            ),
          );
      await _enqueue(id);
      return id;
    });
  }

  Future<void> update(String id, TaskPatch patch) => _write(
    id,
    TasksCompanion(
      title: patch.title == null
          ? const Value.absent()
          : Value(_validTitle(patch.title!)),
      notes: Value.absentIfNull(patch.notes?.trim()),
      priority: Value.absentIfNull(patch.priority?.index),
      dueAt: patch.clearDueAt
          ? const Value(null)
          : Value.absentIfNull(patch.dueAt),
      category: patch.clearCategory
          ? const Value(null)
          : (patch.category == null
                ? const Value.absent()
                : Value(_blankToNull(patch.category))),
      tags: patch.tags == null
          ? const Value.absent()
          : Value(encodeTags(_cleanTags(patch.tags!))),
      completed: Value.absentIfNull(patch.completed),
    ),
  );

  Future<void> setCompleted(String id, bool completed) =>
      _write(id, TasksCompanion(completed: Value(completed)));

  /// Soft delete: sets the tombstone so the delete can sync to the server and
  /// other devices. A hard delete made offline would never reach them.
  Future<void> delete(String id) =>
      _write(id, const TasksCompanion(isDeleted: Value(true)));

  /// Undo for [delete].
  Future<void> restore(String id) =>
      _write(id, const TasksCompanion(isDeleted: Value(false)));

  // ------------------------------------------------------------ internals

  Future<void> _write(String id, TasksCompanion changes) =>
      _db.transaction(() async {
        final updated =
            await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
              changes.copyWith(
                updatedAt: Value(_clock()),
                dirty: const Value(true),
              ),
            );
        if (updated == 0) throw StateError('Task $id not found');
        await _enqueue(id);
      });

  /// Adds or refreshes the task's outbox entry. Must run inside a transaction.
  ///
  /// Offline edits are merged into the task's waiting entry, so ten edits cost
  /// one request. The payload is always the full current row, so whichever
  /// entry is sent carries the latest state.
  ///
  /// * Only `pending` and `failed` entries are merged into. An `in_flight`
  ///   entry is being pushed: merging would lose this edit when its ack
  ///   deletes the entry, so the edit gets a new entry behind it instead.
  ///   (`failed` entries are merged too: the newer entry carries the full
  ///   state, so a separate stale failed entry could later be retried and
  ///   overwrite it.)
  /// * A merge keeps `base_version`: the server version the user's edits
  ///   started from. Only the sync engine moves it, when the server version
  ///   advances (our own ack, or a pull that was merged in).
  /// * A merge assigns a fresh op id. If the old op was sent and the server
  ///   applied it but the ack was lost, reusing its id would make the server
  ///   treat the new payload as a duplicate and drop it.
  /// * A merge keeps `seq`, so the task keeps its place in the queue.
  Future<void> _enqueue(String taskId) async {
    final row = await (_db.select(
      _db.tasks,
    )..where((t) => t.id.equals(taskId))).getSingle();
    final opType = opTypeFor(row);
    final payload = jsonEncode(rowToWire(row));
    final waiting =
        await (_db.select(_db.syncQueue)..where(
              (q) =>
                  q.taskId.equals(taskId) &
                  q.status.isIn([OpStatus.pending, OpStatus.failed]),
            ))
            .getSingleOrNull();

    if (waiting == null) {
      await _db
          .into(_db.syncQueue)
          .insert(
            SyncQueueCompanion.insert(
              opId: _newId(),
              taskId: taskId,
              opType: opType,
              payloadJson: payload,
              baseVersion: row.version,
            ),
          );
      return;
    }

    await (_db.update(
      _db.syncQueue,
    )..where((q) => q.seq.equals(waiting.seq))).write(
      SyncQueueCompanion(
        opId: Value(_newId()),
        opType: Value(opType),
        payloadJson: Value(payload),
        // A new edit gets a fresh set of attempts, even if the op had failed.
        status: const Value(OpStatus.pending),
        attempts: const Value(0),
        nextRetryAt: const Value(null),
        lastError: const Value(null),
      ),
    );
  }

  /// The op type follows from the row's state, so coalesced edits can't
  /// lose it: a tombstone is a delete, a task the server has never seen is
  /// a create, anything else is an update.
  static String opTypeFor(TaskRow row) => row.isDeleted
      ? OpType.delete
      : (row.version == 0 ? OpType.create : OpType.update);

  static String _validTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) {
      throw ArgumentError.value(title, 'title', 'must not be empty');
    }
    return t;
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  static List<String> _cleanTags(List<String> tags) => {
    for (final t in tags)
      if (t.trim().isNotEmpty) t.trim().toLowerCase(),
  }.toList();
}
