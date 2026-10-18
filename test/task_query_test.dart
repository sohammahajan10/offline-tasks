import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_query.dart';
import 'package:offline_tasks/domain/task_repository.dart';

void main() {
  late AppDatabase db;
  late TaskRepository repo;
  var now = DateTime.utc(2026, 10, 19, 9);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = TaskRepository(
      db,
      clock: () => now = now.add(const Duration(minutes: 1)),
    );
  });

  tearDown(() => db.close());

  Future<List<String>> titles(TaskQuery q) async =>
      (await repo.watchTasks(q).first).map((t) => t.title).toList();

  Future<void> seed() async {
    await repo.create(
      title: 'Pay rent',
      priority: Priority.high,
      dueAt: DateTime.utc(2026, 10, 20),
      category: 'Home',
    );
    final milk = await repo.create(
      title: 'Buy milk',
      notes: 'Oat, 2 cartons',
      priority: Priority.low,
      category: 'Errands',
      tags: ['shopping'],
    );
    await repo.create(
      title: 'Write report',
      priority: Priority.medium,
      dueAt: DateTime.utc(2026, 10, 25),
      category: 'Work',
      tags: ['q4'],
    );
    final old = await repo.create(title: 'Old idea', category: 'Archive');
    await repo.setCompleted(milk, true);
    await repo.delete(old);
  }

  test('search matches title, notes, category and tags, any case', () async {
    await seed();
    expect(await titles(const TaskQuery(search: 'RENT')), ['Pay rent']);
    expect(await titles(const TaskQuery(search: 'oat')), ['Buy milk']);
    expect(await titles(const TaskQuery(search: 'work')), ['Write report']);
    expect(await titles(const TaskQuery(search: 'shopping')), ['Buy milk']);
    expect(
      await titles(const TaskQuery(search: 'idea')),
      isEmpty,
      reason: 'deleted tasks never show',
    );
  });

  test('% and _ in the search text match literally', () async {
    await repo.create(title: '100% done');
    await repo.create(title: '1000 done');
    await repo.create(title: 'snake_case');
    await repo.create(title: 'snakeXcase');
    expect(await titles(const TaskQuery(search: '0%')), ['100% done']);
    expect(await titles(const TaskQuery(search: 'e_c')), ['snake_case']);
  });

  test('filters by status, priority and category, combined', () async {
    await seed();
    expect(await titles(const TaskQuery(status: StatusFilter.done)), [
      'Buy milk',
    ]);
    expect(await titles(const TaskQuery(status: StatusFilter.pending)), [
      'Pay rent',
      'Write report',
    ]);
    expect(await titles(const TaskQuery(priority: Priority.medium)), [
      'Write report',
    ]);
    expect(await titles(const TaskQuery(category: 'Home')), ['Pay rent']);
    expect(
      await titles(
        const TaskQuery(status: StatusFilter.pending, category: 'Errands'),
      ),
      isEmpty,
    );
  });

  test('sort orders', () async {
    await seed();
    expect(await titles(const TaskQuery()), [
      'Pay rent',
      'Write report',
      'Buy milk', // done goes last
    ]);
    expect(await titles(const TaskQuery(sort: TaskSort.priority)), [
      'Pay rent',
      'Write report',
      'Buy milk',
    ]);
    expect(await titles(const TaskQuery(sort: TaskSort.dueDate)), [
      'Pay rent',
      'Write report',
      'Buy milk', // no deadline last
    ]);
    expect(await titles(const TaskQuery(sort: TaskSort.recent)), [
      'Buy milk', // completed most recently
      'Write report',
      'Pay rent',
    ]);
  });

  test('categories in use exclude deleted tasks', () async {
    await seed();
    expect(await repo.watchCategories().first, ['Errands', 'Home', 'Work']);
  });

  test(
    'sync states: failed wins over pending, synced tasks have none',
    () async {
      final a = await repo.create(title: 'A');
      final b = await repo.create(title: 'B');
      final c = await repo.create(title: 'C');
      await (db.update(db.syncQueue)..where((q) => q.taskId.equals(b))).write(
        const SyncQueueCompanion(status: Value(OpStatus.failed)),
      );
      await (db.delete(db.syncQueue)..where((q) => q.taskId.equals(c))).go();

      expect(await repo.watchSyncStates().first, {
        a: TaskSyncState.pending,
        b: TaskSyncState.failed,
      });
    },
  );

  test('localWrites fires once per committed write', () async {
    final events = <void>[];
    final sub = repo.localWrites.listen(events.add);
    final id = await repo.create(title: 'x');
    await repo.setCompleted(id, true);
    await expectLater(repo.setCompleted('missing', true), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2), reason: 'a failed write does not fire');
    await sub.cancel();
  });
}
