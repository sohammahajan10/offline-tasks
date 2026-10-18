import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/api/supabase_config.dart';
import 'data/db/database.dart';
import 'data/notifications/local_notifications_gateway.dart';
import 'data/sync/background_sync.dart';
import 'presentation/app.dart';
import 'presentation/providers.dart';

/// Run with sync:    flutter run --dart-define-from-file=.env
/// Run local only:   flutter run
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (SupabaseConfig.isConfigured) {
    // Restores a saved session from disk; works offline.
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.anonKey,
      postgrestOptions: SupabaseConfig.postgrestOptions,
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
    );
    try {
      await BackgroundSync.initialize();
    } catch (e) {
      // Background sync is a bonus; the app syncs in the foreground anyway.
      debugPrint('WorkManager unavailable: $e');
    }
  }

  final reminders = LocalNotificationsGateway.instance;
  await reminders.initialize(onOpen: openTaskFromReminder);

  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(AppDatabase())],
      child: const OfflineTasksApp(),
    ),
  );

  // Opened by tapping a reminder while the app wasn't running.
  final launchedFor = await reminders.launchTaskId();
  if (launchedFor != null) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => openTaskFromReminder(launchedFor),
    );
  }
}
