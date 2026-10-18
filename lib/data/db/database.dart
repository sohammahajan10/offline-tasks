import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'database.steps.dart';

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
@TableIndex(name: 'idx_queue_status', columns: {#status})
class SyncQueue extends Table {
  /// Drain order. AUTOINCREMENT never reuses a value, and unlike a wall-clock
  /// timestamp it cannot tie or go backwards when the phone's clock changes.
  IntColumn get seq => integer().autoIncrement()();

  /// Idempotency key sent to the server.
  TextColumn get opId => text().unique()();
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get opType => text()(); // see OpType
  TextColumn get payloadJson => text()();
  IntColumn get baseVersion => integer()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  TextColumn get status =>
      text().withDefault(const Constant('pending'))(); // see OpStatus
  TextColumn get lastError => text().nullable()();
}

abstract final class OpType {
  static const create = 'create';
  static const update = 'update';
  static const delete = 'delete';
}

abstract final class OpStatus {
  static const pending = 'pending';

  /// Being pushed right now. Never merged into: an edit that arrives
  /// meanwhile gets its own entry, or it would be lost when this one is acked.
  static const inFlight = 'in_flight';

  /// Gave up after [Backoff.maxAttempts]; retried manually from the UI.
  static const failed = 'failed';
}

@DriftDatabase(tables: [Tasks, SyncQueue])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? openDefault());

  static QueryExecutor openDefault() => driftDatabase(name: 'offline_tasks');

  // For every schema change: bump this, run `dart run drift_dev make-migrations`,
  // add the `fromNToM` step below and fill in the generated data test in
  // test/drift/. Never edit an old step: devices may already have run it.
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: stepByStep(
      // v2: the queue is drained by an AUTOINCREMENT `seq` instead of the
      // wall-clock `enqueued_at`. AUTOINCREMENT must be the INTEGER PRIMARY
      // KEY, so the table is rebuilt; existing entries keep their insertion
      // order through their rowid. `op_id` becomes a UNIQUE column.
      from1To2: (m, schema) async {
        // alterTable re-creates the old indexes, and this one names the
        // dropped column.
        await customStatement('DROP INDEX IF EXISTS idx_queue_order');
        await m.alterTable(
          TableMigration(
            schema.syncQueue,
            columnTransformer: {
              schema.syncQueue.seq: const CustomExpression<int>('rowid'),
            },
            newColumns: [schema.syncQueue.seq],
          ),
        );
        await m.create(schema.idxQueueStatus);
      },
    ),
    beforeOpen: (details) async {
      // The foreground app and the WorkManager isolate can open the same file.
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
