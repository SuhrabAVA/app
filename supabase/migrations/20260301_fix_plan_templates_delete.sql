-- Fix template deletion in production planning.
-- 1) Ensure soft delete column exists.
-- 2) Ensure RLS policies allow authenticated users to update/delete templates.
-- 3) Make FK orders.stage_template_id nullable on template delete.

alter table if exists public.plan_templates
  add column if not exists is_archived boolean not null default false;

alter table if exists public.plan_templates enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'plan_templates'
      and policyname = 'plan_templates_select'
  ) then
    create policy plan_templates_select
      on public.plan_templates
      for select
      to authenticated
      using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'plan_templates'
      and policyname = 'plan_templates_insert'
  ) then
    create policy plan_templates_insert
      on public.plan_templates
      for insert
      to authenticated
      with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'plan_templates'
      and policyname = 'plan_templates_update'
  ) then
    create policy plan_templates_update
      on public.plan_templates
      for update
      to authenticated
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'plan_templates'
      and policyname = 'plan_templates_delete'
  ) then
    create policy plan_templates_delete
      on public.plan_templates
      for delete
      to authenticated
      using (true);
  end if;
end $$;

-- If orders.stage_template_id references plan_templates with RESTRICT,
-- recreate the FK as ON DELETE SET NULL.
do $$
declare
  rec record;
begin
  for rec in
    select c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where c.contype = 'f'
      and n.nspname = 'public'
      and t.relname = 'orders'
      and c.conkey = array[
        (select a.attnum
         from pg_attribute a
         where a.attrelid = t.oid and a.attname = 'stage_template_id')
      ]
  loop
    execute format('alter table public.orders drop constraint %I', rec.conname);
  end loop;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'orders'
      and column_name = 'stage_template_id'
  ) then
    alter table public.orders
      add constraint orders_stage_template_id_fkey
      foreign key (stage_template_id)
      references public.plan_templates(id)
      on delete set null;
  end if;
end $$;
