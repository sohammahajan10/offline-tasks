import 'package:drift/drift.dart';

import '../data/db/database.dart';
import '../data/sync/sync_engine.dart';

/// A task whose latest change has not reached the server.
class UnsyncedChange {
  const UnsyncedChange({
    required this.taskId,
    required this.title,
    required this.opType,
    required this.failed,
    this.lastError,
  });

  final String taskId;
  final String title;
  final String opType;

  /// Gave up after the maximum attempts (as opposed to waiting to retry).
  final bool failed;
  final String? lastError;
}

sealed class SignOutResult {
  const SignOutResult();
}

class SignedOut extends SignOutResult {
  const SignedOut();
}

/// Sign-out was NOT performed: these changes would be lost. The UI asks the
/// user, and calls [AccountService.signOut] with `discardUnsynced: true` only
/// if they confirm.
class UnsyncedChangesBlockSignOut extends SignOutResult {
  const UnsyncedChangesBlockSignOut(this.changes);

  final List<UnsyncedChange> changes;
}

/// Signing out wipes the local database (see [AppDatabase.clearAccountData]),
/// so it must never silently drop changes that only exist on this device.
class AccountService {
  AccountService(this._db, this._engine, {required this.signOutOfAuth});

  final AppDatabase _db;
  final SyncEngine _engine;

  /// Ends the Supabase session (`AuthRepository.signOut`).
  final Future<void> Function() signOutOfAuth;

  /// 1. Nothing queued → sign out.
  /// 2. Otherwise try to sync everything first (backoff timers ignored).
  /// 3. Anything still queued → return it and change nothing, unless the
  ///    user already confirmed with [discardUnsynced].
  Future<SignOutResult> signOut({bool discardUnsynced = false}) async {
    if (!discardUnsynced && await _hasQueuedChanges()) {
      await _engine.flush();
      final left = await unsyncedChanges();
      if (left.isNotEmpty) return UnsyncedChangesBlockSignOut(left);
    }
    // Under the sync lease, so a background sync can't write into the
    // database while it is cleared. Local data goes only once the session
    // has really ended.
    await _engine.runExclusive(() async {
      await signOutOfAuth();
      await _db.clearAccountData();
    });
    return const SignedOut();
  }

  /// One entry per task with changes still in the queue.
  Future<List<UnsyncedChange>> unsyncedChanges() async {
    final q = _db.select(_db.syncQueue).join([
      innerJoin(_db.tasks, _db.tasks.id.equalsExp(_db.syncQueue.taskId)),
    ])..orderBy([OrderingTerm.asc(_db.syncQueue.seq)]);
    final byTask = <String, UnsyncedChange>{};
    for (final row in await q.get()) {
      final op = row.readTable(_db.syncQueue);
      final task = row.readTable(_db.tasks);
      // Later entries for the same task overwrite earlier ones: newest state.
      byTask[task.id] = UnsyncedChange(
        taskId: task.id,
        title: task.title,
        opType: op.opType,
        failed: op.status == OpStatus.failed,
        lastError: op.lastError,
      );
    }
    return byTask.values.toList();
  }

  Future<bool> _hasQueuedChanges() async {
    final one = await (_db.select(_db.syncQueue)..limit(1)).getSingleOrNull();
    return one != null;
  }
}
