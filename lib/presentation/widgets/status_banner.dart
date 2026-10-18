import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sync/connectivity_monitor.dart';
import '../providers.dart';
import '../screens/account_screen.dart';
import '../screens/sync_log_screen.dart';

/// One line under the app bar telling the user where their data stands.
/// Shows the most important state only: signed out > offline > server
/// unreachable > failed changes > syncing.
class StatusBanner extends ConsumerWidget {
  const StatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(syncConfiguredProvider)) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final account = ref.watch(accountProvider);
    final network = ref.watch(networkStatusProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final failed = ref.watch(failedCountProvider).value ?? 0;
    final syncing = ref.watch(syncStatusProvider).value?.syncing ?? false;

    final waiting = pending == 0
        ? ''
        : ' $pending ${pending == 1 ? 'change is' : 'changes are'} waiting to sync.';

    if (account.hasValue && account.value == null) {
      return _Banner(
        key: const Key('banner-signed-out'),
        icon: Icons.cloud_outlined,
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer,
        text:
            'Tasks are saved on this device. Sign in to back them up and '
            'sync across devices.',
        action: 'Sign in',
        onAction: () => _push(context, const AccountScreen()),
      );
    }
    if (network == NetworkStatus.offline) {
      return _Banner(
        key: const Key('banner-offline'),
        icon: Icons.cloud_off,
        color: scheme.surfaceContainerHighest,
        onColor: scheme.onSurface,
        text:
            "You're offline. Everything still works and is saved on this "
            'device.$waiting',
      );
    }
    if (network == NetworkStatus.unreachable) {
      return _Banner(
        key: const Key('banner-unreachable'),
        icon: Icons.wifi_tethering_error,
        color: scheme.surfaceContainerHighest,
        onColor: scheme.onSurface,
        text:
            "Connected, but the server can't be reached (sign-in page on "
            "this Wi-Fi?). We'll keep trying.$waiting",
      );
    }
    if (failed > 0) {
      return _Banner(
        key: const Key('banner-failed'),
        icon: Icons.error_outline,
        color: scheme.errorContainer,
        onColor: scheme.onErrorContainer,
        text: "$failed ${failed == 1 ? 'change' : 'changes'} couldn't sync.",
        action: 'Review',
        onAction: () => _push(context, const SyncLogScreen()),
      );
    }
    if (syncing) {
      return const LinearProgressIndicator(
        key: Key('banner-syncing'),
        minHeight: 2,
      );
    }
    return const SizedBox.shrink();
  }

  static void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final Color onColor;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    child: Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, color: onColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: onColor),
              ),
            ),
            if (action != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(foregroundColor: onColor),
                child: Text(action!),
              ),
          ],
        ),
      ),
    ),
  );
}
