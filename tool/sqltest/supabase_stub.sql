-- Minimal stand-in for what a Supabase project provides before migrations run,
-- so supabase/migrations and supabase/tests can run on plain Postgres (PGlite).
-- NOT applied to a real project: Supabase already has all of this.

create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

create schema auth;
create table auth.users (
  id    uuid primary key,
  email text unique
);

-- Same definition Supabase uses: the JWT's `sub` claim, as set by PostgREST.
create function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Supabase's default privileges on the public schema: ALL to every API role
-- (this is why the migration revokes TRUNCATE etc. explicitly).
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
