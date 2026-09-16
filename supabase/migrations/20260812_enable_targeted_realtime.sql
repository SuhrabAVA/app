-- Enable Realtime only for mutable, user-facing tables consumed by the app.
--
-- The block is idempotent and tolerates optional/legacy tables that are not
-- present in every installation. RLS and replica identity are intentionally
-- left unchanged: clients treat events only as invalidation signals and fetch
-- rows again through the existing SELECT paths.
do $$
declare
  qualified_name text;
  schema_name text;
  table_name text;
begin
  if not exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    raise notice 'Publication supabase_realtime does not exist; skipping';
    return;
  end if;

  -- These relations are written/read by explicit commands, but no open UI
  -- owns a realtime refresh path for them. Remove stale publication entries
  -- left by an earlier draft of this migration.
  foreach qualified_name in array array[
    'public.order_files',
    'public.order_events',
    'public.order_paints',
    'public.order_consumption_snapshots',
    'public.order_paint_pending_writeoffs',
    'public.analytics',
    'public.workplace_setup_history'
  ]
  loop
    schema_name := split_part(qualified_name, '.', 1);
    table_name := split_part(qualified_name, '.', 2);
    if exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = schema_name
        and tablename = table_name
    ) then
      execute format(
        'alter publication supabase_realtime drop table %I.%I',
        schema_name,
        table_name
      );
    end if;
  end loop;

  foreach qualified_name in array array[
    -- Orders, workspace and production planning.
    'public.orders',
    'public.tasks',
    'public.task_comment_attachments',
    'public.order_paper_reservations',
    'public.order_paint_reservations',
    'public.prod_plans',
    'public.prod_plan_stages',
    'public.prod_stage_history',
    'public.production_plans',
    'production.plan_stages',
    'public.workplace_queue_positions',
    'public.production_queue_state',
    'public.plan_templates',
    'public.workplace_stages',
    'public.order_stages',

    -- Personnel and workplace dictionaries.
    'public.employees',
    'public.employee_positions',
    'public.positions',
    'public.workplaces',
    'public.workplace_positions',
    'public.terminals',
    'public.terminal_workplaces',
    'public.employee_statuses',
    'public.employee_status_history',
    'public.employee_photos',
    'public.documents',

    -- Warehouse balances, reservations and lazily opened audit logs.
    'public.paints',
    'public.materials',
    'public.papers',
    'public.warehouse_pens',
    'public.warehouse_stationery',
    'public.paints_arrivals',
    'public.materials_arrivals',
    'public.papers_arrivals',
    'public.warehouse_stationery_arrivals',
    'public.warehouse_pens_arrivals',
    'public.paints_writeoffs',
    'public.materials_writeoffs',
    'public.papers_writeoffs',
    'public.warehouse_stationery_writeoffs',
    'public.warehouse_pens_writeoffs',
    'public.paints_inventories',
    'public.materials_inventories',
    'public.papers_inventories',
    'public.warehouse_stationery_inventories',
    'public.warehouse_pens_inventories',
    'public.suppliers',
    'public.warehouse_category_items',
    'public.warehouse_category_writeoffs',
    'public.warehouse_category_inventories',
    'public.warehouse_deleted_records',
    'public.forms',
    'public.forms_series',

    -- Product-type configuration, analytics and scoped chat.
    'public.warehouse_categories',
    'public.order_form_blocks',
    'public.product_type_configs',
    'public.product_type_form_blocks',
    'public.product_type_stages',
    'public.product_type_stage_workplaces',
    'public.product_type_stage_conditions',
    'public.claims',
    'public.employee_month_salary_adjustments',
    'public.employee_status_pay_rates',
    'public.salary_settings',
    'public.work_schedules',
    'public.workplace_coefficients',
    'public.chat_messages'
  ]
  loop
    schema_name := split_part(qualified_name, '.', 1);
    table_name := split_part(qualified_name, '.', 2);

    if to_regclass(format('%I.%I', schema_name, table_name)) is null then
      raise notice 'Realtime table %.% is absent; skipping', schema_name, table_name;
      continue;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = schema_name
        and tablename = table_name
    ) then
      execute format(
        'alter publication supabase_realtime add table %I.%I',
        schema_name,
        table_name
      );
    end if;
  end loop;
end
$$;

-- The client uses this allow-list to avoid binding an optional legacy table
-- that is absent (or deliberately not published) and taking down its whole
-- domain channel. Only relation identifiers are exposed; no row data or policy
-- information is returned. SECURITY INVOKER avoids a needless privilege
-- boundary for catalog metadata that PostgreSQL already exposes to the caller.
drop function if exists public.realtime_sync_published_tables();

create or replace function public.realtime_sync_published_tables()
returns table(schema_name text, table_name text)
language sql
stable
security invoker
set search_path = pg_catalog
as $$
  select schemaname::text, tablename::text
  from pg_catalog.pg_publication_tables
  where pubname = 'supabase_realtime'
    and schemaname in ('public', 'production')
$$;

revoke all on function public.realtime_sync_published_tables() from public;
revoke all on function public.realtime_sync_published_tables() from anon;
grant execute on function public.realtime_sync_published_tables() to authenticated;
