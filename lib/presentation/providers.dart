import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/api/auth_repository.dart';
import '../data/api/supabase_config.dart';
import '../data/api/supabase_remote_api.dart';
import '../data/db/database.dart';
import '../data/sync/background_sync.dart';
import '../data/sync/connectivity_monitor.dart';
import '../data/sync/sync_coordinator.dart';
import '../data/sync/sync_engine.dart';
import '../domain/account_service.dart';
import '../domain/sync_log_repository.dart';
import '../domain/task.dart';
import '../domain/task_query.dart';
import '../domain/task_repository.dart';

// ------------------------------------------------------------------ data

/// Overridden in main() with the opened database (and in tests with an
/// in-memory one).
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final taskRepositoryProvider = Provider(
  (ref) => TaskRepository(ref.watch(databaseProvider)),
);

final syncLogRepositoryProvider = Provider(
  (ref) => SyncLogRepository(ref.watch(databaseProvider)),
);

/// False without Supabase keys: the app is then fully usable, local only.
final syncConfiguredProvider = Provider<bool>(
  (ref) => SupabaseConfig.isConfigured,
);

final supabaseClientProvider = Provider<SupabaseClient?>(
  (ref) => ref.watch(syncConfiguredProvider) ? Supabase.instance.client : null,
);

final authRepositoryProvider = Provider<AuthRepository?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : AuthRepository(client.auth);
});

class Account {
  const Account({required this.id, this.email});
  final String id;
  final String? email;
}

/// The signed-in account, or null (signed out or local only).
final accountProvider = StreamProvider<Account?>((ref) async* {
  final auth = ref.watch(authRepositoryProvider);
  if (auth == null) {
    yield null;
    return;
  }
  Account? toAccount(User? u) =>
      u == null ? null : Account(id: u.id, email: u.email);
  yield toAccount(auth.currentUser);
  yield* auth.userChanges.map(toAccount);
});

final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return null;
  return SyncEngine(ref.watch(databaseProvider), SupabaseRemoteApi(client));
});

final accountServiceProvider = Provider<AccountService?>((ref) {
  final engine = ref.watch(syncEngineProvider);
  final auth = ref.watch(authRepositoryProvider);
  if (engine == null || auth == null) return null;
  return AccountService(
    ref.watch(databaseProvider),
    engine,
    signOutOfAuth: auth.signOut,
  );
});

// ----------------------------------------------------------- connectivity

final connectivityProvider = Provider<ConnectivityMonitor>((ref) {
  final monitor = ConnectivityMonitor.forSupabase(
    url: SupabaseConfig.isConfigured ? SupabaseConfig.url : null,
    anonKey: SupabaseConfig.anonKey,
  );
  monitor.start();
  ref.onDispose(monitor.dispose);
  return monitor;
});

final networkStatusProvider = StreamProvider<NetworkStatus>(
  (ref) => ref.watch(connectivityProvider).statusStream,
);

// ------------------------------------------------------------------- sync

final syncCoordinatorProvider = Provider<SyncCoordinator?>((ref) {
  final engine = ref.watch(syncEngineProvider);
  final client = ref.watch(supabaseClientProvider);
  if (engine == null || client == null) return null;
  final coordinator = SyncCoordinator(
    engine: engine,
    connectivity: ref.watch(connectivityProvider),
    localWrites: ref.watch(taskRepositoryProvider).localWrites,
    nextRetryAt: ref.watch(syncLogRepositoryProvider).nextRetryAt,
    isSignedIn: () => client.auth.currentUser != null,
  )..start();
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final coordinator = ref.watch(syncCoordinatorProvider);
  return coordinator?.statusStream ?? Stream.value(const SyncStatus());
});

/// Hands the queue to WorkManager when the app is backgrounded.
final backgroundFlushProvider = Provider<Future<void> Function()>(
  (ref) => BackgroundSync.scheduleFlush,
);

/// Tasks with changes the server hasn't acknowledged.
final pendingCountProvider = StreamProvider<int>(
  (ref) => ref.watch(taskRepositoryProvider).watchPendingCount(),
);

final failedCountProvider = StreamProvider<int>(
  (ref) => ref.watch(syncLogRepositoryProvider).watchFailedCount(),
);

final syncStatesProvider = StreamProvider<Map<String, TaskSyncState>>(
  (ref) => ref.watch(taskRepositoryProvider).watchSyncStates(),
);

final syncLogProvider = StreamProvider<List<SyncLogEntry>>(
  (ref) => ref.watch(syncLogRepositoryProvider).watchLog(),
);

final queueProvider = StreamProvider<List<QueuedChange>>(
  (ref) => ref.watch(syncLogRepositoryProvider).watchQueue(),
);

// ------------------------------------------------------------------ tasks

class TaskQueryNotifier extends Notifier<TaskQuery> {
  @override
  TaskQuery build() => const TaskQuery();

  void update(TaskQuery Function(TaskQuery q) change) => state = change(state);

  void clearFilters() => state = state.cleared();
}

final taskQueryProvider = NotifierProvider<TaskQueryNotifier, TaskQuery>(
  TaskQueryNotifier.new,
);

final tasksProvider = StreamProvider<List<TaskItem>>(
  (ref) => ref
      .watch(taskRepositoryProvider)
      .watchTasks(ref.watch(taskQueryProvider)),
);

/// Whether any task exists at all, to tell "no tasks yet" from "no matches".
final hasTasksProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(taskRepositoryProvider)
      .watchTasks(const TaskQuery())
      .map((tasks) => tasks.isNotEmpty),
);

final categoriesProvider = StreamProvider<List<String>>(
  (ref) => ref.watch(taskRepositoryProvider).watchCategories(),
);

final taskByIdProvider = StreamProvider.family<TaskItem?, String>(
  (ref, id) => ref.watch(taskRepositoryProvider).watchById(id),
);
