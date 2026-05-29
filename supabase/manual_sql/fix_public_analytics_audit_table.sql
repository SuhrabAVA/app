-- Copy/paste this whole file into the Supabase SQL editor.
-- Do not copy a GitHub diff hunk that starts with "@@ ... @@"; that marker is
-- not SQL and causes: ERROR 42601: syntax error at or near "@@".
-- Also do not copy isolated IF/THEN lines from superbase.sql; run this
-- complete standalone script instead.

create extension if not exists pgcrypto;

create table if not exists public.analytics (
  id uuid primary key default gen_random_uuid(),
  "orderId" text not null default '',
  "stageId" text not null default '',
  "userId" text not null default '',
  action text not null default '',
  category text not null default '',
  details text not null default '',
  "timestamp" bigint not null default (extract(epoch from now()) * 1000)::bigint,
  created_at timestamptz not null default now()
);

alter table public.analytics
  add column if not exists "orderId" text not null default '',
  add column if not exists "stageId" text not null default '',
  add column if not exists "userId" text not null default '',
  add column if not exists action text not null default '',
  add column if not exists category text not null default '',
  add column if not exists details text not null default '',
  add column if not exists "timestamp" bigint not null default (extract(epoch from now()) * 1000)::bigint,
  add column if not exists created_at timestamptz not null default now();

do $$
declare
  id_type text;
begin
  select data_type into id_type
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'analytics'
    and column_name = 'id';

  if id_type = 'uuid' then
    alter table public.analytics alter column id set default gen_random_uuid();
  elsif id_type = 'text' then
    alter table public.analytics alter column id set default gen_random_uuid()::text;
  end if;
end $$;

create index if not exists analytics_user_timestamp_idx
  on public.analytics ("userId", "timestamp" desc);

create index if not exists analytics_order_stage_idx
  on public.analytics ("orderId", "stageId");

alter table public.analytics enable row level security;

drop policy if exists analytics_insert_authenticated on public.analytics;
create policy analytics_insert_authenticated on public.analytics
  for insert
  to authenticated
  with check (true);

drop policy if exists analytics_select_authenticated on public.analytics;
create policy analytics_select_authenticated on public.analytics
  for select
  to authenticated
  using (true);
