-- Offline-first task sync: tasks, applied op ids, and the atomic push function.
--
-- Contract with the app's sync engine (lib/data/api/remote_api.dart):
--   * Task ids are client-generated UUIDs; the primary key makes a retried
--     insert impossible to duplicate.
--   * apply_task_change() is the only write path the app uses. It is atomic:
--     it records the op id, checks the version and writes the row in one
--     transaction, or does nothing.
--   * A stale base version raises SQLSTATE PT409 (PostgREST answers HTTP 409)
--     with the current row as JSON in DETAIL. Any other error is a real failure.
--   * Deletes are tombstones (is_deleted = true). There is no DELETE policy.

-- --------------------------------------------------------------- tasks

create table public.tasks (
  id                uuid primary key,
  user_id           uuid not null default auth.uid()
                      references auth.users (id) on delete cascade,
  title             text not null check (char_length(btrim(title)) between 1 and 500),
  notes             text not null default '' check (char_length(notes) <= 10000),
  priority          smallint not null default 1 check (priority between 0 and 2),
  due_at            timestamptz,
  category          text check (char_length(category) <= 100),
  tags              text[] not null default '{}' check (cardinality(tags) <= 50),
  completed         boolean not null default false,
  is_deleted        boolean not null default false,
  -- Optimistic concurrency: starts at 1, +1 on every write.
  version           integer not null default 1,
  -- Client edit time; used for last-writer-wins when two devices edit one field.
  updated_at        timestamptz not null,
  -- Server write time, set by trigger; the cursor for delta pulls.
  server_updated_at timestamptz not null default clock_timestamp()
);

comment on table public.tasks is
  'Synced tasks. Written through apply_task_change(); deletes are tombstones.';

create index tasks_user_server_updated_at
  on public.tasks (user_id, server_updated_at);

-- Sets server_updated_at on every write and keeps the version sequence
-- intact even for writes that bypass apply_task_change().
create function public.tasks_before_write() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.version <> 1 then
      raise exception 'a new task starts at version 1, got %', new.version
        using errcode = '22023';
    end if;
  elsif new.version <> old.version + 1 then
    raise exception 'version must go from % to %, got %',
      old.version, old.version + 1, new.version
      using errcode = '22023';
  elsif new.user_id <> old.user_id then
    raise exception 'a task cannot change owner' using errcode = '42501';
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

create trigger tasks_before_write
  before insert or update on public.tasks
  for each row execute function public.tasks_before_write();

-- --------------------------------------------------------- applied_ops

-- Every op id the server has applied. The primary key is what makes a retried
-- push idempotent: the second insert of the same op id conflicts.
create table public.applied_ops (
  op_id      uuid primary key,
  user_id    uuid not null default auth.uid()
               references auth.users (id) on delete cascade,
  task_id    uuid not null,
  applied_at timestamptz not null default now()
);

create index applied_ops_applied_at on public.applied_ops (applied_at);

-- ------------------------------------------------------------------ RLS

alter table public.tasks enable row level security;
alter table public.applied_ops enable row level security;

create policy "tasks: select own" on public.tasks
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy "tasks: insert own" on public.tasks
  for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy "tasks: update own" on public.tasks
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- No delete policy: deletes are tombstones, so no row is ever removed by a client.

create policy "applied_ops: select own" on public.applied_ops
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy "applied_ops: insert own" on public.applied_ops
  for insert to authenticated
  with check (user_id = (select auth.uid()));

-- applied_ops is append-only: no update or delete policy.

-- Supabase grants ALL on new public tables to anon and authenticated, which
-- includes TRUNCATE, and TRUNCATE ignores RLS. Grant only what is needed.
revoke all on public.tasks, public.applied_ops from anon, authenticated;
grant select, insert, update on public.tasks to authenticated;
grant select, insert on public.applied_ops to authenticated;

-- --------------------------------------------------- apply_task_change

-- Applies one queued change from a device. Atomic: on any error nothing is
-- written (including the op id), so the client can safely retry.
--
-- Returns {"status": "applied" | "duplicate", "row": <tasks row>}.
-- Raises:
--   PT409  stale_version   base version is behind; DETAIL = current row JSON
--   42501  not authenticated / row owned by someone else (RLS)
--   23505  task id already used by another account
--   22xxx / 23xxx          invalid payload (fails the same way on retry)
create function public.apply_task_change(
  p_op_id        uuid,
  p_task         jsonb,
  p_base_version integer
) returns jsonb
language plpgsql
security invoker          -- runs as the caller, so RLS applies to every statement
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
    -- Already applied (the client lost our earlier answer): report the
    -- current row without writing anything.
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

  -- 2. Lock the row. RLS hides other users' rows, so "not found" here can
  --    also mean the id belongs to someone else; the insert below then fails
  --    on the primary key (23505).
  select * into v_row from public.tasks where id = v_id for update;

  if not found then
    -- Unknown id: insert at version 1. Tombstones too, so a delete for a task
    -- the server never saw (created and deleted offline) succeeds.
    insert into public.tasks (
      id, user_id, title, notes, priority, due_at, category, tags,
      completed, is_deleted, version, updated_at
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
      (p_task ->> 'updated_at')::timestamptz
    )
    returning * into v_row;
    return jsonb_build_object('status', 'applied', 'row', to_jsonb(v_row));
  end if;

  -- 3. Optimistic concurrency. Raising rolls back the op id insert above,
  --    so the same op can be retried after the client merges.
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
    version    = v_row.version + 1,
    updated_at = (p_task ->> 'updated_at')::timestamptz
  where id = v_id
  returning * into v_row;

  return jsonb_build_object('status', 'applied', 'row', to_jsonb(v_row));
end;
$$;

revoke execute on function public.apply_task_change(uuid, jsonb, integer)
  from public, anon;
grant execute on function public.apply_task_change(uuid, jsonb, integer)
  to authenticated;
