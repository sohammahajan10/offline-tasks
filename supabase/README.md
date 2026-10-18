# Supabase backend

`migrations/20261018000000_tasks_sync.sql` creates everything the app needs:

| Object | Purpose |
|---|---|
| `tasks` | Synced tasks. Client UUID primary key, `version` for optimistic concurrency, `server_updated_at` (set by trigger) as the pull cursor, `is_deleted` tombstones. |
| `applied_ops` | Every applied op id. Its primary key is what makes a retried push idempotent. |
| `apply_task_change(op_id, task, base_version)` | The atomic push. Returns `applied` or `duplicate`. A stale base version raises `PT409` (HTTP 409) with the current row in `details`. |
| RLS policies | Each user can select, insert and update only their own rows. There is no DELETE policy, and TRUNCATE is revoked. |

## Deploy

1. Create a project at supabase.com.
2. **Authentication → Providers → Email**: enabled. To test without an inbox,
   turn off *Confirm email*.
3. **SQL Editor**: paste the migration file and run it. Or, with the Supabase
   CLI: `supabase link --project-ref <ref>` and then `supabase db push`.
4. **Project Settings → API**: copy the project URL (`https://<ref>.supabase.co`,
   without `/rest/v1`) and the `anon` public key into `.env` (see
   `.env.example`). Never use the `service_role` key in the app.

## Test

- **Locally**, without a project (Postgres in WASM, with a stand-in for Supabase's `auth` schema):

  ```sh
  cd tool/sqltest && npm install && npm test
  ```

- **On your project**: paste `tests/rls_and_push_test.sql` into the SQL
  Editor. It runs in a transaction that is rolled back, so it leaves nothing
  behind. The last result row lists every passed check.
- **End to end** from Dart, with a test account in `.env`:

  ```sh
  flutter test test/live --dart-define-from-file=.env
  ```

## Housekeeping

`applied_ops` grows by one row per push. Pruning rows older than about 30 days
is safe. A replayed op older than that is either rejected as stale and merged,
or it re-applies an identical payload, which only bumps the version.
