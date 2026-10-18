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
  'updated_at': normalizeTimestamp(r.updatedAt),
};
