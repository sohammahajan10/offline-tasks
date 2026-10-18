import 'dart:async';
import 'dart:convert';

import '../../domain/task.dart';

/// A deadline notification for one task.
class Reminder {
  const Reminder({required this.taskId, required this.title, required this.at});

  final String taskId;
  final String title;
  final DateTime at;

  /// Stable per task, so rescheduling replaces rather than duplicates.
  int get id => notificationId(taskId);

  /// Stored with the scheduled notification; a different payload means the
  /// deadline or title changed and the notification must be replaced.
  String get payload => jsonEncode({
    'task': taskId,
    'at': at.toUtc().toIso8601String(),
    'title': title,
  });

  static int notificationId(String taskId) =>
      int.parse(taskId.replaceAll('-', '').substring(0, 7), radix: 16);

  static String? taskIdFromPayload(String? payload) {
    if (payload == null) return null;
    try {
      return (jsonDecode(payload) as Map)['task'] as String?;
    } on FormatException {
      return null;
    }
  }
}

/// What the reconciler needs from the notification system.
abstract interface class ReminderGateway {
  /// Notifications currently scheduled: id and payload.
  Future<List<({int id, String? payload})>> scheduled();
  Future<void> schedule(Reminder reminder);
  Future<void> cancel(int id);
}

/// Makes the scheduled notifications match the tasks.
///
/// Every source of change (a local edit, a pull from another device, a
/// background sync, app start after a reboot) ends up as rows in the local
/// database, so reconciling against the database covers them all: a pull
/// that moves a deadline reschedules, one that completes or deletes a task
/// cancels.
class ReminderReconciler {
  ReminderReconciler(
    this.gateway, {
    DateTime Function()? clock,
    this.limit = 50,
  }) : _clock = clock ?? DateTime.now;

  final ReminderGateway gateway;
  final DateTime Function() _clock;

  /// Android caps pending alarms per app; the soonest [limit] are scheduled
  /// and later ones get theirs as earlier deadlines pass.
  final int limit;

  Future<({int scheduled, int cancelled})> reconcile(
    Iterable<TaskItem> tasks,
  ) async {
    final now = _clock();
    final due =
        tasks
            .where(
              (t) =>
                  !t.completed &&
                  !t.isDeleted &&
                  t.dueAt != null &&
                  t.dueAt!.isAfter(now),
            )
            .toList()
          ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    final wanted = {
      for (final t in due.take(limit))
        Reminder.notificationId(t.id): Reminder(
          taskId: t.id,
          title: t.title,
          at: t.dueAt!,
        ),
    };

    final existing = {
      for (final s in await gateway.scheduled()) s.id: s.payload,
    };
    var cancelled = 0;
    for (final MapEntry(key: id, value: payload) in existing.entries) {
      if (wanted[id]?.payload != payload) {
        await gateway.cancel(id);
        cancelled++;
      }
    }
    var scheduled = 0;
    for (final r in wanted.values) {
      if (existing[r.id] != r.payload) {
        await gateway.schedule(r);
        scheduled++;
      }
    }
    return (scheduled: scheduled, cancelled: cancelled);
  }
}

/// Keeps reminders in step with a stream of the task list (debounced).
class ReminderSync {
  ReminderSync(
    this.reconciler,
    Stream<List<TaskItem>> tasks, {
    Duration debounce = const Duration(milliseconds: 500),
  }) {
    _sub = tasks.listen((list) {
      _latest = list;
      _timer?.cancel();
      _timer = Timer(debounce, _run);
    });
  }

  final ReminderReconciler reconciler;
  late final StreamSubscription<List<TaskItem>> _sub;
  Timer? _timer;
  List<TaskItem>? _latest;
  Future<void>? _running;

  Future<void> _run() async {
    // One reconcile at a time; the latest list wins.
    await _running;
    final list = _latest;
    if (list == null) return;
    _running = reconciler.reconcile(list).then((_) {}, onError: (_) {});
    await _running;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _sub.cancel();
  }
}
