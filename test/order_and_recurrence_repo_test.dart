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

    test('re-completing the same occurrence does not create another', () async {
      final id = await repo.create(
        title: 'Standup',
        dueAt: due,
        recurrence: Recurrence.daily,
      );
      await repo.setCompleted(id, true);
      await repo.setCompleted(id, false);
      await repo.setCompleted(id, true);
      expect(await db.select(db.tasks).get(), hasLength(2));
    });

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
    });
  });
}
