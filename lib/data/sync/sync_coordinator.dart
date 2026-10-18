import 'dart:async';

import 'connectivity_monitor.dart';
import 'sync_engine.dart';

class SyncStatus {
  const SyncStatus({this.syncing = false, this.lastSyncAt, this.lastError});

  final bool syncing;

  /// Last run that completed without error.
  final DateTime? lastSyncAt;

  /// Why the last run stopped early, if it did.
  final String? lastError;

  SyncStatus copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? lastError,
    bool clearError = false,
  }) => SyncStatus(
    syncing: syncing ?? this.syncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}

/// Decides *when* to sync; [SyncEngine] decides *what*. Triggers:
/// * a local write (debounced, so typing a burst of edits costs one run),
/// * the server becoming reachable,
/// * the app coming back to the foreground,
/// * the earliest backoff retry falling due,
/// * a periodic pull while online, to pick up other devices' changes,
/// * the user tapping "Sync now".
class SyncCoordinator {
  SyncCoordinator({
    required this.engine,
    required this.connectivity,
    required this.localWrites,
    required this.nextRetryAt,
    required this.isSignedIn,
    this.debounce = const Duration(milliseconds: 800),
    this.pullEvery = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SyncEngine engine;
  final ConnectivityMonitor connectivity;
  final bool Function() isSignedIn;
  final Duration debounce;
  final Duration pullEvery;
  final Stream<void> localWrites;
  final Future<DateTime?> Function() nextRetryAt;
  final DateTime Function() _clock;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  var _status = const SyncStatus();
  Timer? _debounceTimer;
  Timer? _retryTimer;
  Timer? _pullTimer;
  var _disposed = false;

  SyncStatus get status => _status;

  Stream<SyncStatus> get statusStream async* {
    yield _status;
    yield* _statusController.stream;
  }

  void start() {
    _subs.add(localWrites.listen((_) => _schedule()));
    _subs.add(
      connectivity.statusStream.listen((s) {
        if (s == NetworkStatus.online) unawaited(syncNow());
      }),
    );
    _pullTimer = Timer.periodic(pullEvery, (_) => unawaited(syncNow()));
  }

  /// App returned to the foreground.
  Future<void> onResume() async {
    await connectivity.recheck();
    await syncNow();
  }

  /// Runs a sync if signed in and the server is reachable. With [userAsked],
  /// connectivity is re-checked first instead of trusting the last status.
  Future<SyncReport?> syncNow({bool userAsked = false}) async {
    if (_disposed || !isSignedIn()) return null;
    if (userAsked) await connectivity.recheck();
    if (connectivity.status != NetworkStatus.online) return null;

    _emit(_status.copyWith(syncing: true));
    final report = await engine.sync();
    if (_disposed) return report;
    _emit(
      report.error == null
          ? _status.copyWith(
              syncing: false,
              lastSyncAt: _clock(),
              clearError: true,
            )
          : _status.copyWith(syncing: false, lastError: report.error),
    );
    // A run that stopped on a network error: maybe we went offline.
    if (report.error != null) unawaited(connectivity.recheck());
    await _scheduleRetry();
    return report;
  }

  void _schedule() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
  }

  /// Wakes up when the earliest backoff entry is due.
  Future<void> _scheduleRetry() async {
    _retryTimer?.cancel();
    final due = await nextRetryAt();
    if (due == null || _disposed) return;
    final wait = due.difference(_clock());
    _retryTimer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(syncNow()),
    );
  }

  void _emit(SyncStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  Future<void> dispose() async {
    _disposed = true;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _pullTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _statusController.close();
  }
}
