import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/sync/connectivity_monitor.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/account_service.dart';
import 'package:offline_tasks/domain/task_repository.dart';
import 'package:offline_tasks/presentation/providers.dart';
import 'package:offline_tasks/presentation/screens/account_screen.dart';
import 'package:offline_tasks/presentation/screens/task_list_screen.dart';

import '../support/fake_remote_api.dart';

const _me = Account(id: 'user-1', email: 'me@example.test');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late TaskRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(db);
  });

  /// Pumps [home] with every backend dependency replaced.
  Future<void> pump(
    WidgetTester tester, {
    Widget home = const TaskListScreen(),
    bool configured = true,
    Account? account = _me,
    NetworkStatus network = NetworkStatus.online,
    AccountService? accountService,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          taskRepositoryProvider.overrideWithValue(repo),
          syncConfiguredProvider.overrideWithValue(configured),
          supabaseClientProvider.overrideWithValue(null),
          syncEngineProvider.overrideWithValue(null),
          syncCoordinatorProvider.overrideWithValue(null),
          accountServiceProvider.overrideWithValue(accountService),
          accountProvider.overrideWith((ref) => Stream.value(account)),
          networkStatusProvider.overrideWith((ref) => Stream.value(network)),
        ],
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmounts the app (closing its stream queries) before the database.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await db.close();
  }

  group('task list', () {
    testWidgets('empty state, and no sync UI in a local-only build', (
      tester,
    ) async {
      await pump(tester, configured: false);
      expect(find.byKey(const Key('tasks-empty')), findsOneWidget);
      expect(find.byKey(const Key('sync-button')), findsNothing);
      expect(find.byKey(const Key('banner-signed-out')), findsNothing);
      await done(tester);
    });

    testWidgets('adding a task shows it at once with a pending badge', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('title-field')), 'Buy milk');
      await tester.tap(find.byKey(const Key('save-task')));
      await tester.pumpAndSettle();

      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.byKey(const Key('badge-pending')), findsOneWidget);
      await done(tester);
    });

    testWidgets('the title is required', (tester) async {
      await pump(tester);
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-task')));
      await tester.pumpAndSettle();
      expect(find.text('Give the task a title'), findsOneWidget);
      expect(await db.select(db.tasks).get(), isEmpty);
      await done(tester);
    });

    testWidgets('search with no matches, then clear filters', (tester) async {
      await repo.create(title: 'Pay rent');
      await repo.create(title: 'Buy milk', tags: ['shopping']);
      await pump(tester);

      await tester.enterText(find.byKey(const Key('search-field')), 'zzz');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('tasks-no-match')), findsOneWidget);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Pay rent'), findsOneWidget);
      expect(find.text('Buy milk'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('search-field')), 'shop');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.text('Buy milk'), findsOneWidget);
      expect(find.text('Pay rent'), findsNothing);
      await done(tester);
    });

    testWidgets('status filter and checking a task off', (tester) async {
      await repo.create(title: 'Open task');
      await repo.create(title: 'Second task');
      await pump(tester);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('status-done')));
      await tester.pumpAndSettle();
      expect(find.byType(TaskTileFinder.type), findsOneWidget);

      await tester.tap(find.byKey(const Key('status-pending')));
      await tester.pumpAndSettle();
      expect(find.byType(TaskTileFinder.type), findsOneWidget);
      await done(tester);
    });

    testWidgets('swipe to delete, then undo', (tester) async {
      final id = await repo.create(title: 'Swipe me');
      await pump(tester);

      await tester.drag(find.text('Swipe me'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsNothing);
      expect(
        (await repo.getById(id))!.isDeleted,
        isTrue,
        reason: 'a tombstone, not a hard delete',
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsOneWidget);
      await done(tester);
    });
  });

  group('status banner', () {
    testWidgets('offline, with the number of changes waiting', (tester) async {
      await repo.create(title: 'A');
      await repo.create(title: 'B');
      await pump(tester, network: NetworkStatus.offline);
      expect(find.byKey(const Key('banner-offline')), findsOneWidget);
      expect(
        find.textContaining('2 changes are waiting to sync'),
        findsOneWidget,
      );
      await done(tester);
    });

    testWidgets('network up but server unreachable', (tester) async {
      await pump(tester, network: NetworkStatus.unreachable);
      expect(find.byKey(const Key('banner-unreachable')), findsOneWidget);
      await done(tester);
    });

    testWidgets('signed out invites signing in', (tester) async {
      await pump(tester, account: null);
      expect(find.byKey(const Key('banner-signed-out')), findsOneWidget);
      await done(tester);
    });

    testWidgets('failed changes link to the sync log', (tester) async {
      final id = await repo.create(title: 'Rejected');
      await (db.update(db.syncQueue)..where((q) => q.taskId.equals(id))).write(
        const SyncQueueCompanion(
          status: Value(OpStatus.failed),
          lastError: Value('check constraint'),
        ),
      );
      await pump(tester);
      expect(find.byKey(const Key('banner-failed')), findsOneWidget);
      expect(find.byKey(const Key('badge-failed')), findsOneWidget);

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Sync log'), findsOneWidget);
      expect(find.textContaining('check constraint'), findsOneWidget);
      await done(tester);
    });

    testWidgets('online and all synced: no banner', (tester) async {
      await pump(tester);
      for (final k in [
        'banner-offline',
        'banner-unreachable',
        'banner-signed-out',
        'banner-failed',
      ]) {
        expect(find.byKey(Key(k)), findsNothing);
      }
      await done(tester);
    });
  });

  group('sign-out', () {
    late FakeRemoteApi server;
    late int authSignOuts;
    late AccountService service;

    setUp(() {
      server = FakeRemoteApi();
      authSignOuts = 0;
      service = AccountService(
        db,
        SyncEngine(db, server),
        signOutOfAuth: () async => authSignOuts++,
      );
    });

    Future<void> tapSignOut(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
    }

    testWidgets('unsynced changes: dialog with Cancel as the default', (
      tester,
    ) async {
      await repo.create(title: 'Only on this phone');
      server.offline = true;
      await pump(tester, home: const AccountScreen(), accountService: service);

      await tapSignOut(tester);
      expect(find.text('1 unsynced change will be lost'), findsOneWidget);
      expect(find.text('• Only on this phone'), findsOneWidget);
      final cancel = tester.widget<FilledButton>(
        find.byKey(const Key('cancel-sign-out')),
      );
      expect(cancel.autofocus, isTrue, reason: 'Cancel is the default');

      await tester.tap(find.byKey(const Key('cancel-sign-out')));
      await tester.pumpAndSettle();
      expect(authSignOuts, 0);
      expect(await db.select(db.tasks).get(), hasLength(1));

      // Dismissing the dialog (back / tap outside) also means Cancel.
      await tapSignOut(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(authSignOuts, 0);
      expect(await db.select(db.tasks).get(), hasLength(1));
      await done(tester);
    });

    testWidgets('confirming discards the changes and signs out', (
      tester,
    ) async {
      await repo.create(title: 'Throwaway');
      server.offline = true;
      await pump(tester, home: const AccountScreen(), accountService: service);

      await tapSignOut(tester);
      await tester.tap(find.byKey(const Key('confirm-discard')));
      await tester.pumpAndSettle();

      expect(authSignOuts, 1);
      expect(await db.select(db.tasks).get(), isEmpty);
      await done(tester);
    });

    testWidgets('everything synced: signs out without asking', (tester) async {
      await repo.create(title: 'Will sync');
      await pump(tester, home: const AccountScreen(), accountService: service);

      await tapSignOut(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(authSignOuts, 1);
      expect(server.rows, hasLength(1), reason: 'synced first');
      await done(tester);
    });
  });
}

/// The list tile type, without importing a private widget.
abstract final class TaskTileFinder {
  static const type = ListTile;
}
