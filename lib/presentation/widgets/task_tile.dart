import 'package:flutter/material.dart';

import '../../domain/task.dart';
import '../../domain/task_query.dart';
import '../format.dart';

/// Small cloud icon: waiting to sync, or failed to sync. Nothing once synced.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.state});

  final TaskSyncState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (state) {
      null => const SizedBox.shrink(),
      TaskSyncState.pending => Tooltip(
        message: 'Waiting to sync',
        child: Icon(
          Icons.cloud_upload_outlined,
          key: const Key('badge-pending'),
          size: 18,
          color: scheme.outline,
          semanticLabel: 'Waiting to sync',
        ),
      ),
      TaskSyncState.failed => Tooltip(
        message: "Couldn't sync",
        child: Icon(
          Icons.cloud_off,
          key: const Key('badge-failed'),
          size: 18,
          color: scheme.error,
          semanticLabel: "Couldn't sync",
        ),
      ),
    };
  }
}

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.syncState,
    required this.onToggle,
    required this.onTap,
    this.dragHandle,
  });

  final TaskItem task;
  final TaskSyncState? syncState;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  /// Shown in manual order, to drag the task to a new position.
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = task.completed;

    final details = <Widget>[
      if (task.dueAt != null)
        _Chip(
          icon: task.isOverdue ? Icons.warning_amber : Icons.event,
          label: (task.isOverdue ? 'Overdue · ' : '') + formatDue(task.dueAt!),
          color: task.isOverdue ? scheme.error : scheme.onSurfaceVariant,
        ),
      if (task.recurrence != null)
        _Chip(
          icon: Icons.repeat,
          label: task.recurrence!.label,
          color: scheme.onSurfaceVariant,
        ),
      if (task.category != null)
        _Chip(
          icon: Icons.folder_outlined,
          label: task.category!,
          color: scheme.onSurfaceVariant,
        ),
      for (final tag in task.tags)
        _Chip(icon: Icons.tag, label: tag, color: scheme.onSurfaceVariant),
    ];

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.only(left: 4, right: 16),
      leading: Checkbox(
        value: done,
        onChanged: (v) => onToggle(v ?? false),
        semanticLabel: done ? 'Mark as not done' : 'Mark as done',
      ),
      title: Row(
        children: [
          Icon(
            priorityIcon(task.priority),
            size: 18,
            color: priorityColor(task.priority, scheme),
            semanticLabel: '${task.priority.label} priority',
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                decoration: done ? TextDecoration.lineThrough : null,
                color: done ? scheme.outline : null,
              ),
            ),
          ),
        ],
      ),
      subtitle: details.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 10, runSpacing: 2, children: details),
            ),
      trailing: dragHandle == null
          ? SyncBadge(state: syncState)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SyncBadge(state: syncState),
                const SizedBox(width: 4),
                dragHandle!,
              ],
            ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 3),
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
      ),
    ],
  );
}
