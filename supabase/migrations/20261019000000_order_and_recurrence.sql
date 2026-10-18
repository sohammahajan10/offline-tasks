-- Manual order (fractional index keys) and recurring tasks.
--
-- Run after 20261018000000_tasks_sync.sql. Safe on a project that already has
-- data: existing rows get order keys and a version bump, so devices pull them.

alter table public.tasks
  add column sort_key   text not null default ''
    check (char_length(sort_key) <= 200 and sort_key ~ '^[0-9A-Za-z]*$'),
  add column recurrence text
    check (recurrence in ('daily', 'weekly', 'monthly')),
  add column series_id  uuid,
  add constraint tasks_recurrence_needs_deadline
    check (recurrence is null or due_at is not null);

-- Integer-part key number n in the app's fractional index format
-- ('a0'..'az', then 'b00', …). Same formula as the app's v4 migration, so a
-- device and the server give the same existing task the same key.
create function pg_temp.fi_key(n bigint) returns text
language plpgsql immutable as $$
declare
  digits constant text :=
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  len int := 1;
  cap bigint := 62;
  s text := '';
begin
  while n >= cap loop
    n := n - cap;
    len := len + 1;
    cap := cap * 62;
  end loop;
  for i in 1..len loop
    s := substr(digits, (n % 62)::int + 1, 1) || s;
    n := n / 62;
  end loop;
  return chr(ascii('a') + len - 1) || s;
end $$;

-- Backfill: keys by id within each account. Bumping the version (the trigger
-- requires +1) also moves server_updated_at, so devices pull the new keys.
update public.tasks t
set sort_key = pg_temp.fi_key(r.rn - 1),
    version  = t.version + 1
from (
  select id, row_number() over (partition by user_id order by id) as rn
  from public.tasks
) r
where r.id = t.id and t.sort_key = '';

-- apply_task_change, now also writing sort_key, recurrence and series_id.
-- A payload without one of these keys (an older app) leaves that column as
-- it is instead of clearing it.
create or replace function public.apply_task_change(
  p_op_id        uuid,
  p_task         jsonb,
  p_base_version integer
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
  v_row public.tasks;
  v_inserted integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  v_id := (p_task ->> 'id')::uuid;
  if v_id is null then
    raise exception 'task id is required' using errcode = '22023';
  end if;

  -- 1. Idempotency, enforced by the applied_ops primary key.
  insert into public.applied_ops (op_id, user_id, task_id)
  values (p_op_id, v_uid, v_id)
  on conflict (op_id) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    select t.* into v_row
    from public.applied_ops o
    join public.tasks t on t.id = o.task_id
    where o.op_id = p_op_id and o.task_id = v_id;
    if not found then
      raise exception 'op id % was used for a different task', p_op_id
        using errcode = '23505';
    end if;
    return jsonb_build_object('status', 'duplicate', 'row', to_jsonb(v_row));
  end if;

  -- 2. Lock the row (RLS: only the caller's rows are visible).
  select * into v_row from public.tasks where id = v_id for update;

  if not found then
    insert into public.tasks (
      id, user_id, title, notes, priority, due_at, category, tags,
      completed, is_deleted, version, updated_at,
      sort_key, recurrence, series_id
    ) values (
      v_id,
      v_uid,
      p_task ->> 'title',
      coalesce(p_task ->> 'notes', ''),
      coalesce((p_task ->> 'priority')::smallint, 1),
      (p_task ->> 'due_at')::timestamptz,
      p_task ->> 'category',
      coalesce(array(select jsonb_array_elements_text(p_task -> 'tags')), '{}'),
      coalesce((p_task ->> 'completed')::boolean, false),
      coalesce((p_task ->> 'is_deleted')::boolean, false),
      1,
      (p_task ->> 'updated_at')::timestamptz,
      coalesce(p_task ->> 'sort_key', ''),
      p_task ->> 'recurrence',
      (p_task ->> 'series_id')::uuid
    )
    returning * into v_row;
    return jsonb_build_object('status', 'applied', 'row', to_jsonb(v_row));
  end if;

  -- 3. Optimistic concurrency.
  if v_row.version <> p_base_version then
    raise exception 'stale_version'
      using errcode = 'PT409',
            detail  = to_jsonb(v_row)::text,
            hint    = format('server is at version %s, push was based on %s',
                             v_row.version, p_base_version);
  end if;

  -- 4. Apply.
  update public.tasks set
    title      = p_task ->> 'title',
    notes      = coalesce(p_task ->> 'notes', ''),
    priority   = coalesce((p_task ->> 'priority')::smallint, 1),
    due_at     = (p_task ->> 'due_at')::timestamptz,
    category   = p_task ->> 'category',
    tags       = coalesce(array(select jsonb_array_elements_text(p_task -> 'tags')), '{}'),
    completed  = coalesce((p_task ->> 'completed')::boolean, false),
    is_deleted = coalesce((p_task ->> 'is_deleted')::boolean, false),
    sort_key   = case when p_task ? 'sort_key'
                      then coalesce(p_task ->> 'sort_key', '')
                      else v_row.sort_key end,
    recurrence = case when p_task ? 'recurrence'
                      then p_task ->> 'recurrence'
                      else v_row.recurrence end,
    series_id  = case when p_task ? 'series_id'
                      then (p_task ->> 'series_id')::uuid
                      else v_row.series_id end,
    version    = v_row.version + 1,
    updated_at = (p_task ->> 'updated_at')::timestamptz
  where id = v_id
  returning * into v_row;

  return jsonb_build_object('status', 'applied', 'row', to_jsonb(v_row));
end;
$$;

-- create or replace keeps the existing grants; restated for clarity.
revoke execute on function public.apply_task_change(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.apply_task_change(uuid, jsonb, integer)
  to authenticated;
