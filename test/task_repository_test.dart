import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_repository.dart';

void main() {
  late AppDatabase db;
  late TaskRepository repo;
  var now = DateTime.utc(2026, 10, 18, 9);

  TaskRepository makeRepo(AppDatabase db) => TaskRepository(
    db,
    clock: () {
      now = now.add(const Duration(seconds: 1));
      return now;
    },
  );

  Future<List<SyncOp>> queue() => (db.select(
    db.syncQueue,
  )..orderBy([(q) => OrderingTerm.asc(q.enqueuedAt)])).get();

  Future<TaskRow> row(String id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingle();

  // The reopen test deliberately has two databases open at once.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = makeRepo(db);
  });

  tearDown(() => db.close());

  group('every write produces a queue entry', () {
    test('create writes the task and a create op in the same state', () async {
      final id = await repo.create(
        title: '  Buy milk ',
        priority: Priority.high,
        category: 'Home',
        tags: ['Errand', 'errand', ' '],
      );

      final task = await row(id);
      expect(task.title, 'Buy milk');
      expect(task.dirty, isTrue);
      expect(task.version, 0);
      expect(task.tags, '["errand"]');

      final ops = await queue();
      expect(ops, hasLength(1));
      expect(ops.single.taskId, id);
      expect(ops.single.opType, OpType.create);
      expect(ops.single.status, OpStatus.pending);
      expect(ops.single.baseVersion, 0);
      final payload = jsonDecode(ops.single.payloadJson) as Map;
      expect(payload['id'], id);
      expect(payload['title'], 'Buy milk');
      expect(payload['priority'], Priority.high.index);
      expect(payload['is_deleted'], isFalse);
    });

    test(
      'update, complete, delete and restore each enqueue the latest state',
      () async {
        final id = await repo.create(title: 'Draft');
        final writes = <String, Future<void> Function()>{
          'update': () => repo.update(id, const TaskPatch(title: 'Final')),
          'complete': () => repo.setCompleted(id, true),
          'delete': () => repo.delete(id),
          'restore': () => repo.restore(id),
        };

        var previousOpId = (await queue()).single.opId;
        for (final MapEntry(key: name, value: write) in writes.entries) {
          await write();
          final ops = await queue();
          expect(ops, hasLength(1), reason: '$name coalesces into one op');
          final op = ops.single;
          expect(
            op.opId,
            isNot(previousOpId),
            reason: '$name gets a fresh op id',
          );
          previousOpId = op.opId;

          final payload = jsonDecode(op.payloadJson) as Map;
          final current = await row(id);
          expect(payload['title'], current.title, reason: name);
          expect(payload['completed'], current.completed, reason: name);
          expect(payload['is_deleted'], current.isDeleted, reason: name);
          expect(current.dirty, isTrue, reason: name);
        }
        // Never seen by the server, so it is still a create.
        expect((await queue()).single.opType, OpType.create);
      },
    );

    test('delete is a soft delete and hides the task', () async {
      final id = await repo.create(title: 'Temp');
      await repo.delete(id);

      expect((await row(id)).isDeleted, isTrue);
      expect(await repo.watchAll().first, isEmpty);
      expect((await queue()).single.opType, OpType.delete);
    });

    test(
      'a synced task gets an update op based on its server version',
      () async {
        final id = await repo.create(title: 'Synced');
        // Simulate a server ack (the sync engine does this in phase 2).
        await db.delete(db.syncQueue).go();
        await (db.update(db.tasks)..where((t) => t.id.equals(id))).write(
          const TasksCompanion(version: Value(4), dirty: Value(false)),
        );

        await repo.update(id, const TaskPatch(notes: 'more'));
        final op = (await queue()).single;
        expect(op.opType, OpType.update);
        expect(op.baseVersion, 4);

        await repo.delete(id);
        expect((await queue()).single.opType, OpType.delete);

        await repo.restore(id);
        expect((await queue()).single.opType, OpType.update);
      },
    );

    test('a new edit gives a failed op a fresh set of attempts', () async {
      final id = await repo.create(title: 'Flaky');
      await db
          .update(db.syncQueue)
          .write(
            const SyncQueueCompanion(
              status: Value(OpStatus.failed),
              attempts: Value(5),
              lastError: Value('boom'),
            ),
          );

      await repo.setCompleted(id, true);
      final op = (await queue()).single;
      expect(op.status, OpStatus.pending);
      expect(op.attempts, 0);
      expect(op.lastError, isNull);
    });

    test('the queue keeps FIFO order across coalesced edits', () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      await repo.update(a, const TaskPatch(title: 'A2'));

      expect((await queue()).map((o) => o.taskId), [a, b]);
    });

    test('task change and queue entry commit or roll back together', () async {
      final id = await repo.create(title: 'Original');
      // Make every outbox write fail, as a crash mid-transaction would.
      await db.customStatement('''
        CREATE TRIGGER fail_insert BEFORE INSERT ON sync_queue
        BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END''');
      await db.customStatement('''
        CREATE TRIGGER fail_update BEFORE UPDATE ON sync_queue
        BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END''');

      await expectLater(repo.create(title: 'Lost'), throwsA(anything));
      await expectLater(
        repo.update(id, const TaskPatch(title: 'Changed')),
        throwsA(anything),
      );

      final tasks = await db.select(db.tasks).get();
      expect(tasks.map((t) => t.title), [
        'Original',
      ], reason: 'neither the new task nor the edit may survive');
      expect(await queue(), hasLength(1));
    });

    test('pending count tracks the queue', () async {
      expect(await repo.watchPendingCount().first, 0);
      await repo.create(title: 'One');
      final two = await repo.create(title: 'Two');
      await repo.update(two, const TaskPatch(title: 'Two!'));
      expect(await repo.watchPendingCount().first, 2);
    });

    test('rejects an empty title without writing anything', () async {
      await expectLater(repo.create(title: '   '), throwsArgumentError);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await queue(), isEmpty);
    });

    test('updating a missing task throws and enqueues nothing', () async {
      await expectLater(repo.setCompleted('nope', true), throwsStateError);
      expect(await queue(), isEmpty);
    });
  });

  test(
    'tasks and queue survive closing and reopening the database file',
    () async {
      final dir = await Directory.systemTemp.createTemp('offline_tasks_');
      final file = File('${dir.path}/tasks.sqlite');
      addTearDown(() => dir.delete(recursive: true));

      final first = AppDatabase(NativeDatabase(file));
      final firstRepo = makeRepo(first);
      final keep = await firstRepo.create(
        title: 'Persisted',
        dueAt: DateTime.utc(2026, 12, 1, 8, 30, 15, 123),
      );
      final gone = await firstRepo.create(title: 'Deleted');
      await firstRepo.setCompleted(keep, true);
      await firstRepo.delete(gone);
      await first.close();

      final second = AppDatabase(NativeDatabase(file));
      addTearDown(second.close);
      final secondRepo = makeRepo(second);

      final visible = await secondRepo.watchAll().first;
      expect(visible.map((t) => t.title), ['Persisted']);
      expect(visible.single.completed, isTrue);
      expect(
        visible.single.dueAt!.toUtc(),
        DateTime.utc(2026, 12, 1, 8, 30, 15, 123),
        reason: 'millisecond precision survives the round trip',
      );
      expect((await secondRepo.getById(gone))!.isDeleted, isTrue);

      final ops = await second.select(second.syncQueue).get();
      expect(ops.map((o) => o.taskId).toSet(), {keep, gone});
      expect(await secondRepo.watchPendingCount().first, 2);
    },
  );
}
