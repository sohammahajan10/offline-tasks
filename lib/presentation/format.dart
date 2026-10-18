import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/task.dart';

/// "Today 14:30", "Tomorrow 09:00", "Mon 20 Oct", "20 Oct 2027".
String formatDue(DateTime due, {DateTime? now}) {
  final local = due.toLocal();
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(local);
  final time = DateFormat.Hm().format(local);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today $time';
  if (diff == 1) return 'Tomorrow $time';
  if (diff == -1) return 'Yesterday $time';
  if (diff.abs() < 7) return '${DateFormat.E().format(local)} $time';
  if (local.year == today.year) return DateFormat('d MMM').format(local);
  return DateFormat('d MMM y').format(local);
}

/// "just now", "5 min ago", "3 h ago", "18 Oct 09:12".
String formatAgo(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return DateFormat('d MMM HH:mm').format(t.toLocal());
}

Color priorityColor(Priority p, ColorScheme scheme) => switch (p) {
  Priority.high => scheme.error,
  Priority.medium => scheme.tertiary,
  Priority.low => scheme.outline,
};

IconData priorityIcon(Priority p) => switch (p) {
  Priority.high => Icons.keyboard_double_arrow_up,
  Priority.medium => Icons.drag_handle,
  Priority.low => Icons.keyboard_arrow_down,
};
