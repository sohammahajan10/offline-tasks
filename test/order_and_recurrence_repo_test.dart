import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/domain/recurrence.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_query.dart';
import 'package:offline_tasks/domain/task_repository.dart';

void main() {
  late AppDatabase db;
  late TaskRepository repo;
  var now = DateTime.utc(2026, 10, 19, 9);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(
      db,
      clock: () => now = now.add(const Duration(seconds: 1)),
    );
  });

  tearDown(() => db.close());

  Future<List<String>> manualOrder() async =>
      (await repo.watchTasks(const TaskQuery(sort: TaskSort.manual)).first)
          .map((t) => t.title)
          .toList();

  Future<TaskRow> row(String id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingle();

  /// [write] is refused with [RecurrenceHistoryLocked] and leaves the tasks
  /// and the outbox exactly as they were.
  Future<void> expectUnchangedBy(Future<void> Function() write) async {
    final tasks = await db.select(db.tasks).get();
    final queue = await db.select(db.syncQueue).get();
    await expectLater(write(), throwsA(isA<RecurrenceHistoryLocked>()));
    expect(await db.select(db.tasks).get(), tasks);
    expect(
      await db.select(db.syncQueue).get(),
      queue,
      reason: 'no queue entry',
    );
  }

  group('manual order', () {
    test('new tasks go on top', () async {
      await repo.create(title: 'first');
      await repo.create(title: 'second');
      await repo.create(title: 'third');
      expect(await manualOrder(), ['third', 'second', 'first']);
    });

    test('a move rewrites only the moved task', () async {
      final c = await repo.create(title: 'C');
      final b = await repo.create(title: 'B');
      final a = await repo.create(title: 'A');
      // Pretend everything synced, so the queue shows exactly what a move adds.
      await db.delete(db.syncQueue).go();
      final keysBefore = {
        for (final id in [a, b, c]) id: (await row(id)).sortKey,
      };

      // Drag A between B and C.
      await repo.move(a, afterId: b, beforeId: c);

      expect(await manualOrder(), ['B', 'A', 'C']);
      final queue = await db.select(db.syncQueue).get();
      expect(queue.map((q) => q.taskId), [a], reason: 'one change to sync');
      expect(
        jsonDecode(queue.single.payloadJson)['sort_key'],
        (await row(a)).sortKey,
      );
      expect((await row(b)).sortKey, keysBefore[b]);
      expect((await row(c)).sortKey, keysBefore[c]);
    });

    test('moves to the very top and bottom', () async {
      final c = await repo.create(title: 'C');
      await repo.create(title: 'B');
      final a = await repo.create(title: 'A');
      await repo.move(a, afterId: c); // to the bottom
      expect(await manualOrder(), ['B', 'C', 'A']);
      await repo.move(
        c,
        beforeId:
            (await repo
                    .watchTasks(const TaskQuery(sort: TaskSort.manual))
                    .first)
                .first
                .id,
      );
      expect(await manualOrder(), ['C', 'B', 'A']);
    });

    test(
      'equal neighbour keys (concurrent inserts) still allow a move',
      () async {
        final x = await repo.create(title: 'X');
        final y = await repo.create(title: 'Y');
        final z = await repo.create(title: 'Z');
        await (db.update(db.tasks)..where((t) => t.id.isIn([x, y]))).write(
          const TasksCompanion(sortKey: Value('a5')),
        );
        await repo.move(z, afterId: x, beforeId: y);
        expect((await row(z)).sortKey.compareTo('a5'), greaterThan(0));
      },
    );
  });

  group('recurring tasks', () {
    final due = DateTime.utc(2026, 10, 20, 8);

    test('need a deadline', () async {
      expect(
        () => repo.create(title: 'Gym', recurrence: Recurrence.daily),
        throwsArgumentError,
      );
      final id = await repo.create(title: 'Gym');
      await expectLater(
        repo.update(id, const TaskPatch(recurrence: Recurrence.daily)),
        throwsArgumentError,
      );
      expect((await row(id)).recurrence, isNull, reason: 'rolled back');
    });

    test('completing one creates the next, with a deterministic id', () async {
      final id = await repo.create(
        title: 'Water plants',
        dueAt: due,
        recurrence: Recurrence.weekly,
        category: 'Home',
        tags: ['garden'],
      );
      await repo.setCompleted(id, true);

      final nextDue = DateTime.utc(2026, 10, 27, 8);
      final nextId = occurrenceId(id, nextDue);
      final next = await row(nextId);
      expect(next.title, 'Water plants');
      expect(next.dueAt!.toUtc(), nextDue);
      expect(next.completed, isFalse);
      expect(next.recurrence, 'weekly');
      expect(next.seriesId, id);
      expect(next.category, 'Home');
      expect(decodeTags(next.tags), ['garden']);
      expect(next.dirty, isTrue);

      final queued = (await db.select(db.syncQueue).get()).map((q) => q.taskId);
      expect(queued, containsAll([id, nextId]));
    });

    Future<List<String>> visible() async =>
        (await repo.watchAll().first).map((t) => t.id).toList();

    test('un-completing takes back the untouched next occurrence', () async {
      final id = await repo.create(
        title: 'Water plants',
        dueAt: due,
        recurrence: Recurrence.weekly,
      );
      await repo.setCompleted(id, true);
      final nextId = occurrenceId(id, DateTime.utc(2026, 10, 27, 8));
      expect(await visible(), unorderedEquals([id, nextId]));

      await repo.setCompleted(id, false);
      expect(await visible(), [id], reason: 'no second copy left behind');
      expect((await row(nextId)).isDeleted, isTrue, reason: 'a tombstone');
      final op = (await db.select(db.syncQueue).get()).singleWhere(
        (q) => q.taskId == nextId,
      );
      expect(op.opType, OpType.delete, reason: 'the withdrawal syncs');
    });

    test('completing again brings the same occurrence back', () async {
      final id = await repo.create(
        title: 'Standup',
        dueAt: due,
        recurrence: Recurrence.daily,
      );
      await repo.setCompleted(id, true);
      await repo.setCompleted(id, false);
      await repo.setCompleted(id, true);

      final nextId = occurrenceId(id, DateTime.utc(2026, 10, 21, 8));
      expect(
        await db.select(db.tasks).get(),
        hasLength(2),
        reason: 'no new id',
      );
      expect(await visible(), unorderedEquals([id, nextId]));
      final next = await row(nextId);
      expect(next.isDeleted, isFalse);
      expect(next.completed, isFalse);
    });

    for (final (what, touch) in <(String, Future<void> Function(String))>[
      ('renamed', (n) => repo.update(n, const TaskPatch(title: 'Mine now'))),
      (
        're-prioritised',
        (n) => repo.update(n, const TaskPatch(priority: Priority.high)),
      ),
      (
        'moved',
        (n) async {
          final other = await repo.create(title: 'Other');
          await repo.move(n, beforeId: other); // above it: a new key
        },
      ),
      ('completed', (n) => repo.setCompleted(n, true)),
    ]) {
      // B is no longer exactly as generated, so it isn't withdrawn; reopening
      // A would leave two open occurrences (B, or C once B was completed).
      test('a next occurrence that was $what blocks un-completing', () async {
        final id = await repo.create(
          title: 'Water plants',
          dueAt: due,
          recurrence: Recurrence.weekly,
        );
        await repo.setCompleted(id, true);
        final nextId = occurrenceId(id, DateTime.utc(2026, 10, 27, 8));
        await touch(nextId);
        await expectUnchangedBy(() => repo.setCompleted(id, false));
        expect((await row(id)).completed, isTrue);
        expect((await row(nextId)).isDeleted, isFalse);
      });
    }

    group('a series has at most one open occurrence', () {
      // A (due 20 Oct) → B (27 Oct) → C (3 Nov).
      late String a, b, c;
      setUp(() async {
        a = await repo.create(
          title: 'Water plants',
          dueAt: due,
          recurrence: Recurrence.weekly,
        );
        await repo.setCompleted(a, true);
        b = occurrenceId(a, DateTime.utc(2026, 10, 27, 8));
        await repo.setCompleted(b, true);
        c = occurrenceId(a, DateTime.utc(2026, 11, 3, 8));
      });

      Future<List<String>> open() async => (await repo.watchAll().first)
          .where((t) => !t.completed)
          .map((t) => t.id)
          .toList();

      test('un-completing an old occurrence is refused', () async {
        await expectUnchangedBy(() => repo.setCompleted(a, false));
        expect(await open(), [c]);
      });

      test('the editor gets the same refusal', () async {
        await expectUnchangedBy(
          () => repo.update(a, const TaskPatch(completed: false, notes: 'x')),
        );
        expect((await row(a)).notes, '', reason: 'nothing else saved either');
      });

      test(
        'un-completing the latest completed one withdraws the next',
        () async {
          await repo.setCompleted(b, false);
          expect(await open(), [b], reason: 'exactly one open occurrence');
          expect((await row(c)).isDeleted, isTrue);
          expect((await row(a)).completed, isTrue);
        },
      );
    });

    test(
      'changing other fields of a completed task leaves the next one',
      () async {
        final id = await repo.create(
          title: 'Water plants',
          dueAt: due,
          recurrence: Recurrence.weekly,
        );
        await repo.setCompleted(id, true);
        await repo.update(id, const TaskPatch(notes: 'used the blue can'));
        final nextId = occurrenceId(id, DateTime.utc(2026, 10, 27, 8));
        expect((await row(nextId)).isDeleted, isFalse);
      },
    );

    test('the chain continues from each occurrence', () async {
      final first = await repo.create(
        title: 'Rent',
        dueAt: DateTime.utc(2026, 1, 31, 9),
        recurrence: Recurrence.monthly,
      );
      await repo.setCompleted(first, true);
      final feb = occurrenceId(first, DateTime.utc(2026, 2, 28, 9));
      await repo.setCompleted(feb, true);
      final mar = await row(occurrenceId(first, DateTime.utc(2026, 3, 28, 9)));
      expect(mar.seriesId, first);
    });

    test('a one-off task completes without creating anything', () async {
      final id = await repo.create(title: 'Once', dueAt: due);
      await repo.setCompleted(id, true);
      expect(await db.select(db.tasks).get(), hasLength(1));
      await repo.setCompleted(id, false);
      expect((await row(id)).completed, isFalse, reason: 'never refused');
    });
  });
}
