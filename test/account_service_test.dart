import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/api/remote_api.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/account_service.dart';
import 'package:offline_tasks/domain/task_repository.dart';

import 'support/fake_remote_api.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late FakeRemoteApi server;
  late TaskRepository repo;
  late SyncEngine engine;
  late AccountService account;
  late int authSignOuts;
  var now = DateTime.utc(2026, 10, 19, 9);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    server = FakeRemoteApi();
    repo = TaskRepository(db, clock: () => now);
    engine = SyncEngine(db, server, clock: () => now);
    authSignOuts = 0;
    account = AccountService(
      db,
      engine,
      signOutOfAuth: () async {
        authSignOuts++;
        server.userId = null;
      },
    );
  });

  tearDown(() => db.close());

  Future<int> localTasks() async => (await db.select(db.tasks).get()).length;

  test('nothing queued: signs out and clears local data', () async {
    final id = await repo.create(title: 'Synced');
    await engine.sync();
    server.pushCalls.clear();

    final result = await account.signOut();

    expect(result, isA<SignedOut>());
    expect(authSignOuts, 1);
    expect(await localTasks(), 0);
    expect(server.pushCalls, isEmpty, reason: 'no sync needed');
    expect(server.rows[id], isNotNull, reason: 'the server copy is kept');
  });

  test('queued and online: syncs first, then signs out', () async {
    final id = await repo.create(title: 'Made offline');
    // Even an entry waiting out its backoff is sent right away.
    await db
        .update(db.syncQueue)
        .write(
          SyncQueueCompanion(
            attempts: const Value(2),
            nextRetryAt: Value(now.add(const Duration(minutes: 5))),
          ),
        );

    final result = await account.signOut();

    expect(result, isA<SignedOut>());
    expect(server.rows[id]!['title'], 'Made offline');
    expect(authSignOuts, 1);
    expect(await localTasks(), 0);
  });

  test('queued and offline: returns the changes and changes nothing', () async {
    final a = await repo.create(title: 'Groceries');
    await repo.create(title: 'Call mom');
    await repo.delete(a);
    server.offline = true;

    final result = await account.signOut();

    expect(result, isA<UnsyncedChangesBlockSignOut>());
    final changes = (result as UnsyncedChangesBlockSignOut).changes;
    expect(changes.map((c) => (c.title, c.opType)), [
      ('Groceries', 'delete'),
      ('Call mom', 'create'),
    ]);
    expect(authSignOuts, 0, reason: 'still signed in');
    expect(await localTasks(), 2, reason: 'nothing deleted');
    expect(await db.select(db.syncQueue).get(), hasLength(2));
  });

  test(
    'a change the server keeps rejecting is reported with its error',
    () async {
      await repo.create(title: 'Bad data');
      server.failures.add(
        const RemoteException('violates check constraint', retryable: false),
      );
      await engine.sync(); // -> failed
      server.failures.add(
        const RemoteException('violates check constraint', retryable: false),
      );

      final result = await account.signOut();

      final change = (result as UnsyncedChangesBlockSignOut).changes.single;
      expect(change.failed, isTrue);
      expect(change.lastError, contains('check constraint'));
      expect(server.pushCalls, hasLength(2), reason: 'it got one more try');
    },
  );

  test('after the user confirms, unsynced changes are discarded', () async {
    await repo.create(title: 'Throwaway');
    server.offline = true;
    expect(await account.signOut(), isA<UnsyncedChangesBlockSignOut>());

    final result = await account.signOut(discardUnsynced: true);

    expect(result, isA<SignedOut>());
    expect(authSignOuts, 1);
    expect(await localTasks(), 0);
    expect(await db.select(db.syncQueue).get(), isEmpty);
  });

  test('if ending the session fails, local data is kept', () async {
    await repo.create(title: 'Keep me');
    await engine.sync();
    final failing = AccountService(
      db,
      engine,
      signOutOfAuth: () async => throw Exception('network down'),
    );

    await expectLater(failing.signOut(), throwsException);
    expect(await localTasks(), 1);
    expect(
      await db.readState(SyncEngine.leaseKey),
      isNull,
      reason: 'lease released',
    );
  });

  test('waits for a running sync before clearing the database', () async {
    await repo.create(title: 'In flight');
    final order = <String>[];
    server.onPush = (_) async {
      order.add('push started');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      order.add('push finished');
    };
    final background = SyncEngine(db, server, clock: () => now);

    final running = background.sync();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final signOut = AccountService(
      db,
      engine,
      signOutOfAuth: () async => order.add('signed out'),
    ).signOut(discardUnsynced: true);
    await Future.wait([running, signOut]);

    expect(order, ['push started', 'push finished', 'signed out']);
    expect(await localTasks(), 0);
  });
}
