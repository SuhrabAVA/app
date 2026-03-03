create table if not exists public.production_queue_state (
  group_id text primary key,
  order_sequence jsonb not null default '[]'::jsonb,
  hidden_order_ids jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default timezone('utc', now())
);

alter table public.production_queue_state enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'production_queue_state'
      and policyname = 'production_queue_state_select'
  ) then
    create policy production_queue_state_select
      on public.production_queue_state
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'production_queue_state'
      and policyname = 'production_queue_state_write'
  ) then
    create policy production_queue_state_write
      on public.production_queue_state
      for all
      using (auth.role() in ('authenticated', 'anon'))
      with check (auth.role() in ('authenticated', 'anon'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'production_queue_state'
  ) then
    alter publication supabase_realtime add table public.production_queue_state;
  end if;
end $$;
