import 'dart:math';

import 'package:uuid/uuid.dart';

enum Recurrence {
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly');

  const Recurrence(this.label);
  final String label;

  static Recurrence? parse(String? value) =>
      values.where((r) => r.name == value).firstOrNull;

  /// The next due time after [due].
  ///
  /// Computed in UTC so every device, in any time zone, gets the same instant
  /// (and therefore the same id for the next occurrence). Trade-off: across a
  /// daylight-saving change the local wall-clock time shifts by an hour.
  /// Monthly keeps the day of month, clamped to the month's length
  /// (Jan 31 → Feb 28/29 → Mar 28 …, as the clamped day carries forward).
  DateTime next(DateTime due) {
    final u = due.toUtc();
    return switch (this) {
      Recurrence.daily => u.add(const Duration(days: 1)),
      Recurrence.weekly => u.add(const Duration(days: 7)),
      Recurrence.monthly => () {
        final firstOfNext = DateTime.utc(u.year, u.month + 1);
        final lastDay = DateTime.utc(
          firstOfNext.year,
          firstOfNext.month + 1,
          0,
        ).day;
        return DateTime.utc(
          firstOfNext.year,
          firstOfNext.month,
          min(u.day, lastDay),
          u.hour,
          u.minute,
          u.second,
          u.millisecond,
        );
      }(),
    };
  }
}

/// Fixed namespace for occurrence ids (a random v4, generated once).
const _occurrenceNamespace = '6f1d6c2e-3b5a-4c8e-9d27-7a2f4e1b9c03';

/// Id of the occurrence of series [seriesId] due at [due]: a UUIDv5, so two
/// devices that complete the same occurrence offline both create the *same*
/// next task, and sync merges them into one instead of duplicating it.
String occurrenceId(String seriesId, DateTime due) => const Uuid().v5(
  _occurrenceNamespace,
  '$seriesId/${due.toUtc().toIso8601String()}',
);
