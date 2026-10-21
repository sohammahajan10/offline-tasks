import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/sync/connectivity_monitor.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/account_service.dart';
import 'package:offline_tasks/domain/recurrence.dart';
import 'package:offline_tasks/domain/task_query.dart';
import 'package:offline_tasks/domain/task_repository.dart';
import 'package:offline_tasks/presentation/providers.dart';
import 'package:offline_tasks/presentation/screens/account_screen.dart';
import 'package:offline_tasks/presentation/screens/task_edit_screen.dart';
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
          notificationsProvider.overrideWithValue(null),
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

  /// A weekly series ticked twice: A and B done, C open. Returns A's id.
  Future<String> seriesWithTwoDone() async {
    final a = await repo.create(
      title: 'Water plants',
      dueAt: DateTime.now().add(const Duration(days: 1)),
      recurrence: Recurrence.weekly,
    );
    await repo.setCompleted(a, true);
    final b = (await db.select(db.tasks).get()).singleWhere((t) => t.id != a);
    await repo.setCompleted(b.id, true);
    return a;
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

  group('phase 5', () {
    testWidgets('a repeating task needs a deadline', (tester) async {
      await pump(tester);
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('title-field')), 'Gym');
      await tester.tap(find.byKey(const Key('repeat-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Daily').last);
      await tester.pumpAndSettle();
      expect(find.text('Set a deadline first'), findsOneWidget);

      await tester.tap(find.byKey(const Key('save-task')));
      await tester.pumpAndSettle();
      expect(await db.select(db.tasks).get(), isEmpty, reason: 'not saved');
      await done(tester);
    });

    testWidgets(
      'ticking a repeating task off shows the next one; unticking removes it',
      (tester) async {
        final due = DateTime.now().add(const Duration(days: 1));
        await repo.create(
          title: 'Water plants',
          dueAt: due,
          recurrence: Recurrence.weekly,
        );
        await pump(tester);
        expect(find.text('Weekly'), findsOneWidget);

        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(find.text('Water plants'), findsNWidgets(2));
        final tasks = await db.select(db.tasks).get();
        expect(
          tasks.where((t) => !t.completed).single.dueAt!.toUtc(),
          Recurrence.weekly.next(due),
        );

        // Unticking it again takes the generated next one back.
        await tester.tap(
          find.byWidgetPredicate((w) => w is Checkbox && w.value == true),
        );
        await tester.pumpAndSettle();
        expect(find.text('Water plants'), findsOneWidget);
        await done(tester);
      },
    );

    testWidgets('unticking an old repeat is refused and stays ticked', (
      tester,
    ) async {
      final a = await seriesWithTwoDone();
      await pump(tester);
      final box = find.descendant(
        of: find.byKey(Key('task-$a')),
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(box).value, isTrue);

      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This repeat is already past. Reopen the latest one instead.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<Checkbox>(box).value, isTrue);
      final open = (await db.select(db.tasks).get()).where((t) => !t.completed);
      expect(open, hasLength(1));
      await done(tester);
    });

    testWidgets('manual order: drag a task by its handle', (tester) async {
      final c = await repo.create(title: 'C task');
      await repo.create(title: 'B task');
      final a = await repo.create(title: 'A task');
      await pump(tester);
      final notifier = ProviderScope.containerOf(
        tester.element(find.byType(TaskListScreen)),
      ).read(taskQueryProvider.notifier);
      notifier.update((q) => q.copyWith(sort: TaskSort.manual));
      await tester.pumpAndSettle();

      // Drag "A task" (top) below "C task" (bottom).
      final handle = find.byKey(Key('drag-$a'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 300));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      // A one-shot query: a stream's .first would wait on a timer that the
      // test's fake clock never fires.
      final order =
          (await (db.select(
            db.tasks,
          )..orderBy([(t) => OrderingTerm.asc(t.sortKey)])).get()).map(
            (t) => t.title,
          );
      expect(order, ['B task', 'C task', 'A task']);
      expect(find.text('A task'), findsOneWidget);
      final keys = {
        for (final t in await db.select(db.tasks).get()) t.id: t.sortKey,
      };
      expect(keys[a]!.compareTo(keys[c]!), greaterThan(0));
      await done(tester);
    });
  });

  group('editor', () {
    testWidgets('unticking Done on an old repeat is refused', (tester) async {
      final a = await seriesWithTwoDone();
      await pump(tester, home: TaskEditScreen(taskId: a));
      final doneSwitch = find.byType(SwitchListTile);
      await tester.scrollUntilVisible(
        doneSwitch,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(doneSwitch);
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-task')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This repeat is already past. Reopen the latest one instead.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(doneSwitch).value, isTrue);
      expect(find.byType(TaskEditScreen), findsOneWidget, reason: 'not closed');
      expect((await repo.getById(a))!.completed, isTrue);
      await done(tester);
    });

    // Pulled rows come back from the server in UTC. The editor showed (and
    // the pickers started from) the UTC wall time. Only fails on a machine
    // whose time zone isn't UTC, like the emulator in IST it was found on.
    testWidgets('shows a pulled UTC deadline in local time', (tester) async {
      final due = DateTime.utc(2026, 10, 24, 3, 30);
      final id = await repo.create(title: 'Water the plants', dueAt: due);
      await pump(tester, home: TaskEditScreen(taskId: id));

      final format = DateFormat('EEE d MMM y, HH:mm');
      expect(find.text(format.format(due.toLocal())), findsOneWidget);
      if (due.toLocal().timeZoneOffset != Duration.zero) {
        expect(find.text(format.format(due)), findsNothing);
      }
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
