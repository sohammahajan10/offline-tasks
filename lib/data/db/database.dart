import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../domain/fractional_index.dart';
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

  /// Wire JSON of the last server state this row was reconciled with: the
  /// common ancestor for the three-way field merge. Null until first synced.
  TextColumn get serverSnapshot => text().nullable()();

  /// Manual order: a fractional index key (see FractionalIndex). Ties are
  /// broken by id.
  TextColumn get sortKey => text().withDefault(const Constant(''))();

  /// 'daily' | 'weekly' | 'monthly', or null for a one-off task.
  TextColumn get recurrence => text().nullable()();

  /// Id shared by every occurrence of a recurring task (the first one's id).
  TextColumn get seriesId => text().nullable()();

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

/// Human-readable sync history, shown on the Sync log screen.
@DataClassName('SyncLogEntry')
class SyncLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();
  TextColumn get level => text()(); // see LogLevel
  TextColumn get message => text()();
  TextColumn get taskId => text().nullable()();
}

abstract final class LogLevel {
  static const info = 'info';

  /// Both sides changed the same field; resolved by last-writer-wins.
  static const conflict = 'conflict';
  static const error = 'error';
}

/// Small key-value store for sync bookkeeping (the pull cursor).
@DataClassName('SyncStateEntry')
class SyncState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Tasks, SyncQueue, SyncLog, SyncState])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? openDefault());

  // The WorkManager job runs in another isolate of the same process while the
  // app may be open. Drift only tells stream queries about writes made through
  // the same connection, so without sharing, a background pull never reached
  // the visible task list. Sharing routes every isolate through one connection.
  static QueryExecutor openDefault({String name = 'offline_tasks'}) =>
      driftDatabase(
        name: name,
        native: const DriftNativeOptions(shareAcrossIsolates: true),
      );

  // For every schema change: bump this, run `dart run drift_dev make-migrations`,
  // add the `fromNToM` step below and fill in the generated data test in
  // test/drift/. Never edit an old step: devices may already have run it.
  @override
  int get schemaVersion => 4;

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
      // v3: sync engine bookkeeping. Only additions, so no data moves.
      // Existing rows get a null snapshot and are treated as never synced.
      from2To3: (m, schema) async {
        await m.addColumn(schema.tasks, schema.tasks.serverSnapshot);
        await m.createTable(schema.syncLog);
        await m.createTable(schema.syncState);
      },
      // v4: manual order and recurring tasks. Existing rows get order keys
      // a0, a1, … by id, the same formula the server migration uses, so a
      // device's synced tasks get the keys the server assigns.
      from3To4: (m, schema) async {
        await m.addColumn(schema.tasks, schema.tasks.sortKey);
        await m.addColumn(schema.tasks, schema.tasks.recurrence);
        await m.addColumn(schema.tasks, schema.tasks.seriesId);
        final ids = await customSelect('SELECT id FROM tasks ORDER BY id')
            .map((r) => r.read<String>('id'))
            .get();
        String? key;
        for (final id in ids) {
          key = FractionalIndex.keyBetween(key, null);
          await customUpdate(
            'UPDATE tasks SET sort_key = ? WHERE id = ?',
            variables: [Variable(key), Variable(id)],
          );
        }
      },
    ),
    beforeOpen: (details) async {
      // The foreground app and the WorkManager isolate can open the same file.
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Removes everything tied to the signed-in account (on sign-out), in one
  /// transaction. Otherwise the next account to sign in on this device would
  /// pull into, and push from, the previous account's local data.
  Future<void> clearAccountData() => transaction(() async {
    await delete(syncQueue).go();
    await delete(tasks).go();
    await delete(syncLog).go();
    await delete(syncState).go();
  });

  Future<String?> readState(String key) async {
    final row = await (select(
      syncState,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeState(String key, String value) =>
      into(syncState)
          .insertOnConflictUpdate(SyncStateEntry(key: key, value: value));

  Future<void> log(
    String level,
    String message, {
    String? taskId,
    DateTime? at,
  }) => into(syncLog).insert(
    SyncLogCompanion.insert(
      at: at ?? DateTime.now(),
      level: level,
      message: message,
      taskId: Value(taskId),
    ),
  );
}
