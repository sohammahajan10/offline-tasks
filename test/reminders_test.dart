import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/notifications/reminders.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_query.dart';
import 'package:offline_tasks/domain/task_repository.dart';

import 'support/fake_remote_api.dart';

/// Records what would be scheduled with the OS.
class FakeGateway implements ReminderGateway {
  final pending = <int, Reminder>{};
  var scheduleCalls = 0;
  var cancelCalls = 0;

  @override
  Future<List<({int id, String? payload})>> scheduled() async => [
    for (final r in pending.values) (id: r.id, payload: r.payload),
  ];

  @override
  Future<void> schedule(Reminder reminder) async {
    scheduleCalls++;
    pending[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    cancelCalls++;
    pending.remove(id);
  }

  Reminder? forTask(String taskId) => pending[Reminder.notificationId(taskId)];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final now = DateTime.utc(2026, 10, 19, 9);

  TaskItem task(
    String id, {
    DateTime? due,
    bool completed = false,
    bool deleted = false,
    String title = 'Task',
  }) => TaskItem(
    id: id,
    title: title,
    dueAt: due,
    completed: completed,
    isDeleted: deleted,
    updatedAt: now,
  );

  group('ReminderReconciler', () {
    late FakeGateway gateway;
    late ReminderReconciler reconciler;
    setUp(() {
      gateway = FakeGateway();
      reconciler = ReminderReconciler(gateway, clock: () => now, limit: 3);
    });

    const a = '0a000000-0000-4000-8000-000000000001';
    const b = '0b000000-0000-4000-8000-000000000002';
    const c = '0c000000-0000-4000-8000-000000000003';

    test('schedules future deadlines of open tasks only', () async {
      await reconciler.reconcile([
        task(a, due: now.add(const Duration(hours: 1))),
        task(b, due: now.subtract(const Duration(hours: 1))), // past
        task(c, due: now.add(const Duration(hours: 2)), completed: true),
        task('0d000000-0000-4000-8000-000000000004'), // no deadline
      ]);
      expect(gateway.pending.keys, [Reminder.notificationId(a)]);
      expect(gateway.forTask(a)!.at, now.add(const Duration(hours: 1)));
    });

    test('a second run with nothing changed does nothing', () async {
      final tasks = [task(a, due: now.add(const Duration(hours: 1)))];
      await reconciler.reconcile(tasks);
      final result = await reconciler.reconcile(tasks);
      expect(result, (scheduled: 0, cancelled: 0));
    });

    test('a changed deadline or title replaces the notification', () async {
      await reconciler.reconcile([
        task(a, due: now.add(const Duration(hours: 1))),
      ]);
      await reconciler.reconcile([
        task(a, due: now.add(const Duration(hours: 5)), title: 'Renamed'),
      ]);
      expect(gateway.pending, hasLength(1));
      expect(gateway.forTask(a)!.at, now.add(const Duration(hours: 5)));
      expect(gateway.forTask(a)!.title, 'Renamed');
    });

    test('completed, deleted or vanished tasks are cancelled', () async {
      await reconciler.reconcile([
        task(a, due: now.add(const Duration(hours: 1))),
        task(b, due: now.add(const Duration(hours: 2))),
        task(c, due: now.add(const Duration(hours: 3))),
      ]);
      await reconciler.reconcile([
        task(a, due: now.add(const Duration(hours: 1)), completed: true),
        task(b, due: now.add(const Duration(hours: 2)), deleted: true),
      ]);
      expect(gateway.pending, isEmpty);
    });

    test('only the soonest [limit] are scheduled', () async {
      await reconciler.reconcile([
        for (var i = 1; i <= 5; i++)
          task(
            '0${i}000000-0000-4000-8000-00000000000$i',
            due: now.add(Duration(hours: 6 - i)),
          ),
      ]);
      expect(gateway.pending, hasLength(3));
      expect(
        gateway.pending.values
            .map((r) => r.at)
            .reduce((x, y) => x.isAfter(y) ? x : y),
        now.add(const Duration(hours: 3)),
      );
    });

    test('notification ids are stable per task and positive', () {
      expect(Reminder.notificationId(a), Reminder.notificationId(a));
      expect(Reminder.notificationId(a), isNot(Reminder.notificationId(b)));
      expect(Reminder.notificationId('ffffffff-ffff'), greaterThan(0));
      expect(
        Reminder.taskIdFromPayload(
          Reminder(taskId: a, title: 't', at: now).payload,
        ),
        a,
      );
      expect(Reminder.taskIdFromPayload('garbage'), isNull);
    });
  });

  group('reminders follow pulls from another device', () {
    late FakeRemoteApi server;
    late AppDatabase phone;
    late AppDatabase laptop;
    late TaskRepository phoneRepo;
    late TaskRepository laptopRepo;
    late FakeGateway gateway;
    late ReminderSync reminders;

    // Real wall clock here: ReminderSync debounces with real timers.
    final due = DateTime.now().toUtc().add(const Duration(days: 2));

    setUp(() async {
      server = FakeRemoteApi();
      phone = AppDatabase(NativeDatabase.memory());
      laptop = AppDatabase(NativeDatabase.memory());
      phoneRepo = TaskRepository(phone);
      laptopRepo = TaskRepository(laptop);
      gateway = FakeGateway();
      reminders = ReminderSync(
        ReminderReconciler(gateway),
        phoneRepo.watchTasks(const TaskQuery()),
        debounce: const Duration(milliseconds: 20),
      );
    });

    tearDown(() async {
      await reminders.dispose();
      await phone.close();
      await laptop.close();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));
    Future<void> phoneSync() async {
      await SyncEngine(phone, server).sync();
      await settle();
    }

    Future<String> sharedTask() async {
      final id = await laptopRepo.create(title: 'Submit report', dueAt: due);
      await SyncEngine(laptop, server).sync();
      await phoneSync();
      expect(gateway.forTask(id)!.at, due, reason: 'pulled task scheduled');
      return id;
    }

    test('a pulled deadline change reschedules', () async {
      final id = await sharedTask();
      final later = due.add(const Duration(hours: 3));
      await laptopRepo.update(id, TaskPatch(dueAt: later));
      await SyncEngine(laptop, server).sync();

      await phoneSync();
      expect(gateway.forTask(id)!.at.toUtc(), later);
      expect(gateway.pending, hasLength(1));
    });

    test('a pulled completion cancels', () async {
      final id = await sharedTask();
      await laptopRepo.setCompleted(id, true);
      await SyncEngine(laptop, server).sync();

      await phoneSync();
      expect(gateway.forTask(id), isNull);
    });

    test('a pulled delete cancels', () async {
      final id = await sharedTask();
      await laptopRepo.delete(id);
      await SyncEngine(laptop, server).sync();

      await phoneSync();
      expect(gateway.pending, isEmpty);
    });
  });
}
