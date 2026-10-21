import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/db/database.dart';
import '../data/db/task_mapper.dart';
import 'fractional_index.dart';
import 'recurrence.dart';
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
      // Equal keys (two devices inserting at the same spot offline) are
      // ordered by id, so every device shows the same order.
      TaskSort.manual => [
        (t) => OrderingTerm.asc(t.sortKey),
        (t) => OrderingTerm.asc(t.id),
      ],
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

  /// Creates a task with a client-generated UUID and returns its id. New
  /// tasks go to the top of the manual order.
  Future<String> create({
    required String title,
    String notes = '',
    Priority priority = Priority.medium,
    DateTime? dueAt,
    String? category,
    List<String> tags = const [],
    Recurrence? recurrence,
  }) {
    if (recurrence != null && dueAt == null) {
      throw ArgumentError('A repeating task needs a deadline');
    }
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
                  sortKey: Value(await _keyAtTop()),
                  recurrence: Value(recurrence?.name),
                  seriesId: Value(recurrence == null ? null : id),
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
      recurrence: patch.clearRecurrence
          ? const Value(null)
          : Value.absentIfNull(patch.recurrence?.name),
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

  /// Drag-to-reorder: puts [id] between the tasks now shown above ([afterId])
  /// and below ([beforeId]) it. Only the moved task gets a new key, so only
  /// it syncs, and concurrent moves on two devices conflict only if they
  /// moved the same task (then the later move wins, like any field).
  Future<void> move(String id, {String? afterId, String? beforeId}) => _db
      .transaction(() async {
        final above = afterId == null ? null : (await _row(afterId))?.sortKey;
        var below = beforeId == null ? null : (await _row(beforeId))?.sortKey;
        // Neighbours with equal keys (two devices inserted at the same spot
        // offline; shown in id order) have no room between them: place the
        // task just after the upper one instead.
        if (above != null && below != null && above.compareTo(below) >= 0) {
          below = null;
        }
        final key = FractionalIndex.keyBetween(
          _validKeyOrNull(above),
          _validKeyOrNull(below),
        );
        await _apply(id, TasksCompanion(sortKey: Value(key)));
      })
      .then((_) => _writes.add(null));

  // ------------------------------------------------------------ internals

  Future<void> _write(String id, TasksCompanion changes) =>
      _db.transaction(() => _apply(id, changes)).then((_) => _writes.add(null));

  /// Writes [changes] and enqueues them. Must run inside a transaction.
  Future<void> _apply(String id, TasksCompanion changes) async {
    final before = await _row(id);
    if (before == null) throw StateError('Task $id not found');
    await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
      changes.copyWith(updatedAt: Value(_clock()), dirty: const Value(true)),
    );
    var after = (await _row(id))!;
    if (after.recurrence != null) {
      if (after.dueAt == null) {
        throw ArgumentError('A repeating task needs a deadline');
      }
      if (after.seriesId == null) {
        await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
          TasksCompanion(seriesId: Value(id)),
        );
        after = (await _row(id))!;
      }
    }
    await _enqueue(id);
    if (!before.completed && after.completed && after.recurrence != null) {
      await _createNextOccurrence(after);
    }
    if (before.completed && !after.completed && before.recurrence != null) {
      await _withdrawNextOccurrence(before);
    }
  }

  /// The next occurrence exactly as completing [done] creates it.
  ({String id, TasksCompanion fields}) _nextOccurrence(TaskRow done) {
    final rule = Recurrence.parse(done.recurrence)!;
    final seriesId = done.seriesId ?? done.id;
    final nextDue = rule.next(done.dueAt!);
    return (
      id: occurrenceId(seriesId, nextDue),
      fields: TasksCompanion(
        title: Value(done.title),
        notes: Value(done.notes),
        priority: Value(done.priority),
        dueAt: Value(nextDue),
        category: Value(done.category),
        tags: Value(done.tags),
        sortKey: Value(done.sortKey),
        recurrence: Value(done.recurrence),
        seriesId: Value(seriesId),
        completed: const Value(false),
        isDeleted: const Value(false),
      ),
    );
  }

  /// Completing a repeating task creates the next one, in the same
  /// transaction. Its id is derived from the series and the next due time
  /// (see [occurrenceId]), so two devices completing the same occurrence
  /// offline create the same task, which sync then merges into one.
  Future<void> _createNextOccurrence(TaskRow done) async {
    final next = _nextOccurrence(done);
    final existing = await _row(next.id);
    // Already here (pulled from another device that got there first): keep it.
    if (existing != null && !existing.isDeleted) return;
    final fields = next.fields.copyWith(
      updatedAt: Value(_clock()),
      dirty: const Value(true),
    );
    if (existing == null) {
      await _db.into(_db.tasks).insert(fields.copyWith(id: Value(next.id)));
    } else {
      // Withdrawn by an earlier un-complete: completing again brings it back.
      await (_db.update(
        _db.tasks,
      )..where((t) => t.id.equals(next.id))).write(fields);
    }
    await _enqueue(next.id);
  }

  /// Un-completing a repeating task takes back the occurrence that completing
  /// it created, so the list doesn't show two copies. Only if that occurrence
  /// is still exactly as generated: once it was edited, moved or completed
  /// (here, or on another device and pulled), it is the user's and stays.
  ///
  /// Works offline and on another device that already pulled the occurrence:
  /// the id is recomputed from the series and due date, and the check is on
  /// content, not on which device created it. The tombstone syncs like any
  /// delete.
  Future<void> _withdrawNextOccurrence(TaskRow done) async {
    if (done.dueAt == null) return;
    final next = _nextOccurrence(done);
    final existing = await _row(next.id);
    if (existing == null || !_isUntouched(existing, next.fields)) return;
    await _apply(next.id, const TasksCompanion(isDeleted: Value(true)));
  }

  static bool _isUntouched(TaskRow row, TasksCompanion generated) =>
      row.title == generated.title.value &&
      row.notes == generated.notes.value &&
      row.priority == generated.priority.value &&
      row.dueAt != null &&
      row.dueAt!.isAtSameMomentAs(generated.dueAt.value!) &&
      row.category == generated.category.value &&
      const ListEquality<String>().equals(
        decodeTags(row.tags),
        decodeTags(generated.tags.value),
      ) &&
      row.sortKey == generated.sortKey.value &&
      row.recurrence == generated.recurrence.value &&
      row.seriesId == generated.seriesId.value &&
      !row.completed &&
      !row.isDeleted;

  Future<TaskRow?> _row(String id) =>
      (_db.select(_db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// A key above every task's, so new tasks appear first in manual order.
  Future<String> _keyAtTop() async {
    final min = _db.tasks.sortKey.min();
    final row =
        await (_db.selectOnly(_db.tasks)
              ..addColumns([min])
              ..where(_db.tasks.sortKey.equals('').not()))
            .getSingle();
    return FractionalIndex.keyBetween(null, _validKeyOrNull(row.read(min)));
  }

  /// Treats an empty or malformed key (legacy data) as "no bound".
  static String? _validKeyOrNull(String? key) {
    if (key == null || key.isEmpty) return null;
    try {
      FractionalIndex.keyBetween(key, null);
      return key;
    } on ArgumentError {
      return null;
    }
  }

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
