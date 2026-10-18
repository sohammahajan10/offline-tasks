import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'screens/task_edit_screen.dart';
import 'screens/task_list_screen.dart';

/// Lets a tapped reminder open its task from outside the widget tree.
final appNavigatorKey = GlobalKey<NavigatorState>();

void openTaskFromReminder(String taskId) => appNavigatorKey.currentState?.push(
  MaterialPageRoute(builder: (_) => TaskEditScreen(taskId: taskId)),
);

class OfflineTasksApp extends ConsumerStatefulWidget {
  const OfflineTasksApp({super.key});

  @override
  ConsumerState<OfflineTasksApp> createState() => _OfflineTasksAppState();
}

class _OfflineTasksAppState extends ConsumerState<OfflineTasksApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(ref.read(syncCoordinatorProvider)?.onResume()),
      // Leaving with changes queued: hand them to WorkManager, which uploads
      // them once there is a network, even if Android kills the app.
      onHide: () {
        final pending = ref.read(pendingCountProvider).value ?? 0;
        if (pending > 0 && ref.read(accountProvider).value != null) {
          unawaited(ref.read(backgroundFlushProvider)());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Start syncing as soon as the app runs, and right after signing in
    // (that also uploads tasks created before there was an account).
    ref.watch(syncCoordinatorProvider);
    ref.watch(reminderSyncProvider);
    ref.listen(accountProvider, (previous, next) {
      if (previous?.value == null && next.value != null) {
        unawaited(ref.read(syncCoordinatorProvider)?.syncNow());
      }
    });

    return MaterialApp(
      title: 'Offline Tasks',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const TaskListScreen(),
    );
  }

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E6B5E),
      brightness: brightness,
    ),
    useMaterial3: true,
  );
}
