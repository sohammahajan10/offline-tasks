// Runs the RemoteApi contract against a real Supabase project.
// Skipped unless .env has the project keys and a test account:
//
//   flutter test test/live --dart-define-from-file=.env
//
// .env needs SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_TEST_EMAIL and
// SUPABASE_TEST_PASSWORD (the account is created if it doesn't exist; with
// email confirmation on, confirm it once first). It leaves a few rows behind,
// as tombstones, since clients cannot delete.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_tasks/data/api/remote_api.dart';
import 'package:offline_tasks/data/api/supabase_config.dart';
import 'package:offline_tasks/data/api/supabase_remote_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const _email = String.fromEnvironment('SUPABASE_TEST_EMAIL');
const _password = String.fromEnvironment('SUPABASE_TEST_PASSWORD');

void main() {
  final configured =
      SupabaseConfig.isConfigured && _email.isNotEmpty && _password.isNotEmpty;
  late SupabaseClient client;
  late SupabaseRemoteApi api;
  const uuid = Uuid();

  setUpAll(() async {
    if (!configured) return;
    client = SupabaseClient(
      SupabaseConfig.url,
      SupabaseConfig.anonKey,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: SupabaseConfig.postgrestOptions,
    );
    try {
      await client.auth.signInWithPassword(email: _email, password: _password);
    } on AuthException {
      await client.auth.signUp(email: _email, password: _password);
    }
    api = SupabaseRemoteApi(client);
  });

  tearDownAll(() async {
    if (configured) await client.auth.signOut();
  });

  Map<String, Object?> task(String id, String title, {bool deleted = false}) =>
      {
        'id': id,
        'title': '[live test] $title',
        'notes': '',
        'priority': 1,
        'due_at': null,
        'category': null,
        'tags': <String>[],
        'completed': false,
        'is_deleted': deleted,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  test(
    'push, duplicate, stale, tombstone, validation and pull',
    () async {
      expect(api.userId, isNotNull, reason: 'signed in');
      final id = uuid.v4();
      final before = DateTime.now().toUtc().subtract(
        const Duration(minutes: 1),
      );

      final op1 = uuid.v4();
      final created = await api.push(
        opId: op1,
        task: task(id, 'v1'),
        baseVersion: 0,
      );
      expect(created, isA<PushApplied>());
      expect(created.serverRow['version'], 1);

      final again = await api.push(
        opId: op1,
        task: task(id, 'v1'),
        baseVersion: 0,
      );
      expect(again, isA<PushApplied>(), reason: 'duplicate op id');
      expect(again.serverRow['version'], 1, reason: 'not applied twice');

      final stale = await api.push(
        opId: uuid.v4(),
        task: task(id, 'stale'),
        baseVersion: 0,
      );
      expect(stale, isA<PushConflict>(), reason: 'PT409 arrives as HTTP 409');
      expect(stale.serverRow['version'], 1);
      expect(stale.serverRow['title'], '[live test] v1');

      final updated = await api.push(
        opId: uuid.v4(),
        task: task(id, 'v2', deleted: true),
        baseVersion: 1,
      );
      expect(updated.serverRow['version'], 2);

      final ghost = uuid.v4();
      final tombstone = await api.push(
        opId: uuid.v4(),
        task: task(ghost, 'created and deleted offline', deleted: true),
        baseVersion: 0,
      );
      expect(tombstone.serverRow['is_deleted'], isTrue);

      await expectLater(
        api.push(
          opId: uuid.v4(),
          task: task(uuid.v4(), '')..['title'] = ' ',
          baseVersion: 0,
        ),
        throwsA(
          isA<RemoteException>().having((e) => e.retryable, 'retryable', false),
        ),
      );

      final pulled = await api.pullSince(before);
      expect(pulled.map((r) => r['id']), containsAll([id, ghost]));
    },
    skip: configured
        ? false
        : 'set SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_TEST_EMAIL and '
              'SUPABASE_TEST_PASSWORD in .env and pass --dart-define-from-file=.env',
  );

  test(
    'order key, recurrence and series id round-trip (needs migration 2)',
    () async {
      final id = uuid.v4();
      final pushed = await api.push(
        opId: uuid.v4(),
        task: {
          ...task(id, 'weekly', deleted: true),
          'due_at': DateTime.now().toUtc().toIso8601String(),
          'sort_key': 'a0V',
          'recurrence': 'weekly',
          'series_id': id,
        },
        baseVersion: 0,
      );
      expect(pushed.serverRow['sort_key'], 'a0V');
      expect(pushed.serverRow['recurrence'], 'weekly');
      expect(pushed.serverRow['series_id'], id);
    },
    skip: configured ? false : 'see above',
  );
}
