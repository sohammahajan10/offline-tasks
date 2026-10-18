import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_tasks/data/api/remote_api.dart';
import 'package:offline_tasks/data/api/supabase_config.dart';
import 'package:offline_tasks/data/api/supabase_remote_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Checks the HTTP mapping against what PostgREST sends for each case.
void main() {
  final row = {
    'id': '7a500000-0000-4000-8000-0000000000a1',
    'title': 'Server title',
    'version': 5,
    'updated_at': '2026-10-18T09:00:00+00:00',
    'server_updated_at': '2026-10-18T09:00:01.123456+00:00',
  };
  final task = {'id': row['id'], 'title': 'Mine'};

  late List<http.Request> requests;

  SupabaseRemoteApi apiReturning(
    Future<http.Response> Function(http.Request) handler,
  ) {
    requests = [];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      httpClient: MockClient((req) async {
        requests.add(req);
        final r = await handler(req);
        // Real responses always carry their request; postgrest reads it.
        return http.Response.bytes(
          r.bodyBytes,
          r.statusCode,
          headers: r.headers,
          request: req,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: SupabaseConfig.postgrestOptions,
    );
    return SupabaseRemoteApi(client);
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response error(
    int status,
    String code,
    String message, {
    String? details,
  }) => json({
    'code': code,
    'message': message,
    'details': details,
    'hint': null,
  }, status);

  group('push', () {
    test(
      'calls apply_task_change and maps applied/duplicate to PushApplied',
      () async {
        for (final status in ['applied', 'duplicate']) {
          final api = apiReturning(
            (_) async => json({'status': status, 'row': row}),
          );
          final result = await api.push(
            opId: 'op-1',
            task: task,
            baseVersion: 4,
          );

          expect(result, isA<PushApplied>());
          expect(result.serverRow['version'], 5);
          final req = requests.single;
          expect(req.method, 'POST');
          expect(req.url.path, '/rest/v1/rpc/apply_task_change');
          expect(jsonDecode(req.body), {
            'p_op_id': 'op-1',
            'p_task': task,
            'p_base_version': 4,
          });
        }
      },
    );

    test('a PT409 is a PushConflict carrying the row from details', () async {
      final api = apiReturning(
        (_) async =>
            error(409, 'PT409', 'stale_version', details: jsonEncode(row)),
      );
      final result = await api.push(opId: 'op-1', task: task, baseVersion: 3);

      expect(result, isA<PushConflict>());
      expect(result.serverRow['title'], 'Server title');
      expect(requests, hasLength(1), reason: 'no extra round trip');
    });

    test('a PT409 without usable details fetches the task instead', () async {
      final api = apiReturning(
        (req) async => req.url.path.endsWith('/rpc/apply_task_change')
            ? error(409, 'PT409', 'stale_version', details: 'not json')
            : json([row]),
      );
      final result = await api.push(opId: 'op-1', task: task, baseVersion: 3);

      expect(result, isA<PushConflict>());
      expect(result.serverRow['version'], 5);
      expect(requests.last.url.path, '/rest/v1/tasks');
      expect(requests.last.url.queryParameters['id'], 'eq.${row['id']}');
    });

    final cases = <String, (http.Response, bool)>{
      'check violation (23514)': (
        error(400, '23514', 'check constraint'),
        false,
      ),
      'id taken by another account (23505)': (
        error(409, '23505', 'duplicate key'),
        false,
      ),
      'RLS / not authenticated (42501)': (error(403, '42501', 'denied'), false),
      'function not deployed (PGRST202)': (
        error(404, 'PGRST202', 'not found'),
        false,
      ),
      'JWT expired (PGRST301)': (error(401, 'PGRST301', 'JWT expired'), true),
      'serialization failure (40001)': (error(500, '40001', 'retry'), true),
      'gateway error with an HTML body': (http.Response('<html>', 502), true),
    };
    for (final MapEntry(key: name, value: (response, retryable))
        in cases.entries) {
      test('$name → ${retryable ? 'retryable' : 'permanent'}', () async {
        final api = apiReturning((_) async => response);
        await expectLater(
          api.push(opId: 'op-1', task: task, baseVersion: 1),
          throwsA(
            isA<RemoteException>().having(
              (e) => e.retryable,
              'retryable',
              retryable,
            ),
          ),
        );
      });
    }

    test('network failure → retryable', () async {
      final api = apiReturning(
        (_) async => throw const SocketException('no route'),
      );
      await expectLater(
        api.push(opId: 'op-1', task: task, baseVersion: 1),
        throwsA(
          isA<RemoteException>().having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
  });

  group('pullSince', () {
    test('asks for rows after the cursor, oldest first, limited', () async {
      final api = apiReturning((_) async => json([row]));
      final rows = await api.pullSince(
        DateTime.utc(2026, 10, 18, 9, 0, 0, 500),
        limit: 50,
      );

      expect(rows.single['id'], row['id']);
      final q = requests.single.url.queryParameters;
      expect(requests.single.url.path, '/rest/v1/tasks');
      expect(q['server_updated_at'], 'gt.2026-10-18T09:00:00.500Z');
      expect(q['order'], startsWith('server_updated_at.asc'));
      expect(q['limit'], '50');
    });

    test('first pull has no cursor filter', () async {
      final api = apiReturning((_) async => json([]));
      await api.pullSince(null);
      expect(
        requests.single.url.queryParameters.containsKey('server_updated_at'),
        isFalse,
      );
    });
  });

  test('signed out → userId is null, so the engine skips sync', () {
    expect(apiReturning((_) async => json([])).userId, isNull);
  });

  test('SupabaseConfig.normalizeUrl keeps only the project origin', () {
    expect(
      SupabaseConfig.normalizeUrl('https://abc.supabase.co/rest/v1/'),
      'https://abc.supabase.co',
    );
    expect(
      SupabaseConfig.normalizeUrl(' https://abc.supabase.co '),
      'https://abc.supabase.co',
    );
    expect(SupabaseConfig.normalizeUrl(''), '');
    expect(SupabaseConfig.normalizeUrl('not a url'), '');
  });
}
