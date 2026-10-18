-- RLS and apply_task_change() tests.
--
-- Runs locally via tool/sqltest (PGlite), or paste into the Supabase SQL
-- editor of a real project: everything happens in one transaction that is
-- rolled back, so it leaves no users, tasks or helpers behind.
-- The first failing check aborts with "FAILED: <check>". On success the last
-- result row lists every check that passed.

begin;

-- ---------------------------------------------------------------- helpers

create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.ok(passed boolean, check_name text) returns void
language plpgsql as $$
begin
  if passed is not true then
    raise exception 'FAILED: %', check_name;
  end if;
  perform set_config('tests.passed',
    (coalesce(nullif(current_setting('tests.passed', true), ''), '0')::int + 1)::text, true);
  perform set_config('tests.log',
    concat_ws(E'\n', nullif(current_setting('tests.log', true), ''), check_name), true);
end $$;

-- Runs a statement as the current role; returns its SQLSTATE, or 'ok'.
create function tests.sqlstate_of(statement text) returns text
language plpgsql as $$
begin
  execute statement;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- A task payload in the app's wire format.
create function tests.task(id uuid, title text, extra jsonb default '{}')
returns jsonb language sql as $$
  select jsonb_build_object(
    'id', id, 'title', title, 'notes', '', 'priority', 1, 'due_at', null,
    'category', null, 'tags', '[]'::jsonb, 'completed', false,
    'is_deleted', false, 'updated_at', '2026-10-18T09:00:00Z'
  ) || extra
$$;

grant execute on all functions in schema tests to anon, authenticated;

-- Two accounts.
insert into auth.users (id, email) values
  ('a11ce000-0000-4000-8000-000000000001', 'alice@example.test'),
  ('b0b00000-0000-4000-8000-000000000002', 'bob@example.test');

-- ------------------------------------------------------ Alice: push rules

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a11ce000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select tests.ok(
  public.apply_task_change('0b000000-0000-4000-8000-000000000001',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'Alice task'), 0)
    ->> 'status' = 'applied',
  'push inserts a new task');

select tests.ok(
  (select version = 1 and user_id = auth.uid()
   from public.tasks where id = '7a500000-0000-4000-8000-0000000000a1'),
  'a new task starts at version 1, owned by the caller');

select tests.ok(
  public.apply_task_change('0b000000-0000-4000-8000-000000000001',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'Alice task'), 0)
    ->> 'status' = 'duplicate',
  'the same op id again is reported as a duplicate');

select tests.ok(
  (select count(*) = 1 and max(version) = 1 from public.tasks),
  'the duplicate wrote nothing');

select tests.ok(
  (public.apply_task_change('0b000000-0000-4000-8000-000000000002',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'Alice task v2'), 1)
    -> 'row' ->> 'version')::int = 2,
  'a push based on the current version applies and bumps the version');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000003',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'stale edit'), 1)$$)
    = 'PT409',
  'a push based on an old version raises PT409 (HTTP 409)');

do $$
declare
  current_row jsonb;
begin
  perform public.apply_task_change('0b000000-0000-4000-8000-000000000003',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'stale edit'), 1);
  perform tests.ok(false, 'a stale push must raise');
exception when sqlstate 'PT409' then
  get stacked diagnostics current_row = pg_exception_detail;
  perform tests.ok(
    (current_row ->> 'version')::int = 2 and current_row ->> 'title' = 'Alice task v2',
    'PT409 carries the current row in DETAIL, so the client can merge');
end $$;

select tests.ok(
  (select title = 'Alice task v2' and version = 2
   from public.tasks where id = '7a500000-0000-4000-8000-0000000000a1'),
  'the stale push changed nothing');

select tests.ok(
  not exists (select 1 from public.applied_ops
              where op_id = '0b000000-0000-4000-8000-000000000003'),
  'a rejected op id is not recorded (the whole call rolled back)');

do $$
declare
  before timestamptz;
  after timestamptz;
begin
  select server_updated_at into before
  from public.tasks where id = '7a500000-0000-4000-8000-0000000000a1';
  perform public.apply_task_change('0b000000-0000-4000-8000-000000000004',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'Alice task v3'), 2);
  select server_updated_at into after
  from public.tasks where id = '7a500000-0000-4000-8000-0000000000a1';
  perform tests.ok(after > before,
    'every write moves server_updated_at forward (the pull cursor)');
  perform tests.ok(
    (select count(*) = 1 from public.tasks where server_updated_at > before),
    'a delta pull after the old cursor returns just the changed row');
end $$;

select tests.ok(
  (public.apply_task_change('0b000000-0000-4000-8000-000000000005',
    tests.task('7a500000-0000-4000-8000-0000000000a2', 'Created and deleted offline',
               '{"is_deleted": true}'), 0)
    -> 'row' ->> 'is_deleted')::boolean,
  'a delete for an id the server never saw is stored as a tombstone');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000006',
    tests.task('7a500000-0000-4000-8000-0000000000a3', '   '), 0)$$) = '23514',
  'a blank title is rejected as invalid (23514), not as stale');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000007',
    tests.task('7a500000-0000-4000-8000-0000000000a3', 'x', '{"priority": 7}'), 0)$$)
    = '23514',
  'an out-of-range priority is rejected (23514)');

select tests.ok(
  tests.sqlstate_of($$update public.tasks set version = 99
    where id = '7a500000-0000-4000-8000-0000000000a1'$$) = '22023',
  'a direct UPDATE cannot skip versions');

select tests.ok(
  tests.sqlstate_of($$delete from public.tasks
    where id = '7a500000-0000-4000-8000-0000000000a1'$$) = '42501',
  'clients cannot DELETE, even their own rows (deletes are tombstones)');

select tests.ok(
  tests.sqlstate_of('truncate public.tasks') = '42501',
  'TRUNCATE (which ignores RLS) is not granted');

-- ----------------------------------------------------- Bob: RLS isolation

select set_config('request.jwt.claims',
  '{"sub":"b0b00000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select tests.ok((select count(*) = 0 from public.tasks),
  'Bob cannot see any of Alice''s tasks');

select tests.ok((select count(*) = 0 from public.applied_ops),
  'Bob cannot see Alice''s applied op ids');

with hijack as (
  update public.tasks set title = 'hacked', version = version + 1
  where id = '7a500000-0000-4000-8000-0000000000a1'
  returning 1
)
select tests.ok((select count(*) = 0 from hijack),
  'Bob''s UPDATE of Alice''s task matches no rows');

-- An UPDATE that reads no columns is filtered by the UPDATE policy alone (the
-- SELECT policy only joins in when columns are read), so this isolates it.
-- Any row it matched would trip the version trigger and raise 22023.
select tests.ok(
  tests.sqlstate_of($$update public.tasks set notes = 'hacked'$$) = 'ok',
  'the UPDATE policy on its own keeps Bob away from Alice''s rows');

select tests.ok(
  tests.sqlstate_of($$insert into public.tasks (id, user_id, title, updated_at)
    values ('7a500000-0000-4000-8000-0000000000b9',
            'a11ce000-0000-4000-8000-000000000001', 'planted', now())$$) = '42501',
  'Bob cannot insert a task owned by Alice');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000010',
    tests.task('7a500000-0000-4000-8000-0000000000a1', 'Bob takes over'), 3)$$)
    = '23505',
  'Bob cannot overwrite Alice''s task through the push function');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000001',
    tests.task('7a500000-0000-4000-8000-0000000000b1', 'replay'), 0)$$) = '23505',
  'Bob cannot replay Alice''s op id');

select public.apply_task_change('0b000000-0000-4000-8000-000000000011',
  tests.task('7a500000-0000-4000-8000-0000000000b1', 'Bob task'), 0);

select tests.ok(
  tests.sqlstate_of($$update public.tasks
    set user_id = 'a11ce000-0000-4000-8000-000000000001', version = version + 1
    where id = '7a500000-0000-4000-8000-0000000000b1'$$) = '42501',
  'Bob cannot hand his task over to Alice');

-- ------------------------------------------------------ anonymous clients

set local role anon;
select set_config('request.jwt.claims', '', true);

select tests.ok(
  tests.sqlstate_of('select count(*) from public.tasks') = '42501',
  'anonymous clients cannot read tasks');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0b000000-0000-4000-8000-000000000012',
    tests.task('7a500000-0000-4000-8000-0000000000c1', 'anon'), 0)$$) = '42501',
  'anonymous clients cannot push');

-- --------------------------------------- Alice again: nothing was touched

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a11ce000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select tests.ok(
  (select title = 'Alice task v3' and version = 3
   from public.tasks where id = '7a500000-0000-4000-8000-0000000000a1'),
  'after all of that, Alice''s task is exactly as she left it');

select tests.ok(
  (select count(*) = 2 from public.tasks),
  'Alice sees only her own two tasks');

-- ---------------------------------------------------------------- schema

reset role;

select tests.ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'tasks'
      and indexdef like '%(user_id, server_updated_at)%'
  ),
  'tasks has an index on (user_id, server_updated_at) for delta pulls');

-- ---------------------------------------------------------------- summary

select current_setting('tests.passed') as passed,
       current_setting('tests.log') as checks;

rollback;
