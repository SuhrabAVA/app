-- Fixed v2: uses pg_policies view (schemaname, tablename, policyname)
-- Avoids joins and works in Supabase Postgres.

create table if not exists public.analytics (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.analytics enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'analytics'
      and policyname = 'analytics_read'
  ) then
    create policy analytics_read on public.analytics
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'analytics'
      and policyname = 'analytics_insert'
  ) then
    create policy analytics_insert on public.analytics
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'analytics'
      and policyname = 'analytics_update'
  ) then
    create policy analytics_update on public.analytics
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'analytics'
      and policyname = 'analytics_delete'
  ) then
    create policy analytics_delete on public.analytics
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.employee_photos (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.employee_photos enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employee_photos'
      and policyname = 'employee_photos_read'
  ) then
    create policy employee_photos_read on public.employee_photos
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employee_photos'
      and policyname = 'employee_photos_insert'
  ) then
    create policy employee_photos_insert on public.employee_photos
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employee_photos'
      and policyname = 'employee_photos_update'
  ) then
    create policy employee_photos_update on public.employee_photos
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employee_photos'
      and policyname = 'employee_photos_delete'
  ) then
    create policy employee_photos_delete on public.employee_photos
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.employees (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.employees enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employees'
      and policyname = 'employees_read'
  ) then
    create policy employees_read on public.employees
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employees'
      and policyname = 'employees_insert'
  ) then
    create policy employees_insert on public.employees
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employees'
      and policyname = 'employees_update'
  ) then
    create policy employees_update on public.employees
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'employees'
      and policyname = 'employees_delete'
  ) then
    create policy employees_delete on public.employees
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.messages (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.messages enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'messages'
      and policyname = 'messages_read'
  ) then
    create policy messages_read on public.messages
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'messages'
      and policyname = 'messages_insert'
  ) then
    create policy messages_insert on public.messages
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'messages'
      and policyname = 'messages_update'
  ) then
    create policy messages_update on public.messages
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'messages'
      and policyname = 'messages_delete'
  ) then
    create policy messages_delete on public.messages
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.order_photos (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.order_photos enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'order_photos'
      and policyname = 'order_photos_read'
  ) then
    create policy order_photos_read on public.order_photos
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'order_photos'
      and policyname = 'order_photos_insert'
  ) then
    create policy order_photos_insert on public.order_photos
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'order_photos'
      and policyname = 'order_photos_update'
  ) then
    create policy order_photos_update on public.order_photos
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'order_photos'
      and policyname = 'order_photos_delete'
  ) then
    create policy order_photos_delete on public.order_photos
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.orders (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.orders enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'orders'
      and policyname = 'orders_read'
  ) then
    create policy orders_read on public.orders
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'orders'
      and policyname = 'orders_insert'
  ) then
    create policy orders_insert on public.orders
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'orders'
      and policyname = 'orders_update'
  ) then
    create policy orders_update on public.orders
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'orders'
      and policyname = 'orders_delete'
  ) then
    create policy orders_delete on public.orders
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.production_plans (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.production_plans enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'production_plans'
      and policyname = 'production_plans_read'
  ) then
    create policy production_plans_read on public.production_plans
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'production_plans'
      and policyname = 'production_plans_insert'
  ) then
    create policy production_plans_insert on public.production_plans
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'production_plans'
      and policyname = 'production_plans_update'
  ) then
    create policy production_plans_update on public.production_plans
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'production_plans'
      and policyname = 'production_plans_delete'
  ) then
    create policy production_plans_delete on public.production_plans
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.returns (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.returns enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'returns'
      and policyname = 'returns_read'
  ) then
    create policy returns_read on public.returns
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'returns'
      and policyname = 'returns_insert'
  ) then
    create policy returns_insert on public.returns
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'returns'
      and policyname = 'returns_update'
  ) then
    create policy returns_update on public.returns
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'returns'
      and policyname = 'returns_delete'
  ) then
    create policy returns_delete on public.returns
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.shipments (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.shipments enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'shipments'
      and policyname = 'shipments_read'
  ) then
    create policy shipments_read on public.shipments
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'shipments'
      and policyname = 'shipments_insert'
  ) then
    create policy shipments_insert on public.shipments
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'shipments'
      and policyname = 'shipments_update'
  ) then
    create policy shipments_update on public.shipments
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'shipments'
      and policyname = 'shipments_delete'
  ) then
    create policy shipments_delete on public.shipments
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.stages (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.stages enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'stages'
      and policyname = 'stages_read'
  ) then
    create policy stages_read on public.stages
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'stages'
      and policyname = 'stages_insert'
  ) then
    create policy stages_insert on public.stages
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'stages'
      and policyname = 'stages_update'
  ) then
    create policy stages_update on public.stages
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'stages'
      and policyname = 'stages_delete'
  ) then
    create policy stages_delete on public.stages
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.suppliers (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.suppliers enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'suppliers'
      and policyname = 'suppliers_read'
  ) then
    create policy suppliers_read on public.suppliers
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'suppliers'
      and policyname = 'suppliers_insert'
  ) then
    create policy suppliers_insert on public.suppliers
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'suppliers'
      and policyname = 'suppliers_update'
  ) then
    create policy suppliers_update on public.suppliers
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'suppliers'
      and policyname = 'suppliers_delete'
  ) then
    create policy suppliers_delete on public.suppliers
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.task_comments (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.task_comments enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'task_comments'
      and policyname = 'task_comments_read'
  ) then
    create policy task_comments_read on public.task_comments
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'task_comments'
      and policyname = 'task_comments_insert'
  ) then
    create policy task_comments_insert on public.task_comments
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'task_comments'
      and policyname = 'task_comments_update'
  ) then
    create policy task_comments_update on public.task_comments
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'task_comments'
      and policyname = 'task_comments_delete'
  ) then
    create policy task_comments_delete on public.task_comments
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.tasks (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.tasks enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tasks'
      and policyname = 'tasks_read'
  ) then
    create policy tasks_read on public.tasks
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tasks'
      and policyname = 'tasks_insert'
  ) then
    create policy tasks_insert on public.tasks
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tasks'
      and policyname = 'tasks_update'
  ) then
    create policy tasks_update on public.tasks
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tasks'
      and policyname = 'tasks_delete'
  ) then
    create policy tasks_delete on public.tasks
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.tmc (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.tmc enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tmc'
      and policyname = 'tmc_read'
  ) then
    create policy tmc_read on public.tmc
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tmc'
      and policyname = 'tmc_insert'
  ) then
    create policy tmc_insert on public.tmc
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tmc'
      and policyname = 'tmc_update'
  ) then
    create policy tmc_update on public.tmc
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'tmc'
      and policyname = 'tmc_delete'
  ) then
    create policy tmc_delete on public.tmc
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

create table if not exists public.workspaces (
  id text primary key,
  data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
alter table public.workspaces enable row level security;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'workspaces'
      and policyname = 'workspaces_read'
  ) then
    create policy workspaces_read on public.workspaces
      for select
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'workspaces'
      and policyname = 'workspaces_insert'
  ) then
    create policy workspaces_insert on public.workspaces
      for insert
      with check (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'workspaces'
      and policyname = 'workspaces_update'
  ) then
    create policy workspaces_update on public.workspaces
      for update
      using (auth.uid() is not null);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'workspaces'
      and policyname = 'workspaces_delete'
  ) then
    create policy workspaces_delete on public.workspaces
      for delete
      using (auth.uid() is not null);
  end if;
end $$;

-- Add explicit columns to analytics if they are missing (as used in your code)
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analytics' and column_name='orderId') then
    alter table public.analytics add column "orderId" text;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analytics' and column_name='stageId') then
    alter table public.analytics add column "stageId" text;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analytics' and column_name='userId') then
    alter table public.analytics add column "userId" text;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analytics' and column_name='action') then
    alter table public.analytics add column "action" text;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='analytics' and column_name='timestamp') then
    alter table public.analytics add column "timestamp" bigint;
  end if;
end $$;