import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/db/database.dart';
import '../data/db/task_mapper.dart';
import 'task.dart';
import 'task_query.dart';

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
  final _writes = StreamController<void>.broadcast();

  /// Fires after every committed local write, so sync can start promptly.
  Stream<void> get localWrites => _writes.stream;

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

  /// Visible (non-deleted) tasks matching [query], in its sort order.
  Stream<List<TaskItem>> watchTasks(TaskQuery query) {
    final q = _db.select(_db.tasks)..where((t) => t.isDeleted.equals(false));

    final search = query.search.trim();
    if (search.isNotEmpty) {
      // LIKE is case-insensitive for ASCII in SQLite. % and _ in the user's
      // text are escaped so they match literally.
      final pattern =
          '%${search.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
      q.where(
        (t) =>
            t.title.like(pattern, escapeChar: r'\') |
            t.notes.like(pattern, escapeChar: r'\') |
            t.category.like(pattern, escapeChar: r'\') |
            t.tags.like(pattern, escapeChar: r'\'),
      );
    }
    switch (query.status) {
      case StatusFilter.all:
        break;
      case StatusFilter.pending:
        q.where((t) => t.completed.equals(false));
      case StatusFilter.done:
        q.where((t) => t.completed.equals(true));
    }
    if (query.priority case final p?) {
      q.where((t) => t.priority.equals(p.index));
    }
    if (query.category case final c?) {
      q.where((t) => t.category.equals(c));
    }

    OrderingTerm due($TasksTable t) => OrderingTerm(
      expression: t.dueAt,
      mode: OrderingMode.asc,
      nulls: NullsOrder.last,
    );
    q.orderBy(switch (query.sort) {
      TaskSort.smart => [
        (t) => OrderingTerm.asc(t.completed),
        due,
        (t) => OrderingTerm.desc(t.priority),
        (t) => OrderingTerm.desc(t.updatedAt),
      ],
      TaskSort.dueDate => [due, (t) => OrderingTerm.desc(t.priority)],
      TaskSort.priority => [(t) => OrderingTerm.desc(t.priority), due],
      TaskSort.recent => [(t) => OrderingTerm.desc(t.updatedAt)],
    });
    return q.map(rowToItem).watch();
  }

  /// Distinct categories in use, for filters and autocomplete.
  Stream<List<String>> watchCategories() {
    final q = _db.selectOnly(_db.tasks, distinct: true)
      ..addColumns([_db.tasks.category])
      ..where(
        _db.tasks.isDeleted.equals(false) & _db.tasks.category.isNotNull(),
      )
      ..orderBy([OrderingTerm.asc(_db.tasks.category)]);
    return q.map((r) => r.read(_db.tasks.category)!).watch();
  }

  /// Sync badge per task that has queued changes. Failed wins over pending.
  Stream<Map<String, TaskSyncState>> watchSyncStates() =>
      _db.select(_db.syncQueue).watch().map((ops) {
        final states = <String, TaskSyncState>{};
        for (final op in ops) {
          if (op.status == OpStatus.failed) {
            states[op.taskId] = TaskSyncState.failed;
          } else {
            states.putIfAbsent(op.taskId, () => TaskSyncState.pending);
          }
        }
        return states;
      });

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
    return _db
        .transaction(() async {
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
        })
        .then((id) {
          _writes.add(null);
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

  Future<void> _write(String id, TasksCompanion changes) => _db
      .transaction(() async {
        final updated =
            await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
              changes.copyWith(
                updatedAt: Value(_clock()),
                dirty: const Value(true),
              ),
            );
        if (updated == 0) throw StateError('Task $id not found');
        await _enqueue(id);
      })
      .then((_) => _writes.add(null));

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
        await (_db.select(_db.syncQueue)
              ..where(
                (q) =>
                    q.taskId.equals(taskId) &
                    q.status.isIn([OpStatus.pending, OpStatus.failed]),
              )
              // Normally at most one. After a crash, a recovered in-flight entry
              // can sit in front of a newer one: merge into the newest.
              ..orderBy([(q) => OrderingTerm.desc(q.seq)])
              ..limit(1))
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
