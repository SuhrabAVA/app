alter table if exists public.tasks
  add column if not exists stage_group_key text;

update public.tasks
set stage_group_key = stage_id
where coalesce(stage_group_key, '') = ''
  and coalesce(stage_id, '') <> '';

create index if not exists tasks_order_stage_group_idx
  on public.tasks(order_id, stage_group_key);

alter table if exists public.prod_plan_stages
  add column if not exists stage_id text;

alter table if exists public.prod_plan_stages
  add column if not exists stage_group_key text;

alter table if exists public.prod_plan_stages
  add column if not exists step_no integer;

update public.prod_plan_stages
set stage_group_key = stage_id
where coalesce(stage_group_key, '') = ''
  and coalesce(stage_id, '') <> '';

update public.prod_plan_stages
set step_no = seq
where step_no is null
  and seq is not null;

create index if not exists prod_plan_stages_plan_group_step_idx
  on public.prod_plan_stages(plan_id, stage_group_key, step_no);

do $$
declare
  stage_name_expr text := 'pps.stage_id';
  order_code_expr text := 'null::text';
  workplace_join text := '';
  started_expr text := 'null::text as started_at';
  finished_expr text := 'null::text as finished_at';
  completed_expr text := 'null::text as completed_at';
  executor_expr text := 'null::text as executor_id';
  assigned_expr text := 'null::text as assigned_employee_id';
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders'
      and column_name = 'assignment_id'
  ) then
    order_code_expr := 'o.assignment_id';
  end if;

  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'workplaces'
  ) then
    workplace_join := ' left join public.workplaces w on w.id = pps.stage_id ';
    stage_name_expr := 'coalesce(pps.stage_id, '''')';
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'workplaces'
        and column_name = 'title'
    ) then
      stage_name_expr := 'coalesce(w.title, ' || stage_name_expr || ')';
    end if;
    if exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'workplaces'
        and column_name = 'name'
    ) then
      stage_name_expr := 'coalesce(w.name, ' || stage_name_expr || ')';
    end if;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'stage_name'
  ) then
    stage_name_expr := 'coalesce(pps.stage_name, ' || stage_name_expr || ')';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'name'
  ) then
    stage_name_expr := 'coalesce(pps.name, ' || stage_name_expr || ')';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'started_at'
  ) then
    started_expr := 'pps.started_at';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'finished_at'
  ) then
    finished_expr := 'pps.finished_at';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'completed_at'
  ) then
    completed_expr := 'pps.completed_at';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'executor_id'
  ) then
    executor_expr := 'pps.executor_id';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'prod_plan_stages'
      and column_name = 'assigned_employee_id'
  ) then
    assigned_expr := 'pps.assigned_employee_id';
  end if;

  execute 'drop view if exists public.v_order_plan_stages';

  execute 'create view public.v_order_plan_stages as
    select
      pp.order_id,
      ' || order_code_expr || ' as order_code,
      pp.id as plan_id,
      pps.id as plan_stage_id,
      pps.stage_id,
      coalesce(pps.stage_group_key, pps.stage_id) as stage_group_key,
      ' || stage_name_expr || ' as stage_name,
      coalesce(pps.step_no, pps.seq) as step_no,
      pps.seq,
      pps.status,
      ' || started_expr || ',
      ' || finished_expr || ',
      ' || completed_expr || ',
      ' || executor_expr || ',
      ' || assigned_expr || '
    from public.prod_plans pp
    join public.prod_plan_stages pps on pps.plan_id = pp.id
    left join public.orders o on o.id = pp.order_id'
    || workplace_join;
end $$;

notify pgrst, 'reload schema';
