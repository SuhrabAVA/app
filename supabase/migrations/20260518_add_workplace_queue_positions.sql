create table if not exists public.workplace_queue_positions (
  id uuid primary key default gen_random_uuid(),
  workplace_id text not null,
  task_id text,
  order_id text not null,
  stage_id text not null,
  stage_group_key text,
  queue_position integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists workplace_queue_positions_task_key
  on public.workplace_queue_positions (workplace_id, task_id)
  where task_id is not null;

create unique index if not exists workplace_queue_positions_stage_key
  on public.workplace_queue_positions (
    workplace_id,
    order_id,
    stage_id,
    coalesce(stage_group_key, '')
  )
  where task_id is null;

create index if not exists workplace_queue_positions_workplace_position_idx
  on public.workplace_queue_positions (workplace_id, queue_position);

alter table public.workplace_queue_positions enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'workplace_queue_positions'
      and policyname = 'workplace_queue_positions_select'
  ) then
    create policy workplace_queue_positions_select
      on public.workplace_queue_positions
      for select
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'workplace_queue_positions'
      and policyname = 'workplace_queue_positions_write'
  ) then
    create policy workplace_queue_positions_write
      on public.workplace_queue_positions
      for all
      using (true)
      with check (true);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'workplace_queue_positions'
  ) then
    alter publication supabase_realtime add table public.workplace_queue_positions;
  end if;
end $$;
