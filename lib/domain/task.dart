import 'dart:convert';

enum Priority {
  low('Low'),
  medium('Medium'),
  high('High');

  const Priority(this.label);
  final String label;
}

/// Immutable task used by the UI and the repository.
class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    this.notes = '',
    this.priority = Priority.medium,
    this.dueAt,
    this.category,
    this.tags = const [],
    this.completed = false,
    this.isDeleted = false,
    this.version = 0,
    required this.updatedAt,
    this.dirty = false,
  });

  final String id;
  final String title;
  final String notes;
  final Priority priority;
  final DateTime? dueAt;
  final String? category;
  final List<String> tags;
  final bool completed;
  final bool isDeleted;
  final int version;
  final DateTime updatedAt;

  /// Has local changes the server has not acknowledged yet.
  final bool dirty;

  bool get isOverdue =>
      !completed && dueAt != null && dueAt!.isBefore(DateTime.now());
}

/// User-editable fields for [TaskRepository.update]. A null field means
/// "unchanged"; use the `clear*` flags to set a nullable field to null.
class TaskPatch {
  const TaskPatch({
    this.title,
    this.notes,
    this.priority,
    this.dueAt,
    this.clearDueAt = false,
    this.category,
    this.clearCategory = false,
    this.tags,
    this.completed,
  });

  final String? title;
  final String? notes;
  final Priority? priority;
  final DateTime? dueAt;
  final bool clearDueAt;
  final String? category;
  final bool clearCategory;
  final List<String>? tags;
  final bool? completed;
}

/// Field names of the synced task fields, in the server's JSON shape.
abstract final class TaskFields {
  static const title = 'title';
  static const notes = 'notes';
  static const priority = 'priority';
  static const dueAt = 'due_at';
  static const category = 'category';
  static const tags = 'tags';
  static const completed = 'completed';
  static const isDeleted = 'is_deleted';

  static const all = [
    title,
    notes,
    priority,
    dueAt,
    category,
    tags,
    completed,
    isDeleted,
  ];
}

/// Normalises a timestamp so the same instant always compares equal no matter
/// which side (Dart or Postgres) formatted it.
String? normalizeTimestamp(Object? value) {
  if (value == null) return null;
  final dt = value is DateTime ? value : DateTime.parse(value as String);
  return dt.toUtc().toIso8601String();
}

/// Brings any representation of a task (local row, queue payload, Postgres
/// row) to one canonical wire map, so equal values always compare equal.
Map<String, Object?> canonicalWire(Map<String, Object?> raw) => {
  'id': raw['id'],
  TaskFields.title: raw[TaskFields.title] ?? '',
  TaskFields.notes: raw[TaskFields.notes] ?? '',
  TaskFields.priority: (raw[TaskFields.priority] as num?)?.toInt() ?? 1,
  TaskFields.dueAt: normalizeTimestamp(raw[TaskFields.dueAt]),
  TaskFields.category: raw[TaskFields.category],
  TaskFields.tags: [
    for (final t in (raw[TaskFields.tags] as List?) ?? const []) t.toString(),
  ],
  TaskFields.completed: raw[TaskFields.completed] ?? false,
  TaskFields.isDeleted: raw[TaskFields.isDeleted] ?? false,
  'version': (raw['version'] as num?)?.toInt() ?? 0,
  'updated_at': normalizeTimestamp(raw['updated_at']),
  if (raw['server_updated_at'] != null)
    'server_updated_at': normalizeTimestamp(raw['server_updated_at']),
};

String encodeTags(List<String> tags) => jsonEncode(tags);

List<String> decodeTags(String json) =>
    (jsonDecode(json) as List).map((e) => e.toString()).toList();
