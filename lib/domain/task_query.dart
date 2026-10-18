import 'task.dart';

enum StatusFilter {
  all('All'),
  pending('To do'),
  done('Done');

  const StatusFilter(this.label);
  final String label;
}

enum TaskSort {
  /// Open tasks first, then by due date, priority and last edit.
  smart('Smart'),
  dueDate('Due date'),
  priority('Priority'),
  recent('Recently edited');

  const TaskSort(this.label);
  final String label;
}

/// What the task list shows: search text, filters and sort order.
class TaskQuery {
  const TaskQuery({
    this.search = '',
    this.status = StatusFilter.all,
    this.priority,
    this.category,
    this.sort = TaskSort.smart,
  });

  /// Matched against title, notes, category and tags (case-insensitive).
  final String search;
  final StatusFilter status;
  final Priority? priority;
  final String? category;
  final TaskSort sort;

  bool get isFiltered =>
      search.trim().isNotEmpty ||
      status != StatusFilter.all ||
      priority != null ||
      category != null;

  TaskQuery copyWith({
    String? search,
    StatusFilter? status,
    Priority? priority,
    bool clearPriority = false,
    String? category,
    bool clearCategory = false,
    TaskSort? sort,
  }) => TaskQuery(
    search: search ?? this.search,
    status: status ?? this.status,
    priority: clearPriority ? null : (priority ?? this.priority),
    category: clearCategory ? null : (category ?? this.category),
    sort: sort ?? this.sort,
  );

  /// Keeps the sort order, drops every filter.
  TaskQuery cleared() => TaskQuery(sort: sort);
}

/// Sync state shown as a badge on each task.
enum TaskSyncState {
  /// Changed on this device, waiting to reach the server.
  pending,

  /// The server rejected it, or it ran out of attempts. Needs a manual retry.
  failed,
}
