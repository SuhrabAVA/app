begin;

do $block$
begin
  if not exists (select 1 from pg_roles where rolname = 'ai_readonly') then
    create role ai_readonly nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'ai_agent_login') then
    create role ai_agent_login nologin inherit;
  end if;
end
$block$;

-- Managed Supabase migration roles may not alter SUPERUSER/BYPASSRLS flags,
-- even when setting them to false. New roles already default to those safe values.
alter role ai_readonly nologin noinherit;
alter role ai_agent_login nologin inherit;

grant ai_readonly to ai_agent_login;

alter role ai_agent_login set default_transaction_read_only = on;
alter role ai_agent_login set statement_timeout = '10s';
alter role ai_agent_login set idle_in_transaction_session_timeout = '30s';
alter role ai_agent_login set work_mem = '32MB';
alter role ai_agent_login set search_path = public, pg_catalog;

revoke all on schema public from ai_readonly;
revoke all on all tables in schema public from ai_readonly;
revoke all on all sequences in schema public from ai_readonly;
revoke all on all functions in schema public from ai_readonly;
grant usage on schema public to ai_readonly;

do $block$
declare
  object_name text;
  allowed_relations constant text[] := array[
    'actual_qty_formulas', 'analytics', 'claims', 'employee_attendance',
    'employee_positions', 'employee_status_history', 'employee_statuses', 'employees',
    'forms', 'forms_series', 'materials', 'materials_arrivals',
    'materials_inventories', 'materials_writeoffs', 'order_consumption_snapshots',
    'order_events', 'order_form_blocks', 'order_option_defs', 'order_option_values',
    'order_paint_pending_writeoffs', 'order_paint_reservations', 'order_paints',
    'order_paper_reservations', 'order_predicates', 'order_shipments', 'orders',
    'paints', 'paints_arrivals', 'paints_inventories', 'paints_writeoffs',
    'paper_items', 'paper_moves', 'papers', 'papers_arrivals', 'papers_inventories',
    'papers_writeoffs', 'positions', 'prod_plan_stages', 'prod_plans',
    'prod_stage_comments', 'prod_stage_history', 'product_type_configs',
    'product_type_form_block_conditions', 'product_type_form_blocks',
    'product_type_stage_conditions', 'product_type_stage_workplaces',
    'product_type_stages', 'production_plans', 'production_queue_state',
    'schema_change_log', 'task_event_requests', 'tasks', 'warehouse_categories',
    'warehouse_category_inventories', 'warehouse_category_items',
    'warehouse_category_writeoffs', 'warehouse_deleted_records', 'work_schedules',
    'workplace_positions', 'workplace_queue_positions', 'workplace_setup_history',
    'workplaces', 'paper_stock_view', 'v_order_plan_stages', 'v_orders_with_form',
    'v_paints', 'v_papers'
  ];
begin
  foreach object_name in array allowed_relations loop
    if to_regclass(format('public.%I', object_name)) is null then
      raise exception 'Allowlisted relation public.% is missing', object_name;
    end if;
    execute format('grant select on table public.%I to ai_readonly', object_name);
  end loop;
end
$block$;

do $block$
declare
  function_name text;
  function_row record;
  found_count integer;
  allowed_functions constant text[] := array[
    'data_health_report', 'find_forms', 'get_order_generation_chain',
    'get_order_restart_history', 'normalize_paint_name', 'order_actual_qty_compute',
    'order_actual_qty_rows', 'order_pack_size', 'order_paint_pending_debt_grams',
    'order_paper_slots', 'order_paper_usage_state', 'order_paper_writeoff_stage_key',
    'order_stage_is_last', 'paint_reservation_has_pending_debt', 'resolve_order_form',
    'safe_paint_id', 'stage_is_packaging', 'task_comment_millis',
    'task_comments_to_array', 'task_finish_record_is_repeat', 'task_iso_utc',
    'task_json_payload', 'task_open_interval_index', 'task_order_quantity_measure',
    'task_quantity_payload', 'task_quantity_share_preview', 'task_quantity_value',
    'validate_product_type_config'
  ];
begin
  foreach function_name in array allowed_functions loop
    found_count := 0;
    for function_row in
      select p.oid::regprocedure as signature
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = function_name
        and p.prokind = 'f'
        and p.provolatile in ('i', 's')
    loop
      execute format('grant execute on function %s to ai_readonly', function_row.signature);
      found_count := found_count + 1;
    end loop;
    if found_count = 0 then
      raise exception 'Allowlisted stable/immutable function public.% is missing', function_name;
    end if;
  end loop;
end
$block$;

commit;
