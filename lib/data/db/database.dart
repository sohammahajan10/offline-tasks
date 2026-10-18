import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Local copy of every task — the single source of truth for the UI.
@DataClassName('TaskRow')
class Tasks extends Table {
  TextColumn get id => text()(); // client-generated UUID v4
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get priority =>
      integer().withDefault(const Constant(1))(); // 0 low, 1 medium, 2 high
  DateTimeColumn get dueAt => dateTime().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get tags =>
      text().withDefault(const Constant('[]'))(); // JSON list of strings
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted =>
      boolean().withDefault(const Constant(false))(); // tombstone

  /// Server version this row is based on. 0 = the server has never seen it.
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  /// True while a change is waiting in [SyncQueue].
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Transactional outbox, written in the same transaction as the task change.
@DataClassName('SyncOp')
@TableIndex(name: 'idx_queue_task', columns: {#taskId})
@TableIndex(name: 'idx_queue_order', columns: {#status, #enqueuedAt})
class SyncQueue extends Table {
  TextColumn get opId => text()(); // idempotency key sent to the server
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get opType => text()(); // see OpType
  TextColumn get payloadJson => text()();
  IntColumn get baseVersion => integer()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  TextColumn get status =>
      text().withDefault(const Constant('pending'))(); // see OpStatus
  TextColumn get lastError => text().nullable()();

  /// Not in the original plan: gives the queue a stable FIFO order, since
  /// [opId] is a random UUID.
  DateTimeColumn get enqueuedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {opId};
}

abstract final class OpType {
  static const create = 'create';
  static const update = 'update';
  static const delete = 'delete';
}

abstract final class OpStatus {
  static const pending = 'pending';
  static const failed = 'failed';
}

@DriftDatabase(tables: [Tasks, SyncQueue])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? openDefault());

  static QueryExecutor openDefault() => driftDatabase(name: 'offline_tasks');

  // Bump this and run `dart run drift_dev make-migrations` for every schema
  // change, then add the step to [migration]. Never edit an old step.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Step-by-step upgrades are added here from schema version 2 on,
      // generated via `make-migrations` (database.steps.dart). Existing
      // rows are kept: no step may drop and recreate a table with data.
      throw StateError('No migration path from schema $from to $to');
    },
    beforeOpen: (details) async {
      // The foreground app and the WorkManager isolate can open the same file.
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
