import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/recurrence.dart';
import '../../domain/task.dart';
import 'database.dart';

TaskItem rowToItem(TaskRow r) => TaskItem(
  id: r.id,
  title: r.title,
  notes: r.notes,
  priority: Priority.values[r.priority.clamp(0, Priority.values.length - 1)],
  dueAt: r.dueAt,
  category: r.category,
  tags: decodeTags(r.tags),
  completed: r.completed,
  isDeleted: r.isDeleted,
  version: r.version,
  updatedAt: r.updatedAt,
  dirty: r.dirty,
  sortKey: r.sortKey,
  recurrence: Recurrence.parse(r.recurrence),
  seriesId: r.seriesId,
);

/// Wire-format JSON of a row: what goes into `payload_json` and to the server.
Map<String, Object?> rowToWire(TaskRow r) => {
  'id': r.id,
  TaskFields.title: r.title,
  TaskFields.notes: r.notes,
  TaskFields.priority: r.priority,
  TaskFields.dueAt: normalizeTimestamp(r.dueAt),
  TaskFields.category: r.category,
  TaskFields.tags: decodeTags(r.tags),
  TaskFields.completed: r.completed,
  TaskFields.isDeleted: r.isDeleted,
  TaskFields.sortKey: r.sortKey,
  TaskFields.recurrence: r.recurrence,
  TaskFields.seriesId: r.seriesId,
  'updated_at': normalizeTimestamp(r.updatedAt),
};

/// Companion that sets a row's synced fields and `updated_at` from a
/// canonical wire map.
TasksCompanion wireToCompanion(Map<String, Object?> w) {
  final due = w[TaskFields.dueAt] as String?;
  return TasksCompanion(
    title: Value(w[TaskFields.title] as String),
    notes: Value(w[TaskFields.notes] as String),
    priority: Value(w[TaskFields.priority] as int),
    dueAt: Value(due == null ? null : DateTime.parse(due)),
    category: Value(w[TaskFields.category] as String?),
    tags: Value(encodeTags((w[TaskFields.tags] as List).cast<String>())),
    completed: Value(w[TaskFields.completed] as bool),
    isDeleted: Value(w[TaskFields.isDeleted] as bool),
    sortKey: Value(w[TaskFields.sortKey] as String),
    recurrence: Value(w[TaskFields.recurrence] as String?),
    seriesId: Value(w[TaskFields.seriesId] as String?),
    updatedAt: Value(DateTime.parse(w['updated_at'] as String)),
  );
}

String encodeSnapshot(Map<String, Object?> wire) => jsonEncode(wire);

Map<String, Object?>? decodeSnapshot(String? json) => json == null
    ? null
    : canonicalWire(Map<String, Object?>.from(jsonDecode(json) as Map));

/// The op type follows from the row's state, so merged edits can't lose it:
/// a tombstone is a delete, a task the server has never seen is a create,
/// anything else is an update.
String opTypeFor(TaskRow row) => row.isDeleted
    ? OpType.delete
    : (row.version == 0 ? OpType.create : OpType.update);
