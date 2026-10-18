-- Tests for 20261019000000_order_and_recurrence.sql. Like the other test
-- file: runs locally via tool/sqltest or pasted into the SQL editor, rolls
-- back everything, and the last row lists the checks that passed.

begin;

create schema tests;
grant usage on schema tests to authenticated;

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

create function tests.sqlstate_of(statement text) returns text
language plpgsql as $$
begin
  execute statement;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

create function tests.task(id uuid, title text, extra jsonb default '{}')
returns jsonb language sql as $$
  select jsonb_build_object(
    'id', id, 'title', title, 'notes', '', 'priority', 1,
    'due_at', '2026-10-20T08:00:00Z', 'category', null, 'tags', '[]'::jsonb,
    'completed', false, 'is_deleted', false,
    'updated_at', '2026-10-19T09:00:00Z'
  ) || extra
$$;

grant execute on all functions in schema tests to authenticated;

insert into auth.users (id, email)
values ('a11ce000-0000-4000-8000-000000000001', 'alice@example.test');

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a11ce000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select tests.ok(
  (public.apply_task_change('0c000000-0000-4000-8000-000000000001',
    tests.task('7b500000-0000-4000-8000-000000000001', 'Water plants',
      '{"sort_key": "a0V", "recurrence": "weekly",
        "series_id": "7b500000-0000-4000-8000-000000000001"}'), 0)
    -> 'row') @> '{"sort_key": "a0V", "recurrence": "weekly"}',
  'push stores sort_key, recurrence and series_id');

select tests.ok(
  (public.apply_task_change('0c000000-0000-4000-8000-000000000002',
    tests.task('7b500000-0000-4000-8000-000000000001', 'Water the plants'), 1)
    -> 'row') @> '{"sort_key": "a0V", "recurrence": "weekly", "version": 2}',
  'a payload without the new keys (older app) leaves them unchanged');

select tests.ok(
  (public.apply_task_change('0c000000-0000-4000-8000-000000000003',
    tests.task('7b500000-0000-4000-8000-000000000001', 'Water the plants',
      '{"recurrence": null, "sort_key": "Zz"}'), 2)
    -> 'row') @> '{"sort_key": "Zz", "recurrence": null}',
  'explicit values (including null) are applied');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0c000000-0000-4000-8000-000000000004',
    tests.task('7b500000-0000-4000-8000-000000000002', 'Bad',
      '{"recurrence": "hourly"}'), 0)$$) = '23514',
  'an unknown recurrence is rejected (23514)');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0c000000-0000-4000-8000-000000000005',
    tests.task('7b500000-0000-4000-8000-000000000003', 'No deadline',
      '{"recurrence": "daily", "due_at": null}'), 0)$$) = '23514',
  'a repeating task without a deadline is rejected (23514)');

select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0c000000-0000-4000-8000-000000000006',
    tests.task('7b500000-0000-4000-8000-000000000004', 'Bad key',
      '{"sort_key": "a 0"}'), 0)$$) = '23514',
  'a sort_key with characters outside base 62 is rejected (23514)');

-- Two devices completing the same occurrence offline both push a create for
-- the same deterministic id: the second is a stale push, never a duplicate.
select public.apply_task_change('0c000000-0000-4000-8000-000000000007',
  tests.task('7b500000-0000-4000-8000-000000000005', 'Next occurrence'), 0);
select tests.ok(
  tests.sqlstate_of($$select public.apply_task_change(
    '0c000000-0000-4000-8000-000000000008',
    tests.task('7b500000-0000-4000-8000-000000000005', 'Next occurrence'), 0)$$)
    = 'PT409',
  'a second create for the same occurrence id is a stale push (PT409), not a second row');
select tests.ok(
  (select count(*) = 1 from public.tasks
   where id = '7b500000-0000-4000-8000-000000000005'),
  'there is exactly one row for that occurrence');

reset role;

select current_setting('tests.passed') as passed,
       current_setting('tests.log') as checks;

rollback;
