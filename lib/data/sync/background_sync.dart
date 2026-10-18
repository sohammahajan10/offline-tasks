import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../api/supabase_config.dart';
import '../api/supabase_remote_api.dart';
import '../../domain/task_query.dart';
import '../../domain/task_repository.dart';
import '../db/database.dart';
import '../notifications/local_notifications_gateway.dart';
import '../notifications/reminders.dart';
import 'sync_engine.dart';

const _syncTask = 'offline_tasks.sync';
const _periodicName = 'offline_tasks.periodic_sync';
const _pendingName = 'offline_tasks.pending_sync';

/// Entry point of the WorkManager isolate. It shares nothing with the app's
/// isolate but the database file, so it opens its own connection and Supabase
/// client; the sync lease in the database keeps the two from syncing at once.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (!SupabaseConfig.isConfigured) return true;
    final db = AppDatabase();
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.anonKey,
        postgrestOptions: SupabaseConfig.postgrestOptions,
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      );
      final api = SupabaseRemoteApi(Supabase.instance.client);
      final report = await SyncEngine(db, api).sync();
      debugPrint('Background sync ($task): $report');
      // A pull may have moved, completed or deleted tasks: update reminders.
      // (Also runs after a reboot, via the periodic job.)
      final gateway = LocalNotificationsGateway.instance;
      await gateway.initialize();
      final tasks = await TaskRepository(db)
          .watchTasks(const TaskQuery())
          .first;
      final changed = await ReminderReconciler(gateway).reconcile(tasks);
      debugPrint('Background reminders: $changed');
      // false asks WorkManager to retry this run later with its own backoff;
      // a skipped run (signed out, lease held by the app) is not a failure.
      return report.error == null;
    } catch (e) {
      debugPrint('Background sync failed: $e');
      return false;
    } finally {
      await db.close();
    }
  });
}

/// Registers the WorkManager jobs. Safe to call on every launch.
class BackgroundSync {
  static Future<void> initialize() async {
    if (!SupabaseConfig.isConfigured) return;
    await Workmanager().initialize(backgroundSyncDispatcher);
    // Catches other devices' changes and anything left over, even if the app
    // is never opened. 15 minutes is Android's minimum period.
    await Workmanager().registerPeriodicTask(
      _periodicName,
      _syncTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Called when the app goes to the background with changes still queued:
  /// WorkManager runs it as soon as there is a network, even if the app has
  /// been killed by then.
  static Future<void> scheduleFlush() async {
    if (!SupabaseConfig.isConfigured) return;
    await Workmanager().registerOneOffTask(
      _pendingName,
      _syncTask,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }
}
