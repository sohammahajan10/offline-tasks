// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = AppDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  test('v1 to v2 keeps every task and queue entry, in queue order', () async {
    final t = DateTime.utc(2026, 10, 18, 9).toIso8601String();
    final oldTasks = [
      for (final id in ['a', 'b'])
        v1.TasksData(
          id: id,
          title: 'Task $id',
          notes: '',
          priority: 1,
          tags: '["x"]',
          completed: 0,
          isDeleted: id == 'b' ? 1 : 0,
          version: 0,
          updatedAt: t,
          dirty: 1,
        ),
    ];
    // Wall-clock order disagrees with insertion order, as after a clock
    // change. v2 must keep insertion order.
    final oldQueue = [
      v1.SyncQueueData(
        opId: 'op-a',
        taskId: 'a',
        opType: 'create',
        payloadJson: '{"id":"a"}',
        baseVersion: 0,
        attempts: 2,
        status: 'pending',
        lastError: 'timeout',
        enqueuedAt: '2026-10-18T10:00:00.000Z',
      ),
      v1.SyncQueueData(
        opId: 'op-b',
        taskId: 'b',
        opType: 'delete',
        payloadJson: '{"id":"b"}',
        baseVersion: 0,
        attempts: 0,
        status: 'pending',
        enqueuedAt: '2026-10-18T09:00:00.000Z',
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.tasks, oldTasks);
        batch.insertAll(oldDb.syncQueue, oldQueue);
      },
      validateItems: (newDb) async {
        final tasks = await newDb.select(newDb.tasks).get();
        expect(tasks.map((t) => (t.id, t.isDeleted)), [('a', 0), ('b', 1)]);
        final queue = await (newDb.select(
          newDb.syncQueue,
        )..orderBy([(q) => OrderingTerm.asc(q.seq)])).get();
        expect(queue.map((q) => q.opId), ['op-a', 'op-b']);
        expect(queue.first.attempts, 2);
        expect(queue.first.lastError, 'timeout');
      },
    );
  });

  test('after v1 to v2, new entries continue the sequence', () async {
    final schema = await verifier.schemaAt(1);
    final old = v1.DatabaseAtV1(schema.newConnection());
    await old
        .into(old.tasks)
        .insert(v1.TasksCompanion.insert(id: 'a', title: 'A', updatedAt: 'x'));
    await old
        .into(old.syncQueue)
        .insert(
          v1.SyncQueueCompanion.insert(
            opId: 'op-old',
            taskId: 'a',
            opType: 'create',
            payloadJson: '{}',
            baseVersion: 0,
            enqueuedAt: '2030-01-01T00:00:00.000Z',
          ),
        );

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    await db
        .into(db.syncQueue)
        .insert(
          SyncQueueCompanion.insert(
            opId: 'op-new',
            taskId: 'a',
            opType: 'update',
            payloadJson: '{}',
            baseVersion: 0,
          ),
        );
    final queue = await (db.select(
      db.syncQueue,
    )..orderBy([(q) => OrderingTerm.asc(q.seq)])).get();
    expect(queue.map((q) => q.opId), ['op-old', 'op-new']);
    await db.close();
    await old.close();
  });

  test('v2 to v3 keeps tasks and queue; snapshots start empty', () async {
    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        batch.insert(
          oldDb.tasks,
          v2.TasksCompanion.insert(
            id: 'a',
            title: 'Kept',
            updatedAt: '2026-10-18T09:00:00.000Z',
            version: const Value(4),
          ),
        );
        batch.insert(
          oldDb.syncQueue,
          v2.SyncQueueCompanion.insert(
            opId: 'op-a',
            taskId: 'a',
            opType: 'update',
            payloadJson: '{}',
            baseVersion: 4,
          ),
        );
      },
      validateItems: (newDb) async {
        final task = await newDb.select(newDb.tasks).getSingle();
        expect(
          (task.title, task.version, task.serverSnapshot),
          ('Kept', 4, null),
        );
        final op = await newDb.select(newDb.syncQueue).getSingle();
        expect((op.opId, op.baseVersion), ('op-a', 4));
        expect(await newDb.select(newDb.syncLog).get(), isEmpty);
        expect(await newDb.select(newDb.syncState).get(), isEmpty);
      },
    );
  });

  test('v3 to v4 gives existing tasks distinct order keys by id', () async {
    await verifier.testWithDataIntegrity(
      oldVersion: 3,
      newVersion: 4,
      createOld: v3.DatabaseAtV3.new,
      createNew: v4.DatabaseAtV4.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        for (final id in ['c', 'a', 'b']) {
          batch.insert(
            oldDb.tasks,
            v3.TasksCompanion.insert(
              id: id,
              title: 'Task $id',
              updatedAt: '2026-10-19T09:00:00.000Z',
            ),
          );
        }
      },
      validateItems: (newDb) async {
        final rows = await (newDb.select(
          newDb.tasks,
        )..orderBy([(t) => OrderingTerm.asc(t.sortKey)])).get();
        expect(rows.map((r) => (r.id, r.sortKey)), [
          ('a', 'a0'),
          ('b', 'a1'),
          ('c', 'a2'),
        ]);
        expect(
          rows.every((r) => r.recurrence == null && r.seriesId == null),
          isTrue,
        );
      },
    );
  });
}
