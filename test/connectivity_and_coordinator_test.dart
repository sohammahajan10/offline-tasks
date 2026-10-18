import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_tasks/data/api/remote_api.dart';
import 'package:offline_tasks/data/db/database.dart';
import 'package:offline_tasks/data/sync/connectivity_monitor.dart';
import 'package:offline_tasks/data/sync/sync_coordinator.dart';
import 'package:offline_tasks/data/sync/sync_engine.dart';
import 'package:offline_tasks/domain/sync_log_repository.dart';
import 'package:offline_tasks/domain/task.dart';
import 'package:offline_tasks/domain/task_repository.dart';

import 'support/fake_remote_api.dart';

/// Scriptable network: which interfaces are up and whether the server answers.
class FakeNetwork {
  final changes = StreamController<List<ConnectivityResult>>.broadcast();
  var interfaces = [ConnectivityResult.wifi];
  var serverUp = true;
  var probes = 0;

  ConnectivityMonitor monitor({
    bool withProbe = true,
    Duration recheckEvery = const Duration(milliseconds: 20),
  }) => ConnectivityMonitor(
    changes: changes.stream,
    current: () async => interfaces,
    probe: withProbe
        ? () async {
            probes++;
            return serverUp;
          }
        : null,
    recheckEvery: recheckEvery,
  );

  void set(List<ConnectivityResult> next) {
    interfaces = next;
    changes.add(next);
  }
}

Future<void> settle([int ms = 10]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('ConnectivityMonitor', () {
    late FakeNetwork net;
    setUp(() => net = FakeNetwork());

    test('no interfaces is offline, without asking the server', () async {
      net.interfaces = [ConnectivityResult.none];
      final m = net.monitor();
      await m.start();
      expect(m.status, NetworkStatus.offline);
      expect(net.probes, 0);
      await m.dispose();
    });

    test(
      'Wi-Fi up but the server unreachable (captive portal) is not online',
      () async {
        net.serverUp = false;
        final m = net.monitor();
        await m.start();
        expect(m.status, NetworkStatus.unreachable);
        await m.dispose();
      },
    );

    test('keeps re-checking while not online, then reports online', () async {
      net.serverUp = false;
      final m = net.monitor();
      final seen = <NetworkStatus>[];
      final sub = m.statusStream.listen(seen.add);
      await m.start();
      net.serverUp = true; // signed into the portal
      await settle(60);
      expect(m.status, NetworkStatus.online);
      expect(seen, [
        NetworkStatus.unknown,
        NetworkStatus.unreachable,
        NetworkStatus.online,
      ]);
      await sub.cancel();
      await m.dispose();
    });

    test('follows interface changes (airplane mode on and off)', () async {
      final m = net.monitor();
      await m.start();
      expect(m.status, NetworkStatus.online);
      net.set([ConnectivityResult.none]);
      await settle();
      expect(m.status, NetworkStatus.offline);
      net.set([ConnectivityResult.mobile]);
      await settle();
      expect(m.status, NetworkStatus.online);
      await m.dispose();
    });

    test('a probe that throws counts as unreachable', () async {
      final m = ConnectivityMonitor(
        changes: const Stream.empty(),
        current: () async => [ConnectivityResult.wifi],
        probe: () async => throw Exception('DNS failure'),
      );
      await m.start();
      expect(m.status, NetworkStatus.unreachable);
      await m.dispose();
    });

    test('without a backend, any network counts as online', () async {
      final m = net.monitor(withProbe: false);
      await m.start();
      expect(m.status, NetworkStatus.online);
      await m.dispose();
    });

    test(
      'healthCheck: 2xx is reachable; errors, 5xx and timeouts are not',
      () async {
        final uri = Uri.parse('https://x.supabase.co/auth/v1/health');
        Future<bool> check(Future<http.Response> Function(http.Request) h) =>
            ConnectivityMonitor.healthCheck(
              uri,
              'key',
              client: MockClient(h),
              timeout: const Duration(milliseconds: 50),
            );
        expect(
          await check((r) async {
            expect(r.headers['apikey'], 'key');
            return http.Response('{}', 200);
          }),
          isTrue,
        );
        expect(await check((_) async => http.Response('portal', 302)), isFalse);
        expect(await check((_) async => http.Response('down', 503)), isFalse);
        expect(
          await check((_) async => throw http.ClientException('x')),
          isFalse,
        );
        expect(
          await check((_) async {
            await settle(200);
            return http.Response('{}', 200);
          }),
          isFalse,
        );
      },
    );
  });

  group('SyncCoordinator', () {
    late AppDatabase db;
    late FakeRemoteApi server;
    late FakeNetwork net;
    late ConnectivityMonitor monitor;
    late TaskRepository repo;
    late SyncCoordinator coordinator;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      server = FakeRemoteApi();
      net = FakeNetwork();
      monitor = net.monitor();
      repo = TaskRepository(db);
      coordinator = SyncCoordinator(
        engine: SyncEngine(db, server),
        connectivity: monitor,
        localWrites: repo.localWrites,
        nextRetryAt: SyncLogRepository(db).nextRetryAt,
        isSignedIn: () => server.userId != null,
        debounce: const Duration(milliseconds: 30),
        pullEvery: const Duration(hours: 1),
      );
    });

    tearDown(() async {
      await coordinator.dispose();
      await monitor.dispose();
      await db.close();
    });

    test('a local write syncs after the debounce, bursts coalesce', () async {
      await monitor.start();
      coordinator.start();
      await settle();
      server.pushCalls.clear();

      final id = await repo.create(title: 'One');
      await repo.update(id, const TaskPatch(title: 'One!'));
      await repo.setCompleted(id, true);
      expect(server.pushCalls, isEmpty, reason: 'still debouncing');
      await settle(120);

      expect(server.pushCalls, hasLength(1));
      expect(server.rows[id]!['title'], 'One!');
      expect(coordinator.status.lastSyncAt, isNotNull);
    });

    test('offline: nothing is sent; coming back online syncs', () async {
      net.interfaces = [ConnectivityResult.none];
      await monitor.start();
      coordinator.start();

      final id = await repo.create(title: 'Made offline');
      await settle(80);
      expect(server.pushCalls, isEmpty);

      net.set([ConnectivityResult.wifi]);
      await settle(80);
      expect(server.rows[id], isNotNull);
    });

    test('signed out: no sync at all', () async {
      server.userId = null;
      await monitor.start();
      coordinator.start();
      await repo.create(title: 'Local');
      await settle(80);
      expect(await coordinator.syncNow(userAsked: true), isNull);
      expect(server.pushCalls, isEmpty);
    });

    test('wakes up when a backoff retry falls due', () async {
      await monitor.start();
      await repo.create(title: 'Flaky');
      server.failures.add(const RemoteException('blip', retryable: true));
      final report = await coordinator.syncNow();
      expect(report!.error, 'blip');
      // Pull the retry forward so the test doesn't wait 2+ seconds.
      await db
          .update(db.syncQueue)
          .write(
            SyncQueueCompanion(
              nextRetryAt: Value(
                DateTime.now().add(const Duration(milliseconds: 40)),
              ),
            ),
          );
      await coordinator.syncNow(); // re-arms the timer from the queue
      await settle(150);
      expect(await db.select(db.syncQueue).get(), isEmpty);
    });
  });
}
