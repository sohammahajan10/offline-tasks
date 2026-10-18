import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/api/remote_api.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/recurrence.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_query.dart';
import 'package:offline_tasks/domain/task_repository.dart';

import 'support/fake_remote_api.dart';

/// Shared, manually advanced clock, so last-writer-wins is deterministic.
class TestClock {
  DateTime t = DateTime.utc(2026, 10, 18, 9);
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
}

/// One phone: its own database, repository and sync engine.
class Device {
  Device(this.server, this.clock, {int pageSize = 500})
    : db = AppDatabase(NativeDatabase.memory()) {
    repo = TaskRepository(db, clock: clock.now);
    engine = SyncEngine(
      db,
      server,
      clock: clock.now,
      random: Random(7),
      pageSize: pageSize,
    );
  }

  final FakeRemoteApi server;
  final TestClock clock;
  final AppDatabase db;
  late final TaskRepository repo;
  late final SyncEngine engine;

  Future<SyncReport> sync() => engine.sync();

  Future<List<SyncOp>> queue() => (db.select(
    db.syncQueue,
  )..orderBy([(q) => OrderingTerm.asc(q.seq)])).get();

  Future<TaskRow?> row(String id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<SyncLogEntry>> log([String? level]) {
    final q = db.select(db.syncLog)..orderBy([(l) => OrderingTerm.asc(l.id)]);
    if (level != null) q.where((l) => l.level.equals(level));
    return q.get();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeRemoteApi server;
  late TestClock clock;
  late Device a;
  late Device b;

  setUp(() {
    server = FakeRemoteApi();
    clock = TestClock();
    a = Device(server, clock);
    b = Device(server, clock);
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  group('push', () {
    test(
      'drains the queue in seq order, deleting entries only after the ack',
      () async {
        final t1 = await a.repo.create(title: 'First');
        final t2 = await a.repo.create(title: 'Second');
        await a.repo.update(t1, const TaskPatch(notes: 'merged edit'));

        server.onPush = (call) async {
          // While on the wire the entry still exists, marked in flight.
          final sending = (await a.queue()).firstWhere(
            (o) => o.opId == call.opId,
          );
          expect(sending.status, OpStatus.inFlight);
        };

        final report = await a.sync();

        expect(report.pushed, 2);
        expect(server.pushCalls.map((c) => c.task['id']), [t1, t2]);
        expect(await a.queue(), isEmpty);
        expect(server.rows[t1]!['notes'], 'merged edit');
        for (final id in [t1, t2]) {
          final row = (await a.row(id))!;
          expect(row.version, 1);
          expect(row.dirty, isFalse);
          expect(row.serverSnapshot, isNotNull);
        }
        expect(
          (await a.log(LogLevel.info)).map((l) => l.message),
          contains(startsWith('Uploaded “First”')),
        );
      },
    );

    test('a retry after a lost ack does not create a duplicate', () async {
      final id = await a.repo.create(title: 'Pay rent');
      server.loseNextAck = true;

      final first = await a.sync();
      expect(first.error, contains('timed out'));
      expect(server.rows, hasLength(1), reason: 'the server did apply it');
      final op = (await a.queue()).single;
      expect(op.attempts, 1);
      expect(op.status, OpStatus.pending);

      clock.advance(const Duration(minutes: 1));
      await a.sync();

      expect(server.pushCalls.map((c) => c.opId), [op.opId, op.opId]);
      expect(server.rows, hasLength(1));
      expect(server.rows[id]!['version'], 1, reason: 'not applied twice');
      expect(await a.queue(), isEmpty);
      expect((await a.row(id))!.version, 1);
    });

    test(
      'offline: backoff with jitter, then failed after 5 attempts',
      () async {
        final id = await a.repo.create(title: 'Offline task');
        server.offline = true;

        DateTime? lastRetryAt;
        for (var attempt = 1; attempt <= 5; attempt++) {
          final report = await a.sync();
          expect(report.error, 'offline');
          final op = (await a.queue()).single;
          expect(op.attempts, attempt);
          if (attempt < 5) {
            expect(op.status, OpStatus.pending);
            final delay = op.nextRetryAt!.difference(clock.t);
            final expected = Duration(seconds: 2 << (attempt - 1));
            expect(delay, greaterThanOrEqualTo(expected));
            expect(delay, lessThanOrEqualTo(expected * 1.25));
            lastRetryAt = op.nextRetryAt;

            // Before the retry time nothing is sent.
            final calls = server.pushCalls.length;
            await a.sync();
            expect(server.pushCalls.length, calls);
            clock.t = lastRetryAt!;
          } else {
            expect(op.status, OpStatus.failed);
            expect(op.nextRetryAt, isNull);
            expect(op.lastError, 'offline');
            expect(report.failed, 1);
          }
        }

        // A failed entry is never retried automatically.
        server.offline = false;
        clock.advance(const Duration(hours: 1));
        await a.sync();
        expect(server.pushCalls, hasLength(5));
        expect((await a.row(id))!.dirty, isTrue);
        expect(
          (await a.log(LogLevel.error)).map((l) => l.message),
          containsAll([
            startsWith('Upload of “Offline task” failed (attempt 1/5)'),
            startsWith('Gave up on “Offline task” after 5 attempt(s)'),
          ]),
        );

        // Manual retry from the UI.
        await a.engine.retry((await a.queue()).single.seq);
        await a.sync();
        expect(await a.queue(), isEmpty);
        expect(server.rows[id]!['title'], 'Offline task');
      },
    );

    test(
      'a permanent error fails one entry without blocking other tasks',
      () async {
        final bad = await a.repo.create(title: 'Rejected');
        final good = await a.repo.create(title: 'Accepted');
        server.failures.add(
          const RemoteException('violates check constraint', retryable: false),
        );

        final report = await a.sync();

        expect(report.failed, 1);
        expect(report.pushed, 1);
        final op = (await a.queue()).single;
        expect(op.taskId, bad);
        expect(op.status, OpStatus.failed);
        expect(server.rows.keys, [good]);
      },
    );

    test(
      'an edit made during an in-flight push is kept and sent next',
      () async {
        final id = await a.repo.create(title: 'v1');
        await a.sync();
        await a.repo.update(id, const TaskPatch(title: 'v2'));

        var edited = false;
        server.onPush = (call) async {
          if (edited) return;
          edited = true;
          clock.advance(const Duration(seconds: 1));
          await a.repo.update(id, const TaskPatch(title: 'v3'));
          await a.repo.setCompleted(id, true);
        };

        final report = await a.sync();

        expect(report.pushed, 2);
        expect(report.conflicts, 0);
        expect(server.pushCalls.map((c) => (c.task['title'], c.baseVersion)), [
          ('v1', 0),
          ('v2', 1),
          ('v3', 2), // re-targeted at the version our own push created
        ]);
        expect(server.rows[id]!['title'], 'v3');
        expect(server.rows[id]!['completed'], isTrue);
        expect(server.rows[id]!['version'], 3);
        expect(await a.queue(), isEmpty);
        expect((await a.row(id))!.dirty, isFalse);
      },
    );

    test(
      'create then delete before any sync: the server accepts the delete',
      () async {
        final id = await a.repo.create(title: 'Never mind');
        await a.repo.delete(id);

        final report = await a.sync();

        expect(report.error, isNull);
        expect(report.pushed, 1);
        expect(server.pushCalls.single.baseVersion, 0);
        expect(server.rows[id]!['is_deleted'], isTrue);
        expect(server.rows[id]!['version'], 1);
        expect(await a.queue(), isEmpty);

        // Another device never sees it.
        await b.sync();
        expect(await b.row(id), isNull);
        expect(await b.repo.watchAll().first, isEmpty);
      },
    );

    test(
      'a push interrupted by a crash is recovered and not duplicated',
      () async {
        final id = await a.repo.create(title: 'Mid-flight');
        // The server applied it, then the app was killed before the ack was
        // processed: the entry is left in flight.
        server.loseNextAck = true;
        await a.sync();
        await a.db
            .update(a.db.syncQueue)
            .write(const SyncQueueCompanion(status: Value(OpStatus.inFlight)));
        final restarted = SyncEngine(a.db, server, clock: clock.now);

        clock.advance(const Duration(minutes: 1));
        final report = await restarted.sync();

        expect(report.pushed, 1);
        expect(server.rows[id]!['version'], 1);
        expect(await a.queue(), isEmpty);
        expect(
          (await a.log()).map((l) => l.message),
          contains('Recovered 1 interrupted upload(s)'),
        );
      },
    );

    test(
      'a stale version is merged and re-pushed, never marked failed',
      () async {
        final id = await a.repo.create(title: 'Contested');
        await a.sync();
        await a.repo.update(id, const TaskPatch(title: 'Mine'));
        // Another device writes a different field just before our push lands.
        var raced = false;
        server.onPush = (call) async {
          if (raced) return;
          raced = true;
          server.serverEdit(id, {'notes': 'theirs'});
        };

        final report = await a.sync();

        expect(report.error, isNull);
        expect(report.failed, 0);
        expect(server.pushCalls.map((c) => c.baseVersion), [0, 1, 2]);
        expect(server.rows[id]!['title'], 'Mine');
        expect(server.rows[id]!['notes'], 'theirs');
        expect(await a.queue(), isEmpty);
      },
    );

    test(
      'after 3 stale rounds the entry falls back to a normal retry',
      () async {
        final id = await a.repo.create(title: 'Hot task');
        await a.sync();
        await a.repo.update(id, const TaskPatch(title: 'Mine'));
        var n = 0;
        server.onPush = (call) async =>
            server.serverEdit(id, {'notes': '${n++}'});

        final report = await a.sync();

        expect(server.pushCalls.skip(1), hasLength(3), reason: '3 rounds');
        expect(report.failed, 0);
        final op = (await a.queue()).single;
        expect(op.status, OpStatus.pending, reason: 'not failed');
        expect(op.attempts, 1);
        expect(op.nextRetryAt, isNotNull);
        expect(op.lastError, 'Still out of date after 3 merge rounds');
        expect(
          op.baseVersion,
          server.rows[id]!['version'],
          reason: 'already re-targeted at the latest version',
        );

        // The other device calms down; the backoff retry goes through.
        server.onPush = null;
        clock.t = op.nextRetryAt!;
        await a.sync();
        expect(await a.queue(), isEmpty);
        expect(server.rows[id]!['title'], 'Mine');
        expect(server.rows[id]!['notes'], '2');
      },
    );

    test('concurrent sync calls share one run', () async {
      await a.repo.create(title: 'Once');
      final results = await Future.wait([a.sync(), a.sync()]);
      expect(identical(results[0], results[1]), isTrue);
      expect(server.pushCalls, hasLength(1));
    });

    test('signed out: nothing is sent', () async {
      server.userId = null;
      await a.repo.create(title: 'Local only');
      final report = await a.sync();
      expect(report.skipped, 'signed out');
      expect(server.pushCalls, isEmpty);
      expect(await a.queue(), hasLength(1));
    });
  });

  group('pull', () {
    test('fetches only changes after the stored cursor', () async {
      final t1 = await a.repo.create(title: 'One');
      await a.repo.create(title: 'Two');
      await a.sync();

      final first = await b.sync();
      expect(first.pulled, 2);
      expect(b.server.pullCalls.last, isNull, reason: 'first pull: all rows');
      final cursor = DateTime.parse(
        (await b.db.readState('pull_cursor:user-1'))!,
      );

      final second = await b.sync();
      expect(second.pulled, 0);
      expect(
        server.pullCalls.last,
        cursor.subtract(const Duration(seconds: 5)),
      );

      server.serverEdit(t1, {'title': 'One (edited)'});
      final third = await b.sync();
      expect(third.pulled, 1);
      expect((await b.row(t1))!.title, 'One (edited)');
      expect((await b.row(t1))!.version, 2);
    });

    test('pages through large deltas', () async {
      for (var i = 0; i < 5; i++) {
        await a.repo.create(title: 'Task $i');
      }
      await a.sync();
      final paged = Device(server, clock, pageSize: 2);
      addTearDown(paged.db.close);
      server.pullCalls.clear();

      final report = await paged.sync();

      expect(report.pulled, 5);
      expect(server.pullCalls, hasLength(3));
      expect(await paged.repo.watchAll().first, hasLength(5));
    });

    test('merges into local unsent changes and re-targets their entry', () async {
      final id = await a.repo.create(title: 'Shared');
      await a.sync();
      await b.sync();

      // B edits notes, but its upload is stuck (failed) so the pull runs first.
      await b.repo.update(id, const TaskPatch(notes: 'from B'));
      server.failures.add(const RemoteException('rejected', retryable: false));
      await b.sync();
      // Meanwhile A renames it.
      clock.advance(const Duration(minutes: 1));
      await a.repo.update(id, const TaskPatch(title: 'Shared (renamed)'));
      await a.sync();

      await b.engine.retryAllFailed();
      server.failures.add(const RemoteException('rejected', retryable: false));
      await b.sync(); // pull merges; push fails again (scripted)

      final row = (await b.row(id))!;
      expect(row.title, 'Shared (renamed)');
      expect(row.notes, 'from B');
      expect(row.version, 2);
      final op = (await b.queue()).single;
      expect(op.baseVersion, 2, reason: 're-targeted at the pulled version');
      expect(jsonDecode(op.payloadJson)['title'], 'Shared (renamed)');

      await b.engine.retryAllFailed();
      final report = await b.sync();
      expect(report.conflicts, 0);
      expect(server.pushCalls.last.baseVersion, 2);
      expect(server.rows[id]!['title'], 'Shared (renamed)');
      expect(server.rows[id]!['notes'], 'from B');
    });
  });

  group('conflicts between two devices', () {
    late String id;

    setUp(() async {
      id = await a.repo.create(title: 'Buy milk', category: 'Home');
      await a.sync();
      await b.sync();
    });

    Future<void> bothSync() async {
      await a.sync();
      await b.sync();
      await a.sync();
    }

    test(
      'offline edits to different fields on A and B both reach the server',
      () async {
        // Both phones go offline and edit different fields of the same task.
        clock.advance(const Duration(minutes: 1));
        await a.repo.update(id, const TaskPatch(title: 'Buy oat milk'));
        clock.advance(const Duration(minutes: 1));
        await b.repo.update(id, const TaskPatch(priority: Priority.high));
        final calls = server.pushCalls.length;

        // Back online: A syncs first, then B.
        await a.sync();
        final reportB = await b.sync();

        final row = server.rows[id]!;
        expect(row['title'], 'Buy oat milk');
        expect(row['priority'], Priority.high.index);
        expect(row['version'], 3);
        // B's first push was rejected as stale (base 1 < 2), merged, re-pushed.
        expect(
          server.pushCalls
              .skip(calls)
              .map((c) => (c.task['title'], c.baseVersion)),
          [('Buy oat milk', 1), ('Buy milk', 1), ('Buy oat milk', 2)],
        );
        expect(reportB.failed, 0);
        expect(reportB.conflicts, 0);
        expect(await b.queue(), isEmpty);
      },
    );

    test('different fields: both edits survive on every device', () async {
      clock.advance(const Duration(minutes: 1));
      await a.repo.update(id, const TaskPatch(title: 'Buy oat milk'));
      clock.advance(const Duration(minutes: 1));
      await b.repo.setCompleted(id, true);

      await bothSync();

      for (final d in [a, b]) {
        final row = (await d.row(id))!;
        expect(row.title, 'Buy oat milk');
        expect(row.completed, isTrue);
        expect(row.version, 3);
        expect(row.dirty, isFalse);
      }
      expect(await b.log(LogLevel.conflict), isEmpty);
      expect(
        (await b.log(LogLevel.info)).map((l) => l.message),
        contains('Merged server changes into “Buy oat milk”'),
      );
    });

    test('same field: last writer wins and the conflict is logged', () async {
      clock.advance(const Duration(minutes: 5));
      await a.repo.update(id, const TaskPatch(title: 'Title from A (newer)'));
      clock.t = clock.t.subtract(const Duration(minutes: 3));
      await b.repo.update(
        id,
        const TaskPatch(title: 'Title from B (older)', notes: 'B notes'),
      );
      clock.advance(const Duration(minutes: 10));

      await bothSync();

      for (final d in [a, b]) {
        final row = (await d.row(id))!;
        expect(row.title, 'Title from A (newer)');
        expect(row.notes, 'B notes', reason: 'only B changed notes');
      }
      final conflict = (await b.log(LogLevel.conflict)).single;
      expect(conflict.taskId, id);
      expect(conflict.message, contains('title'));
      expect(conflict.message, contains('kept remote'));
    });

    test('same field: a newer edit on the second device wins', () async {
      clock.advance(const Duration(minutes: 1));
      await a.repo.update(id, const TaskPatch(category: 'Errands'));
      clock.advance(const Duration(minutes: 1));
      await b.repo.update(id, const TaskPatch(category: 'Weekend'));

      await bothSync();

      expect((await a.row(id))!.category, 'Weekend');
      expect(server.rows[id]!['category'], 'Weekend');
      expect(
        (await b.log(LogLevel.conflict)).single.message,
        contains('kept local'),
      );
    });

    test(
      'delete vs edit: stays deleted, keeps the edit for a restore',
      () async {
        clock.advance(const Duration(minutes: 1));
        await a.repo.delete(id);
        clock.advance(const Duration(minutes: 1));
        await b.repo.update(id, const TaskPatch(title: 'Buy milk and eggs'));

        await bothSync();

        for (final d in [a, b]) {
          final row = (await d.row(id))!;
          expect(row.isDeleted, isTrue);
          expect(row.title, 'Buy milk and eggs');
          expect(await d.repo.watchAll().first, isEmpty);
        }
        expect(server.rows[id]!['is_deleted'], isTrue);

        await a.repo.restore(id);
        await bothSync();
        expect(
          (await b.repo.watchAll().first).single.title,
          'Buy milk and eggs',
        );
      },
    );
  });

  group('lease across isolates', () {
    // Two engines on one database file stand in for the app isolate and the
    // WorkManager isolate: they share only what is in SQLite.
    test('a second engine skips while the first holds the lease', () async {
      await a.repo.create(title: 'Once');
      final background = SyncEngine(a.db, server, clock: clock.now);
      SyncReport? concurrent;
      server.onPush = (_) async => concurrent ??= await background.sync();

      final report = await a.sync();

      expect(report.pushed, 1);
      expect(concurrent!.skipped, 'another sync is running');
      expect(server.pushCalls, hasLength(1));
      expect(
        await a.db.readState(SyncEngine.leaseKey),
        isNull,
        reason: 'released at the end of the run',
      );
      expect((await background.sync()).skipped, isNull);
    });

    test('a lease left by a killed isolate expires', () async {
      await a.repo.create(title: 'Orphaned lease');
      await a.db.writeState(
        SyncEngine.leaseKey,
        jsonEncode({
          'owner': 'dead-isolate',
          'expires': clock.t
              .add(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        }),
      );

      expect((await a.sync()).skipped, 'another sync is running');
      clock.advance(const Duration(minutes: 2));
      final report = await a.sync();
      expect(report.skipped, isNull);
      expect(report.pushed, 1);
    });

    test(
      'a lease from the future (clock moved back) is not honoured',
      () async {
        await a.db.writeState(
          SyncEngine.leaseKey,
          jsonEncode({
            'owner': 'other',
            'expires': clock.t
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch,
          }),
        );
        expect((await a.sync()).skipped, isNull);
      },
    );

    test('a run that loses its lease stops instead of racing', () async {
      final t1 = await a.repo.create(title: 'One');
      await a.repo.create(title: 'Two');
      server.onPush = (_) async {
        // Our lease was taken over (we were too slow to renew).
        await a.db.writeState(
          SyncEngine.leaseKey,
          jsonEncode({
            'owner': 'other',
            'expires': clock.t
                .add(const Duration(minutes: 2))
                .millisecondsSinceEpoch,
          }),
        );
      };

      final report = await a.sync();

      expect(report.error, 'lost the sync lease to another run');
      expect(server.pushCalls.map((c) => c.task['id']), [t1]);
      expect((await a.queue()).single.status, OpStatus.pending);
      expect(
        await a.db.readState(SyncEngine.leaseKey),
        contains('other'),
        reason: "never deletes someone else's lease",
      );
    });
  });

  group('recurring tasks and manual order across devices', () {
    test(
      'both devices complete the same occurrence offline: one next task',
      () async {
        final due = DateTime.utc(2026, 10, 20, 8);
        final id = await a.repo.create(
          title: 'Water plants',
          dueAt: due,
          recurrence: Recurrence.weekly,
        );
        await a.sync();
        await b.sync();

        // Both phones offline, both tick the same occurrence off.
        clock.advance(const Duration(minutes: 1));
        await a.repo.setCompleted(id, true);
        clock.advance(const Duration(minutes: 1));
        await b.repo.setCompleted(id, true);
        final nextId = occurrenceId(id, DateTime.utc(2026, 10, 27, 8));
        expect(
          (await a.row(nextId))!.id,
          (await b.row(nextId))!.id,
          reason: 'same deterministic id on both devices',
        );

        await a.sync();
        final reportB = await b.sync();
        await a.sync();

        expect(reportB.failed, 0);
        expect(reportB.conflicts, 0, reason: 'identical content, nothing lost');
        final series = server.rows.values.where((r) => r['series_id'] == id);
        expect(series, hasLength(2), reason: 'the original + ONE next task');
        expect(server.rows[nextId]!['completed'], isFalse);
        expect(server.rows[id]!['completed'], isTrue);
        for (final d in [a, b]) {
          expect(await d.queue(), isEmpty);
          final visible = await d.repo.watchAll().first;
          expect(visible.map((t) => t.id).toSet(), {id, nextId});
        }
      },
    );

    test('moves of different tasks on two devices both survive', () async {
      final c = await a.repo.create(title: 'C');
      final bTask = await a.repo.create(title: 'B');
      final aTask = await a.repo.create(title: 'A');
      await a.sync();
      await b.sync();

      // Device A drags A to the bottom; device B drags C to the top.
      clock.advance(const Duration(minutes: 1));
      await a.repo.move(aTask, afterId: c);
      clock.advance(const Duration(minutes: 1));
      await b.repo.move(c, beforeId: aTask);

      await a.sync();
      await b.sync();
      await a.sync();

      Future<List<String>> order(Device d) async =>
          (await d.repo
                  .watchTasks(const TaskQuery(sort: TaskSort.manual))
                  .first)
              .map((t) => t.title)
              .toList();
      expect(await order(a), ['C', 'B', 'A']);
      expect(await order(b), ['C', 'B', 'A']);
      expect(await b.log(LogLevel.conflict), isEmpty);
      expect(server.rows[bTask]!['version'], 1, reason: 'B never rewritten');
    });

    test('the same task moved on both devices: the later move wins', () async {
      final c = await a.repo.create(title: 'C');
      final bTask = await a.repo.create(title: 'B');
      final aTask = await a.repo.create(title: 'A');
      await a.sync();
      await b.sync();

      clock.advance(const Duration(minutes: 1));
      await a.repo.move(aTask, afterId: bTask, beforeId: c); // B A C
      clock.advance(const Duration(minutes: 1));
      await b.repo.move(aTask, afterId: c); // B C A (later)

      await a.sync();
      await b.sync();
      await a.sync();

      final conflict = (await b.log(LogLevel.conflict)).single;
      expect(conflict.message, contains('sort_key'));
      expect(conflict.message, contains('kept local'));
      for (final d in [a, b]) {
        final titles =
            (await d.repo
                    .watchTasks(const TaskQuery(sort: TaskSort.manual))
                    .first)
                .map((t) => t.title);
        expect(titles, ['B', 'C', 'A']);
      }
    });
  });
}
