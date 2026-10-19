import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/recurrence.dart';
import '../../domain/task.dart';
import '../../domain/task_query.dart';
import '../format.dart';
import '../providers.dart';
import '../widgets/task_tile.dart';

/// Creates a task ([taskId] null) or edits one.
class TaskEditScreen extends ConsumerStatefulWidget {
  const TaskEditScreen({super.key, this.taskId});

  final String? taskId;

  @override
  ConsumerState<TaskEditScreen> createState() => _TaskEditScreenState();
}

class _TaskEditScreenState extends ConsumerState<TaskEditScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _category = TextEditingController();
  final _categoryFocus = FocusNode();
  final _tagInput = TextEditingController();

  /// The task as loaded; null when creating. Saving sends only what differs
  /// from it, so a field another device changed meanwhile isn't overwritten.
  TaskItem? _original;
  var _loading = true;
  var _saving = false;
  Priority _priority = Priority.medium;
  DateTime? _dueAt;
  List<String> _tags = [];
  bool _completed = false;
  Recurrence? _recurrence;

  bool get _isNew => widget.taskId == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isNew) {
      setState(() => _loading = false);
      return;
    }
    final task = await ref.read(taskRepositoryProvider).getById(widget.taskId!);
    if (!mounted) return;
    setState(() {
      _original = task;
      _loading = false;
      if (task != null) {
        _title.text = task.title;
        _notes.text = task.notes;
        _category.text = task.category ?? '';
        _priority = task.priority;
        // Pulled rows carry UTC times; edit and show them in local time.
        _dueAt = task.dueAt?.toLocal();
        _tags = [...task.tags];
        _completed = task.completed;
        _recurrence = task.recurrence;
      }
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _category.dispose();
    _categoryFocus.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  /// DateTime's == also compares UTC-vs-local, so compare instants.
  static bool _sameMoment(DateTime? a, DateTime? b) =>
      a == null ? b == null : (b != null && a.isAtSameMomentAs(b));

  bool get _hasChanges {
    final o = _original;
    if (o == null) {
      return _title.text.trim().isNotEmpty ||
          _notes.text.trim().isNotEmpty ||
          _category.text.trim().isNotEmpty ||
          _tags.isNotEmpty ||
          _dueAt != null ||
          _recurrence != null;
    }
    return _title.text.trim() != o.title ||
        _notes.text.trim() != o.notes ||
        _category.text.trim() != (o.category ?? '') ||
        _priority != o.priority ||
        !_sameMoment(_dueAt, o.dueAt) ||
        _completed != o.completed ||
        _recurrence != o.recurrence ||
        !const ListEquality<String>().equals(_tags, o.tags);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_recurrence != null && _dueAt == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set a deadline for a repeating task.')),
      );
      return;
    }
    _addPendingTag();
    setState(() => _saving = true);
    final repo = ref.read(taskRepositoryProvider);
    final category = _category.text.trim();
    try {
      final o = _original;
      if (o == null) {
        await repo.create(
          title: _title.text,
          notes: _notes.text,
          priority: _priority,
          dueAt: _dueAt,
          category: category.isEmpty ? null : category,
          tags: _tags,
          recurrence: _recurrence,
        );
      } else if (_hasChanges) {
        await repo.update(
          o.id,
          TaskPatch(
            title: _title.text.trim() != o.title ? _title.text : null,
            notes: _notes.text.trim() != o.notes ? _notes.text : null,
            priority: _priority != o.priority ? _priority : null,
            dueAt: _sameMoment(_dueAt, o.dueAt) ? null : _dueAt,
            clearDueAt: _dueAt == null && o.dueAt != null,
            category: category != (o.category ?? '') && category.isNotEmpty
                ? category
                : null,
            clearCategory: category.isEmpty && o.category != null,
            tags: const ListEquality<String>().equals(_tags, o.tags)
                ? null
                : _tags,
            completed: _completed != o.completed ? _completed : null,
            recurrence: _recurrence != o.recurrence ? _recurrence : null,
            clearRecurrence: _recurrence == null && o.recurrence != null,
          ),
        );
      }
      await _askForReminderPermission();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  /// The first time a task gets a deadline, ask to show reminders (Android
  /// 13+ asks only once; after that this just reports the current state).
  Future<void> _askForReminderPermission() async {
    final notifications = ref.read(notificationsProvider);
    final due = _dueAt;
    if (notifications == null || due == null || due.isBefore(DateTime.now())) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!await notifications.requestPermission()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Reminders are off. Allow notifications for Offline Tasks in '
            'Settings to be reminded when tasks are due.',
          ),
        ),
      );
    }
  }

  Future<void> _delete() async {
    final o = _original!;
    final repo = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    await repo.delete(o.id);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted “${o.title}”'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => repo.restore(o.id),
        ),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text("Your edits to this task haven't been saved."),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  void _addPendingTag() {
    final parts = _tagInput.text
        .split(RegExp(r'[,\s]+'))
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.isNotEmpty && !_tags.contains(t));
    if (parts.isEmpty) return;
    setState(() {
      _tags = [..._tags, ...parts];
      _tagInput.clear();
    });
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final initial = _dueAt ?? DateTime(now.year, now.month, now.day, 18);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;
    final t = time ?? TimeOfDay.fromDateTime(initial);
    setState(
      () =>
          _dueAt = DateTime(date.year, date.month, date.day, t.hour, t.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final missing = !_isNew && !_loading && _original == null;
    return PopScope(
      canPop: _saving || !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New task' : 'Edit task'),
          actions: [
            if (_original != null)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
            TextButton(
              key: const Key('save-task'),
              onPressed: _loading || _saving || missing ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : missing
            ? const Center(child: Text('This task no longer exists.'))
            : _buildForm(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final categories = ref.watch(categoriesProvider).value ?? const [];
    return Form(
      key: _form,
      onChanged: () => setState(() {}),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_original != null) _SyncInfo(task: _original!),
          TextFormField(
            key: const Key('title-field'),
            controller: _title,
            autofocus: _isNew,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Give the task a title'
                : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: const Key('notes-field'),
            controller: _notes,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('Priority', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<Priority>(
            key: const Key('priority-field'),
            segments: [
              for (final p in Priority.values)
                ButtonSegment(
                  value: p,
                  label: Text(p.label),
                  icon: Icon(priorityIcon(p)),
                ),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.single),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(
              _dueAt == null
                  ? 'No deadline'
                  : DateFormat('EEE d MMM y, HH:mm').format(_dueAt!),
            ),
            subtitle: _dueAt == null ? null : Text(formatDue(_dueAt!)),
            onTap: _pickDue,
            trailing: _dueAt == null
                ? TextButton(onPressed: _pickDue, child: const Text('Set'))
                : IconButton(
                    tooltip: 'Remove deadline',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _dueAt = null),
                  ),
          ),
          DropdownButtonFormField<Recurrence?>(
            key: const Key('repeat-field'),
            initialValue: _recurrence,
            decoration: InputDecoration(
              labelText: 'Repeat',
              prefixIcon: const Icon(Icons.repeat),
              border: const OutlineInputBorder(),
              helperText: _recurrence == null
                  ? null
                  : 'Completing it creates the next one, '
                        '${_recurrence!.label.toLowerCase()} from the deadline',
              errorText: _recurrence != null && _dueAt == null
                  ? 'Set a deadline first'
                  : null,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Never')),
              for (final r in Recurrence.values)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
            onChanged: (r) => setState(() => _recurrence = r),
          ),
          const SizedBox(height: 16),
          RawAutocomplete<String>(
            textEditingController: _category,
            focusNode: _categoryFocus,
            optionsBuilder: (value) {
              final text = value.text.trim().toLowerCase();
              return categories.where(
                (c) =>
                    c.toLowerCase().contains(text) && c.toLowerCase() != text,
              );
            },
            fieldViewBuilder: (context, controller, focusNode, onSubmit) =>
                TextFormField(
                  key: const Key('category-field'),
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    hintText: 'e.g. Work, Home',
                    prefixIcon: Icon(Icons.folder_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
            optionsViewBuilder: (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 200,
                    maxWidth: 320,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final o in options)
                        ListTile(title: Text(o), onTap: () => onSelected(o)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('tag-field'),
            controller: _tagInput,
            decoration: InputDecoration(
              labelText: 'Tags',
              hintText: 'Type a tag and press enter',
              prefixIcon: const Icon(Icons.tag),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Add tag',
                icon: const Icon(Icons.add),
                onPressed: _addPendingTag,
              ),
            ),
            onSubmitted: (_) => _addPendingTag(),
            onChanged: (v) {
              if (v.endsWith(',') || v.endsWith(' ')) _addPendingTag();
            },
          ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: () =>
                          setState(() => _tags = [..._tags]..remove(tag)),
                    ),
                ],
              ),
            ),
          if (!_isNew) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Done'),
              value: _completed,
              onChanged: (v) => setState(() => _completed = v),
            ),
          ],
        ],
      ),
    );
  }
}

/// Where this task's latest change stands with the server.
class _SyncInfo extends ConsumerWidget {
  const _SyncInfo({required this.task});

  final TaskItem task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(syncConfiguredProvider)) return const SizedBox.shrink();
    final state = ref.watch(syncStatesProvider).value?[task.id];
    final change = ref
        .watch(queueProvider)
        .value
        ?.lastWhereOrNull((c) => c.taskId == task.id);
    final live = ref.watch(taskByIdProvider(task.id)).value ?? task;
    final scheme = Theme.of(context).colorScheme;

    final (String text, Color color) = switch (state) {
      TaskSyncState.failed => (
        "Couldn't sync: ${change?.lastError ?? 'unknown error'}",
        scheme.error,
      ),
      TaskSyncState.pending => (
        'Saved on this device, waiting to sync'
            '${(change?.attempts ?? 0) > 0 ? ' (attempt ${change!.attempts} failed, retrying)' : ''}',
        scheme.onSurfaceVariant,
      ),
      null => (
        live.version == 0
            ? 'Not synced yet'
            : 'Synced (version ${live.version})',
        scheme.onSurfaceVariant,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          SyncBadge(state: state),
          if (state != null) const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: color),
            ),
          ),
          if (state == TaskSyncState.failed && change != null)
            TextButton(
              onPressed: () async {
                await ref.read(syncEngineProvider)?.retry(change.seq);
                await ref
                    .read(syncCoordinatorProvider)
                    ?.syncNow(userAsked: true);
              },
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
