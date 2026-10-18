import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'reminders.dart';

/// [ReminderGateway] backed by flutter_local_notifications.
///
/// * POST_NOTIFICATIONS (Android 13+) is requested at runtime, the first
///   time the user saves a task with a deadline.
/// * Exact alarms are used only if the system already allows them
///   (SCHEDULE_EXACT_ALARM, off by default on Android 14+); otherwise
///   inexact, which Android may delay by a few minutes to save battery.
/// * After a reboot the plugin's ScheduledNotificationBootReceiver
///   reschedules what was pending (see AndroidManifest.xml), and the next app
///   start or background sync reconciles again.
class LocalNotificationsGateway implements ReminderGateway {
  LocalNotificationsGateway._();

  static final instance = LocalNotificationsGateway._();
  final _plugin = FlutterLocalNotificationsPlugin();
  var _initialized = false;

  static const _channel = AndroidNotificationDetails(
    'deadlines',
    'Deadlines',
    channelDescription: 'A reminder when a task is due',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// [onOpen] gets the task id when the user taps a reminder.
  Future<void> initialize({void Function(String taskId)? onOpen}) async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final id = Reminder.taskIdFromPayload(response.payload);
        if (id != null) onOpen?.call(id);
      },
    );
    _initialized = true;
  }

  /// The task id of the reminder that launched the app, if any.
  Future<String?> launchTaskId() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return Reminder.taskIdFromPayload(details!.notificationResponse?.payload);
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Asks for POST_NOTIFICATIONS if not decided yet. True if allowed.
  Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? true;

  @override
  Future<List<({int id, String? payload})>> scheduled() async => [
    for (final p in await _plugin.pendingNotificationRequests())
      (id: p.id, payload: p.payload),
  ];

  @override
  Future<void> schedule(Reminder reminder) async {
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      id: reminder.id,
      title: 'Due now',
      body: reminder.title,
      // An absolute instant, so UTC needs no time zone database lookup.
      scheduledDate: tz.TZDateTime.from(reminder.at, tz.UTC),
      notificationDetails: const NotificationDetails(android: _channel),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: reminder.payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
