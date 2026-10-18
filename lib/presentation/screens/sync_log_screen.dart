import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../domain/sync_log_repository.dart';
import '../format.dart';
import '../providers.dart';

/// What's waiting to sync, what failed (with retry), and the sync history:
/// uploads, retries, conflicts and how they were resolved.
class SyncLogScreen extends ConsumerWidget {
  const SyncLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);
    final log = ref.watch(syncLogProvider);
    final engine = ref.watch(syncEngineProvider);
    final coordinator = ref.watch(syncCoordinatorProvider);
    final syncing = ref.watch(syncStatusProvider).value?.syncing ?? false;
    final failed = queue.value?.where((c) => c.failed).length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync log'),
        actions: [
          if (coordinator != null)
            IconButton(
              tooltip: 'Sync now',
              icon: const Icon(Icons.sync),
              onPressed: syncing
                  ? null
                  : () => coordinator.syncNow(userAsked: true),
            ),
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => ref.read(syncLogRepositoryProvider).clearLog(),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          if (syncing)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2),
            ),
          _header(
            context,
            'Waiting to sync',
            trailing: failed > 1 && engine != null
                ? TextButton(
                    onPressed: () async {
                      await engine.retryAllFailed();
                      await coordinator?.syncNow(userAsked: true);
                    },
                    child: const Text('Retry all'),
                  )
                : null,
          ),
          switch (queue) {
            AsyncData(value: final items) when items.isEmpty =>
              const SliverToBoxAdapter(
                child: ListTile(
                  leading: Icon(Icons.cloud_done_outlined),
                  title: Text('Everything is synced'),
                ),
              ),
            AsyncData(value: final items) => SliverList.list(
              children: [
                for (final c in items)
                  _QueuedTile(
                    change: c,
                    onRetry: engine == null
                        ? null
                        : () async {
                            await engine.retry(c.seq);
                            await coordinator?.syncNow(userAsked: true);
                          },
                  ),
              ],
            ),
            AsyncError(:final error) => SliverToBoxAdapter(
              child: ListTile(title: Text("Couldn't read the queue: $error")),
            ),
            _ => const SliverToBoxAdapter(child: LinearProgressIndicator()),
          },
          _header(context, 'History'),
          switch (log) {
            AsyncData(value: final entries) when entries.isEmpty =>
              const SliverToBoxAdapter(
                child: ListTile(title: Text('Nothing has happened yet.')),
              ),
            AsyncData(value: final entries) => SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => _LogTile(entry: entries[i]),
            ),
            AsyncError(:final error) => SliverToBoxAdapter(
              child: ListTile(title: Text("Couldn't read the log: $error")),
            ),
            _ => const SliverToBoxAdapter(child: LinearProgressIndicator()),
          },
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }

  static Widget _header(
    BuildContext context,
    String title, {
    Widget? trailing,
  }) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

class _QueuedTile extends StatelessWidget {
  const _QueuedTile({required this.change, required this.onRetry});

  final QueuedChange change;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final what = switch (change.opType) {
      OpType.create => 'New task',
      OpType.delete => 'Deleted',
      _ => 'Edited',
    };
    final String status;
    if (change.failed) {
      status =
          "Couldn't sync after ${change.attempts} attempt(s): "
          '${change.lastError ?? 'unknown error'}';
    } else if (change.status == OpStatus.inFlight) {
      status = 'Uploading…';
    } else if (change.nextRetryAt != null) {
      status =
          'Attempt ${change.attempts} failed (${change.lastError}). '
          'Next try ${formatAgo(change.nextRetryAt!).replaceFirst(' ago', '')}'
          '${change.nextRetryAt!.isAfter(DateTime.now()) ? '' : ' (due)'}';
    } else {
      status = 'Waiting for a connection';
    }
    return ListTile(
      leading: Icon(
        change.failed ? Icons.cloud_off : Icons.cloud_upload_outlined,
        color: change.failed ? scheme.error : scheme.outline,
      ),
      title: Text('$what: ${change.title}'),
      subtitle: Text(status),
      trailing: change.failed && onRetry != null
          ? TextButton(onPressed: onRetry, child: const Text('Retry'))
          : null,
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final SyncLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry.level) {
      LogLevel.conflict => (Icons.call_split, scheme.tertiary),
      LogLevel.error => (Icons.error_outline, scheme.error),
      _ => (Icons.check_circle_outline, scheme.outline),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(entry.message),
      subtitle: Text(formatAgo(entry.at)),
    );
  }
}
