import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sync/connectivity_monitor.dart';
import '../../domain/task.dart';
import '../../domain/task_query.dart';
import '../providers.dart';
import '../widgets/status_banner.dart';
import '../widgets/task_tile.dart';
import 'account_screen.dart';
import 'sync_log_screen.dart';
import 'task_edit_screen.dart';

class TaskListScreen extends ConsumerWidget {
  const TaskListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          const SyncButton(),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => value == 'log'
                    ? const SyncLogScreen()
                    : const AccountScreen(),
              ),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'log',
                child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('Sync log'),
                ),
              ),
              PopupMenuItem(
                value: 'account',
                child: ListTile(
                  leading: Icon(Icons.account_circle_outlined),
                  title: Text('Account'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: const Column(
        children: [
          StatusBanner(),
          _SearchAndFilters(),
          Expanded(child: _TaskList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openTaskEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
    );
  }
}

void openTaskEditor(BuildContext context, {String? taskId}) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => TaskEditScreen(taskId: taskId)));

// ------------------------------------------------------------- sync button

/// App bar sync control: shows the overall sync state, syncs on tap.
class SyncButton extends ConsumerWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(syncConfiguredProvider)) return const SizedBox.shrink();
    final signedIn = ref.watch(accountProvider).value != null;
    final network = ref.watch(networkStatusProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final syncing = ref.watch(syncStatusProvider).value?.syncing ?? false;

    final Widget icon;
    final String tooltip;
    if (syncing) {
      icon = const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
      tooltip = 'Syncing…';
    } else if (!signedIn) {
      icon = const Icon(Icons.cloud_outlined);
      tooltip = 'Sign in to sync';
    } else if (network != NetworkStatus.online) {
      icon = const Icon(Icons.cloud_off);
      tooltip = 'Offline';
    } else if (pending > 0) {
      icon = const Icon(Icons.cloud_upload_outlined);
      tooltip = '$pending waiting to sync. Tap to sync now';
    } else {
      icon = const Icon(Icons.cloud_done_outlined);
      tooltip = 'All changes synced. Tap to sync now';
    }

    return IconButton(
      key: const Key('sync-button'),
      tooltip: tooltip,
      icon: Badge(
        isLabelVisible: pending > 0 && !syncing,
        label: Text('$pending'),
        child: icon,
      ),
      onPressed: syncing
          ? null
          : () => signedIn
                ? _syncNow(context, ref)
                : Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AccountScreen()),
                  ),
    );
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final coordinator = ref.read(syncCoordinatorProvider);
    if (coordinator == null) return;
    final report = await coordinator.syncNow(userAsked: true);
    final message = switch (report) {
      null => "You're offline. Changes will sync when you're back online.",
      final r when r.error != null => 'Sync stopped: ${r.error}',
      final r when r.failed > 0 =>
        "${r.failed} ${r.failed == 1 ? 'change' : 'changes'} couldn't sync. "
            'See the sync log.',
      _ => 'Up to date',
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// --------------------------------------------------------- search + filters

class _SearchAndFilters extends ConsumerStatefulWidget {
  const _SearchAndFilters();

  @override
  ConsumerState<_SearchAndFilters> createState() => _SearchAndFiltersState();
}

class _SearchAndFiltersState extends ConsumerState<_SearchAndFilters> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _setSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      ref
          .read(taskQueryProvider.notifier)
          .update((q) => q.copyWith(search: text));
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(taskQueryProvider);
    final notifier = ref.read(taskQueryProvider.notifier);
    final categories = ref.watch(categoriesProvider).value ?? const [];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('search-field'),
                  controller: _search,
                  onChanged: _setSearch,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search title, notes, tags',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              _setSearch('');
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              PopupMenuButton<TaskSort>(
                tooltip: 'Sort: ${query.sort.label}',
                icon: const Icon(Icons.sort),
                initialValue: query.sort,
                onSelected: (s) => notifier.update((q) => q.copyWith(sort: s)),
                itemBuilder: (_) => [
                  for (final s in TaskSort.values)
                    CheckedPopupMenuItem(
                      value: s,
                      checked: s == query.sort,
                      child: Text(s.label),
                    ),
                ],
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                for (final s in StatusFilter.values) ...[
                  ChoiceChip(
                    key: Key('status-${s.name}'),
                    label: Text(s.label),
                    selected: query.status == s,
                    onSelected: (_) =>
                        notifier.update((q) => q.copyWith(status: s)),
                  ),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 4),
                _MenuChip<Priority>(
                  chipKey: const Key('filter-priority'),
                  label: query.priority == null
                      ? 'Priority'
                      : '${query.priority!.label} priority',
                  selected: query.priority != null,
                  options: {
                    for (final p in Priority.values.reversed) p: p.label,
                  },
                  onSelected: (p) => notifier.update(
                    (q) => p == null
                        ? q.copyWith(clearPriority: true)
                        : q.copyWith(priority: p),
                  ),
                ),
                const SizedBox(width: 6),
                if (categories.isNotEmpty || query.category != null)
                  _MenuChip<String>(
                    chipKey: const Key('filter-category'),
                    label: query.category ?? 'Category',
                    selected: query.category != null,
                    options: {for (final c in categories) c: c},
                    onSelected: (c) => notifier.update(
                      (q) => c == null
                          ? q.copyWith(clearCategory: true)
                          : q.copyWith(category: c),
                    ),
                  ),
                if (query.isFiltered) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: () {
                      _search.clear();
                      notifier.clearFilters();
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A filter chip that opens a menu of values, plus "Any".
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final Map<T, String> options;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        onPressed: () => onSelected(null),
        child: const Text('Any'),
      ),
      for (final e in options.entries)
        MenuItemButton(
          onPressed: () => onSelected(e.key),
          child: Text(e.value),
        ),
    ],
    builder: (context, controller, _) => FilterChip(
      key: chipKey,
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      avatar: const Icon(Icons.arrow_drop_down, size: 18),
      onSelected: (_) =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

// ------------------------------------------------------------------- list

class _TaskList extends ConsumerWidget {
  const _TaskList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider);
    // In a build without a backend nothing ever syncs, so "waiting to sync"
    // badges would only mislead.
    final syncStates = ref.watch(syncConfiguredProvider)
        ? ref.watch(syncStatesProvider).value ?? const {}
        : const <String, TaskSyncState>{};

    return tasks.when(
      skipLoadingOnReload: true,
      loading: () => const Center(
        child: CircularProgressIndicator(key: Key('tasks-loading')),
      ),
      error: (e, _) => _Message(
        key: const Key('tasks-error'),
        icon: Icons.error_outline,
        title: "Couldn't load your tasks",
        body: '$e',
        action: 'Try again',
        onAction: () => ref.invalidate(tasksProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          final hasAny = ref.watch(hasTasksProvider).value ?? false;
          return hasAny
              ? _Message(
                  key: const Key('tasks-no-match'),
                  icon: Icons.search_off,
                  title: 'No tasks match',
                  body: 'Try a different search or clear the filters.',
                  action: 'Clear filters',
                  onAction: ref.read(taskQueryProvider.notifier).clearFilters,
                )
              : const _Message(
                  key: Key('tasks-empty'),
                  icon: Icons.checklist,
                  title: 'No tasks yet',
                  body: 'Tap "New task" to add one. It works offline too.',
                );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
          itemBuilder: (context, i) {
            final task = items[i];
            return Dismissible(
              key: ValueKey(task.id),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) => _delete(context, ref, task),
              child: TaskTile(
                key: Key('task-${task.id}'),
                task: task,
                syncState: syncStates[task.id],
                onToggle: (done) => ref
                    .read(taskRepositoryProvider)
                    .setCompleted(task.id, done),
                onTap: () => openTaskEditor(context, taskId: task.id),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    TaskItem task,
  ) async {
    final repo = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    await repo.delete(task.id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted “${task.title}”'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repo.restore(task.id),
          ),
        ),
      );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
