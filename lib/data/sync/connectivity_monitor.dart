import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

enum NetworkStatus {
  /// Not checked yet.
  unknown,

  /// No Wi-Fi, mobile data or ethernet (e.g. airplane mode).
  offline,

  /// A network is up, but the server can't be reached (captive portal,
  /// no internet behind the Wi-Fi, server down).
  unreachable,

  /// The server answered a health check.
  online,
}

/// Online means "the server answered", not just "Wi-Fi is on".
///
/// connectivity_plus only reports which network interfaces are up, so on its
/// own it shows "online" on captive-portal Wi-Fi. Every interface change (and
/// a timer while not online) is confirmed with a real request to [probe].
class ConnectivityMonitor {
  ConnectivityMonitor({
    required this.changes,
    required this.current,
    this.probe,
    this.recheckEvery = const Duration(seconds: 30),
  });

  /// Monitor for the real device, probing the Supabase auth health endpoint.
  factory ConnectivityMonitor.forSupabase({
    required String? url,
    required String? anonKey,
  }) {
    final connectivity = Connectivity();
    return ConnectivityMonitor(
      changes: connectivity.onConnectivityChanged,
      current: connectivity.checkConnectivity,
      probe: (url == null || url.isEmpty)
          ? null
          : () => healthCheck(Uri.parse('$url/auth/v1/health'), anonKey ?? ''),
    );
  }

  /// Network interface changes (connectivity_plus).
  final Stream<List<ConnectivityResult>> changes;
  final Future<List<ConnectivityResult>> Function() current;

  /// Returns true if the server is reachable. Null when there is no server
  /// configured: then any network counts as online.
  final Future<bool> Function()? probe;
  final Duration recheckEvery;

  final _controller = StreamController<NetworkStatus>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _timer;
  var _status = NetworkStatus.unknown;
  var _checks = 0;

  NetworkStatus get status => _status;

  /// Emits the current status on listen, then every change.
  Stream<NetworkStatus> get statusStream async* {
    yield _status;
    yield* _controller.stream;
  }

  Future<void> start() async {
    _sub = changes.listen(_evaluate);
    await recheck();
  }

  /// Checks again now, e.g. after a sync failed with a network error.
  Future<void> recheck() async => _evaluate(await current());

  Future<void> _evaluate(List<ConnectivityResult> interfaces) async {
    final check = ++_checks;
    final NetworkStatus next;
    if (interfaces.every((r) => r == ConnectivityResult.none)) {
      next = NetworkStatus.offline;
    } else if (probe == null) {
      next = NetworkStatus.online;
    } else {
      bool reachable;
      try {
        reachable = await probe!();
      } catch (_) {
        reachable = false;
      }
      next = reachable ? NetworkStatus.online : NetworkStatus.unreachable;
    }
    // A newer check started while this one awaited the probe: let it win.
    if (check != _checks) return;
    _set(next);
  }

  void _set(NetworkStatus next) {
    _timer?.cancel();
    // While not online, keep checking: the captive portal may have been
    // signed into, or the server may be back.
    if (next != NetworkStatus.online) {
      _timer = Timer(recheckEvery, recheck);
    }
    if (next == _status) return;
    _status = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _sub?.cancel();
    await _controller.close();
  }

  /// GET on a small endpoint with a short timeout. Any 2xx is reachable.
  static Future<bool> healthCheck(
    Uri uri,
    String apiKey, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final c = client ?? http.Client();
    try {
      final res = await c
          .get(uri, headers: {'apikey': apiKey})
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      if (client == null) c.close();
    }
  }
}
