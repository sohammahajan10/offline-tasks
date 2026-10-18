// Runs on a real Android device/emulator:
//   flutter test integration_test/persistence_test.dart -d <device-id>
//
// Proves the SQLite bundled by package:sqlite3 3.x loads on Android (we don't
// use sqlite3_flutter_libs) and that tasks plus their outbox entries are on
// disk, not just in memory, when the database is reopened.
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_repository.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // A separate file so the test never touches the app's real database.
  final dbName = 'it_persistence_${DateTime.now().microsecondsSinceEpoch}';

  tearDownAll(() async {
    final dir = await getApplicationDocumentsDirectory();
    for (final name in [dbName, '${dbName}_shared']) {
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('${dir.path}/$name.sqlite$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    }
  });

  testWidgets('bundled SQLite works and data survives reopening', (_) async {
    final first = AppDatabase(driftDatabase(name: dbName));
    final version = await first
        .customSelect('SELECT sqlite_version() AS v')
        .map((r) => r.read<String>('v'))
        .getSingle();
    // ignore: avoid_print
    print('Bundled SQLite version on device: $version');

    final journal = await first
        .customSelect('PRAGMA journal_mode')
        .map((r) => r.data.values.first.toString())
        .getSingle();
    expect(journal.toLowerCase(), 'wal');

    final repo = TaskRepository(first);
    final keep = await repo.create(
      title: 'Survives restart',
      priority: Priority.high,
      dueAt: DateTime.utc(2026, 12, 24, 18, 0, 0, 250),
      category: 'Home',
      tags: ['gift'],
    );
    final gone = await repo.create(title: 'Deleted offline');
    await repo.setCompleted(keep, true);
    await repo.delete(gone);
    await first.close();

    final dir = await getApplicationDocumentsDirectory();
    expect(
      File('${dir.path}/$dbName.sqlite').existsSync(),
      isTrue,
      reason: 'database must live in a file on the device',
    );

    final second = AppDatabase(driftDatabase(name: dbName));
    final repo2 = TaskRepository(second);

    final visible = await repo2.watchAll().first;
    expect(visible.map((t) => t.title), ['Survives restart']);
    final task = visible.single;
    expect(task.completed, isTrue);
    expect(task.priority, Priority.high);
    expect(task.tags, ['gift']);
    expect(task.dueAt!.toUtc(), DateTime.utc(2026, 12, 24, 18, 0, 0, 250));
    expect(task.dirty, isTrue);
    expect((await repo2.getById(gone))!.isDeleted, isTrue);

    final ops = await second.select(second.syncQueue).get();
    expect(ops.map((o) => o.taskId).toSet(), {keep, gone});
    expect(ops.firstWhere((o) => o.taskId == gone).opType, OpType.delete);

    await second.close();
  });

  // The WorkManager job writes from another isolate while the app is open.
  // Its writes must reach the UI's stream queries, or a background pull leaves
  // the visible list stale until the app restarts.
  testWidgets('writes from another isolate update open streams', (_) async {
    final name = '${dbName}_shared';
    final ui = AppDatabase(AppDatabase.openDefault(name: name));
    final stream = TaskRepository(ui).watchAll();
    final emitted = <List<String>>[];
    final sub = stream.listen((l) => emitted.add([for (final t in l) t.title]));
    Future<void> until(bool Function() done) => Future.doWhile(() async {
      if (done()) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return true;
    }).timeout(const Duration(seconds: 5));

    await until(() => emitted.isNotEmpty);
    expect(emitted.last, isEmpty);

    // The WorkManager isolate has platform channels (drift_flutter asks
    // path_provider for a temp dir); a plain isolate needs the messenger.
    final token = RootIsolateToken.instance!;
    await Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      final background = AppDatabase(AppDatabase.openDefault(name: name));
      await TaskRepository(background).create(title: 'Pulled in background');
      await background.close();
    });

    await until(() => emitted.last.contains('Pulled in background'));
    await sub.cancel();
    await ui.close();
  });
}
