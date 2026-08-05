-- Снимок определений public-функций Supabase
-- Снят: 2026-08-05 05:21 UTC
-- Проект: postgres
-- Функций: 68
-- Сгенерировано: scripts/dump_supabase_functions.sql
--
-- ЭТО СНИМОК ПРОДА, НЕ МИГРАЦИЯ.
-- Не применять на чистой базе как есть: порядок и зависимости здесь не
-- восстанавливаются, таблиц и типов файл не создаёт. Только для чтения и
-- сравнения версий.
--
-- Новые функции создавать миграцией в supabase/migrations/.

-- ==========================================================================
-- _infer_template_id_from_order(o orders)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public._infer_template_id_from_order(o orders)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_tid uuid;
  v_txt text;
begin
  v_tid := o.prod_template_id;
  if v_tid is not null then
    return v_tid;
  end if;

  -- try product JSON keys
  v_txt := coalesce(o.product->>'template_id', o.product->>'templateId', o.product->>'prod_template_id');
  if v_txt is not null then
    begin
      v_tid := v_txt::uuid;
      return v_tid;
    exception when others then
      -- ignore cast errors
      null;
    end;
  end if;

  -- Try by template name in JSON: product.planName / templateName
  v_txt := coalesce(o.product->>'planName', o.product->>'templateName');
  if v_txt is not null then
    select id into v_tid from public.prod_templates where lower(name) = lower(v_txt) limit 1;
    if v_tid is not null then
      return v_tid;
    end if;
  end if;

  return null;
end $function$
;

-- ==========================================================================
-- advance_order_after_task_completion(p_order_id text, p_stage_id text, p_stage_group_key text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.advance_order_after_task_completion(p_order_id text, p_stage_id text, p_stage_group_key text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_group_key text := coalesce(nullif(trim(p_stage_group_key), ''), nullif(trim(p_stage_id), ''));
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_now_iso timestamptz := clock_timestamp();
  v_plan_id text;
  v_completed_all_stage boolean;
  v_has_pending_after boolean;
  v_actual_qty double precision;
  v_order_completed boolean;
begin
  if coalesce(trim(p_order_id), '') = '' or coalesce(trim(p_stage_id), '') = '' then
    return;
  end if;

  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tasks' and column_name = 'completed_at'
  ) then
    update tasks
       set status = 'completed',
           started_at = null,
           completed_at = v_now_ms
     where order_id::text = p_order_id
       and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key
       and status <> 'completed';
  else
    update tasks
       set status = 'completed',
           started_at = null
     where order_id::text = p_order_id
       and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key
       and status <> 'completed';
  end if;

  if to_regclass('public.prod_plans') is not null and to_regclass('public.prod_plan_stages') is not null then
    select id::text into v_plan_id
      from public.prod_plans
     where order_id::text = p_order_id
     limit 1;

    if v_plan_id is not null then
      if exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'prod_plan_stages' and column_name = 'finished_at'
      ) and exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'prod_plan_stages' and column_name = 'completed_at'
      ) then
        update public.prod_plan_stages
           set status = 'completed', finished_at = v_now_iso, completed_at = v_now_iso
         where plan_id::text = v_plan_id
           and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key;
      elsif exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'prod_plan_stages' and column_name = 'finished_at'
      ) then
        update public.prod_plan_stages
           set status = 'completed', finished_at = v_now_iso
         where plan_id::text = v_plan_id
           and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key;
      elsif exists (
        select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'prod_plan_stages' and column_name = 'completed_at'
      ) then
        update public.prod_plan_stages
           set status = 'completed', completed_at = v_now_iso
         where plan_id::text = v_plan_id
           and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key;
      else
        update public.prod_plan_stages
           set status = 'completed'
         where plan_id::text = v_plan_id
           and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key;
      end if;
    end if;
  end if;

  select bool_and(status = 'completed')
    into v_completed_all_stage
    from tasks
   where order_id::text = p_order_id
     and stage_id::text = p_stage_id;

  if coalesce(v_completed_all_stage, false) then
    select exists(
      select 1 from tasks
       where order_id::text = p_order_id
         and stage_id::text <> p_stage_id
         and status <> 'completed'
    ) into v_has_pending_after;

    if not v_has_pending_after then
      select coalesce(sum(qty), 0) into v_actual_qty
        from (
          select case
            when exists (
              select 1 from jsonb_array_elements(public.task_comments_to_array(comments)) c
               where c->>'type' = 'quantity_team_total'
            ) then (
              select public.task_quantity_value(c->>'text')
                from jsonb_array_elements(public.task_comments_to_array(comments)) c
               where c->>'type' = 'quantity_team_total'
               order by coalesce((c->>'timestamp')::bigint, 0) desc
               limit 1
            )
            else (
              select coalesce(sum(public.task_quantity_value(c->>'text')), 0)
                from jsonb_array_elements(public.task_comments_to_array(comments)) c
               where c->>'type' = 'quantity_done'
            )
          end as qty
          from tasks
          where order_id::text = p_order_id and stage_id::text = p_stage_id
        ) s;

      update orders
         set actual_qty = v_actual_qty
       where id::text = p_order_id;
    end if;
  end if;

  select bool_and(status = 'completed')
    into v_order_completed
    from tasks
   where order_id::text = p_order_id;

  if coalesce(v_order_completed, false) then
    update orders
       set status = 'completed'
     where id::text = p_order_id;

    if to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
    end if;
  end if;
end;
$function$
;

-- ==========================================================================
-- apply_customer_to_flex_paint_writeoff_reason()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.apply_customer_to_flex_paint_writeoff_reason()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prefix constant text := 'Списание флексопечати по заказу ';
  v_queue_suffix constant text := ' из очереди';
  v_source_order_id text;
  v_reason_suffix text := '';
  v_customer text;
begin
  if new.reason is null or new.reason not like v_prefix || '%' then
    return new;
  end if;

  v_source_order_id := trim(substr(new.reason, char_length(v_prefix) + 1));
  if v_source_order_id = '' then
    return new;
  end if;

  if right(v_source_order_id, char_length(v_queue_suffix)) = v_queue_suffix then
    v_source_order_id := trim(left(v_source_order_id, char_length(v_source_order_id) - char_length(v_queue_suffix)));
    v_reason_suffix := v_queue_suffix;
  end if;

  if v_source_order_id = '' then
    return new;
  end if;

  select nullif(trim(o.customer), '')
    into v_customer
    from public.orders o
   where o.id::text = v_source_order_id
   limit 1;

  if v_customer is not null then
    new.reason := format('%s%s%s', v_prefix, v_customer, v_reason_suffix);
  end if;

  return new;
end;
$function$
;

-- ==========================================================================
-- apply_template_to_order(p_order_id uuid, p_template_id uuid, p_by_name text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.apply_template_to_order(p_order_id uuid, p_template_id uuid, p_by_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_stages jsonb;
  v_name   text;
begin
  select t.stages, t.name into v_stages, v_name
  from public.plan_templates t
  where t.id = p_template_id;

  if v_stages is null then
    raise exception 'Template % not found or has no stages', p_template_id;
  end if;

  -- Upsert production plan
  insert into public.production_plans(order_id, stages, template_id, template_name, by_name, updated_at)
  values (p_order_id, v_stages, p_template_id, v_name, p_by_name, now())
  on conflict (order_id) do update
    set stages       = excluded.stages,
        template_id  = excluded.template_id,
        template_name= excluded.template_name,
        by_name      = excluded.by_name,
        updated_at   = now();
end;
$function$
;

-- ==========================================================================
-- arrival_add(_type text, _item uuid, _qty numeric, _note text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.arrival_add(_type text, _item uuid, _qty numeric, _note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if _type = 'paint' then
    insert into public.paints_arrivals(paint_id, qty, note, created_by) values (_item, _qty, _note, auth.uid());
  elsif _type = 'material' then
    insert into public.materials_arrivals(material_id, qty, note, created_by) values (_item, _qty, _note, auth.uid());
  elsif _type = 'paper' then
    insert into public.papers_arrivals(paper_id, qty, note, created_by) values (_item, _qty, _note, auth.uid());
  elsif _type = 'stationery' then
    insert into public.warehouse_stationery_arrivals(item_id, qty, note, created_by) values (_item, _qty, _note, auth.uid());
  end if;
end $function$
;

-- ==========================================================================
-- arrival_add(_type text, _item uuid, _qty numeric, _note text, _by_name text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.arrival_add(_type text, _item uuid, _qty numeric, _note text DEFAULT NULL::text, _by_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if _type = 'paint' then
    insert into public.paints_arrivals(paint_id, qty, note, created_by, by_name)
    values (_item, _qty, _note, auth.uid(), _by_name);
  elsif _type = 'material' then
    insert into public.materials_arrivals(material_id, qty, note, created_by, by_name)
    values (_item, _qty, _note, auth.uid(), _by_name);
  elsif _type = 'paper' then
    insert into public.papers_arrivals(paper_id, qty, note, created_by, by_name)
    values (_item, _qty, _note, auth.uid(), _by_name);
  elsif _type = 'stationery' then
    insert into public.warehouse_stationery_arrivals(item_id, qty, note, created_by, by_name)
    values (_item, _qty, _note, auth.uid(), _by_name);
  end if;
end $function$
;

-- ==========================================================================
-- complete_flex_printing_stage(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_paint_usages jsonb, p_quantity_done text, p_comment text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.complete_flex_printing_stage(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_paint_usages jsonb DEFAULT '[]'::jsonb, p_quantity_done text DEFAULT NULL::text, p_comment text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record;
  rel record;
  v_reserved_other double precision;
  v_available double precision;
  v_paint_name text;
  v_total_qty double precision;
  v_stock_name text;
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_comments jsonb;
  v_touched public.paints.id%type[] := '{}';
  v_order_id public.orders.id%type;
begin
  if coalesce(trim(p_task_id), '') = '' then raise exception 'task_id is required'; end if;
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  v_order_id := trim(p_order_id);
  if p_paint_usages is null then p_paint_usages := '[]'::jsonb; end if;

  perform 1 from tasks where id::text = p_task_id and order_id::text = p_order_id for update;
  if not found then
    raise exception 'Задача % не найдена для заказа %.', p_task_id, p_order_id;
  end if;

  for rec in
    with requested as (
      select
        public.safe_paint_id(coalesce(value->>'paint_id', value->>'material_id')) as paint_id,
        nullif(trim(coalesce(value->>'paint_name', value->>'name')), '') as paint_name,
        coalesce(
          nullif(value->>'used_qty', '')::double precision,
          nullif(value->>'qty', '')::double precision,
          nullif(value->>'qty_g', '')::double precision,
          nullif(value->>'qty_grams', '')::double precision,
          nullif(value->>'qty_kg', '')::double precision * 1000,
          0
        ) as qty
      from jsonb_array_elements(p_paint_usages)
    ), resolved as (
      select coalesce(req.paint_id, p_by_name.id) as paint_id,
             coalesce(req.paint_name, p_by_name.description) as paint_name,
             req.qty
      from requested req
      left join lateral (
        select p.id, p.description
          from paints p
         where req.paint_id is null
           and req.paint_name is not null
           and lower(trim(p.description)) = lower(trim(req.paint_name))
         order by p.id
         limit 1
      ) p_by_name on true
      where req.paint_id is not null or req.paint_name is not null
    ), aggregated as (
      select paint_id, max(paint_name) as paint_name, sum(qty) as qty
      from resolved
      group by paint_id
    )
    select a.paint_id, a.paint_name, a.qty, p.quantity as total_qty, p.description as stock_name
    from aggregated a
    left join paints p on p.id = a.paint_id
    order by a.paint_id nulls last, a.paint_name
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя списать отрицательное количество краски (%).', coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
    end if;
    if rec.qty = 0 then
      continue;
    end if;
    if rec.paint_id is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select p.quantity, p.description
      into v_total_qty, v_stock_name
      from paints p
     where p.id = rec.paint_id
     for update;

    if not found or v_total_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id::text <> p_order_id;

    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paint_name := coalesce(v_stock_name, rec.stock_name, rec.paint_name, rec.paint_id::text);
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %',
        v_paint_name, round(v_available::numeric, 2), round(rec.qty::numeric, 2);
    end if;

    insert into paints_writeoffs(paint_id, qty, reason, by_name)
    values (
      rec.paint_id,
      rec.qty,
      format('Списание флексопечати по заказу %s', p_order_id),
      coalesce(nullif(trim(p_actor), ''), nullif(trim(p_employee_id), ''), 'system')
    );

    update paints
       set quantity = greatest(quantity - rec.qty, 0)
     where id = rec.paint_id;

    update order_paint_reservations
       set used_qty = rec.qty,
           released_qty = greatest(reserved_qty - rec.qty, 0),
           paint_name = coalesce(paint_name, rec.paint_name, v_stock_name, rec.stock_name),
           updated_at = now()
     where order_id::text = p_order_id and paint_id = rec.paint_id;

    if not found then
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (v_order_id, rec.paint_id, coalesce(rec.paint_name, v_stock_name, rec.stock_name), rec.qty, rec.qty, 0)
      on conflict (order_id, paint_id) where paint_id is not null
      do update set used_qty = excluded.used_qty,
                    released_qty = greatest(order_paint_reservations.reserved_qty - excluded.used_qty, 0),
                    updated_at = now();
    end if;

    v_touched := array_append(v_touched, rec.paint_id);
  end loop;

  for rel in
    select paint_id
      from order_paint_reservations
     where order_id::text = p_order_id
       and greatest(reserved_qty - used_qty - released_qty, 0) > 0
     for update
  loop
    update order_paint_reservations
       set released_qty = greatest(reserved_qty - used_qty, 0),
           updated_at = now()
     where order_id::text = p_order_id and paint_id = rel.paint_id;
    v_touched := array_append(v_touched, rel.paint_id);
  end loop;

  perform recalculate_paint_reserved_qty((select array_agg(distinct x) from unnest(v_touched) as x where x is not null));

  select coalesce(comments::jsonb, '[]'::jsonb) into v_comments
    from tasks
   where id::text = p_task_id
   for update;

  if p_quantity_done is not null and trim(p_quantity_done) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_done',
      'text', p_quantity_done,
      'userId', coalesce(nullif(trim(p_employee_id), ''), nullif(trim(p_actor), ''), 'system'),
      'timestamp', v_now_ms
    ));
  end if;

  if p_comment is not null and trim(p_comment) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'finish_note',
      'text', p_comment,
      'userId', coalesce(nullif(trim(p_employee_id), ''), nullif(trim(p_actor), ''), 'system'),
      'timestamp', v_now_ms + 1
    ));
  end if;

  update tasks
     set status = 'completed',
         started_at = null,
         comments = v_comments
   where id::text = p_task_id;

  update tasks
     set status = 'completed', started_at = null
   where order_id::text = p_order_id
     and stage_id::text = p_stage_id
     and id::text <> p_task_id
     and status <> 'completed';
end;
$function$
;

-- ==========================================================================
-- complete_flex_printing_stage_with_paint_queue(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_current_order_rows jsonb, p_pending_rows jsonb, p_quantity_done text, p_comment text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.complete_flex_printing_stage_with_paint_queue(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_current_order_rows jsonb DEFAULT '[]'::jsonb, p_pending_rows jsonb DEFAULT '[]'::jsonb, p_quantity_done text DEFAULT NULL::text, p_comment text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task tasks%rowtype;
  v_pending order_paint_pending_writeoffs%rowtype;
  rec record;
  v_paint_id public.paints.id%type;
  v_paint_name text;
  v_stock_name text;
  v_stock_qty double precision;
  v_reserved_other double precision;
  v_available double precision;
  v_amount double precision;
  v_source_order_id text;
  v_source_task_id text;
  v_pending_writeoff_id uuid;
  v_unit text;
  v_rows_updated integer;
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_comments jsonb;
  v_touched public.paints.id%type[] := '{}';
  v_user_id text := coalesce(nullif(trim(p_employee_id), ''), nullif(trim(p_actor), ''), 'system');
  v_assignee text;
  v_current_written_off_by_order jsonb := '{}'::jsonb;
  v_current_pending_by_order jsonb := '{}'::jsonb;
  v_deferred_written_off_by_order jsonb := '{}'::jsonb;
  v_summary_item text;
  v_amount_text text;
  v_written_text text;
  v_pending_text text;
  v_event_order_id text;
  v_event_items jsonb;
  v_event_message text;
begin
  if coalesce(trim(p_task_id), '') = '' then raise exception 'task_id is required'; end if;
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  if coalesce(trim(p_stage_id), '') = '' then raise exception 'stage_id is required'; end if;
  if p_current_order_rows is null then p_current_order_rows := '[]'::jsonb; end if;
  if p_pending_rows is null then p_pending_rows := '[]'::jsonb; end if;

  select * into v_task
    from tasks
   where id::text = p_task_id and order_id::text = p_order_id and stage_id::text = p_stage_id
   for update;
  if not found then
    raise exception 'Задача % не найдена для заказа %.', p_task_id, p_order_id;
  end if;
  if v_task.status = 'completed' then
    raise exception 'Этап уже завершен.';
  end if;
  if v_task.status not in ('inProgress', 'paused', 'problem', 'waiting', 'pending', 'planned') then
    raise exception 'Нельзя завершить этап из статуса %.', v_task.status;
  end if;
  if v_user_id <> 'system' and array_position(coalesce(v_task.assignees, array[]::text[]), v_user_id) is null then
    raise exception 'Сотрудник не назначен исполнителем этапа.';
  end if;

  -- Rows of the current order that were intentionally left unchecked become queued write-offs.
  for rec in
    select value as row_data
      from jsonb_array_elements(p_current_order_rows) value
     where coalesce((value->>'write_off_now')::boolean, false) = false
  loop
    v_paint_id := null;
    v_paint_name := null;
    v_stock_name := null;
    v_stock_qty := null;
    v_amount := null;
    v_source_order_id := coalesce(nullif(trim(rec.row_data->>'source_order_id'), ''), p_order_id);
    v_source_task_id := coalesce(nullif(trim(rec.row_data->>'source_task_id'), ''), p_task_id);
    v_paint_id := public.safe_paint_id(coalesce(rec.row_data->>'paint_id', rec.row_data->>'material_id'));
    v_paint_name := nullif(trim(coalesce(rec.row_data->>'paint_name', rec.row_data->>'name')), '');
    v_amount := coalesce(
      nullif(rec.row_data->>'actual_used_amount', '')::double precision,
      nullif(rec.row_data->>'planned_amount', '')::double precision,
      nullif(rec.row_data->>'planned_qty', '')::double precision,
      nullif(rec.row_data->>'reserved_qty', '')::double precision,
      nullif(rec.row_data->>'qty_kg', '')::double precision * 1000
    );
    v_unit := coalesce(nullif(trim(rec.row_data->>'unit'), ''), 'г');

    if v_paint_id is null and coalesce(v_paint_name, '') = '' then
      continue;
    end if;
    if v_amount is not null and v_amount < 0 then
      raise exception 'Нельзя поставить в очередь отрицательный расход краски (%).', coalesce(v_paint_name, v_paint_id::text);
    end if;

    if v_paint_id is not null then
      insert into order_paint_pending_writeoffs(
        order_id, task_id, stage_id, stage_name, paint_id, paint_name,
        planned_amount, actual_used_amount, unit, status, created_by, comment
      )
      values (
        v_source_order_id,
        v_source_task_id,
        p_stage_id,
        p_stage_id,
        v_paint_id,
        v_paint_name,
        coalesce(nullif(rec.row_data->>'planned_amount', '')::double precision, v_amount),
        v_amount,
        v_unit,
        'pending',
        v_user_id,
        'Создано при завершении флексопечати без немедленного списания'
      )
      on conflict (
        order_id,
        (coalesce(task_id, '')),
        (coalesce(stage_id, '')),
        paint_id
      ) where status = 'pending' and paint_id is not null
      do update set
        paint_name = coalesce(excluded.paint_name, order_paint_pending_writeoffs.paint_name),
        planned_amount = excluded.planned_amount,
        actual_used_amount = excluded.actual_used_amount,
        unit = excluded.unit,
        updated_at = now();
    else
      insert into order_paint_pending_writeoffs(
        order_id, task_id, stage_id, stage_name, paint_id, paint_name,
        planned_amount, actual_used_amount, unit, status, created_by, comment
      )
      values (
        v_source_order_id,
        v_source_task_id,
        p_stage_id,
        p_stage_id,
        null,
        v_paint_name,
        coalesce(nullif(rec.row_data->>'planned_amount', '')::double precision, v_amount),
        v_amount,
        v_unit,
        'pending',
        v_user_id,
        'Создано при завершении флексопечати без немедленного списания'
      )
      on conflict (
        order_id,
        (coalesce(task_id, '')),
        (coalesce(stage_id, '')),
        (lower(trim(paint_name)))
      ) where status = 'pending'
          and paint_id is null
          and coalesce(trim(paint_name), '') <> ''
      do update set
        planned_amount = excluded.planned_amount,
        actual_used_amount = excluded.actual_used_amount,
        unit = excluded.unit,
        updated_at = now();
    end if;

    v_amount_text := case
      when v_amount is null then 'не указан расход'
      else trim(to_char(round(v_amount::numeric, 2), 'FM999999999990.##')) || ' ' || v_unit
    end;
    v_summary_item := format('%s: %s', coalesce(v_paint_name, v_paint_id::text, 'без названия'), v_amount_text);
    v_current_pending_by_order := jsonb_set(
      v_current_pending_by_order,
      array[v_source_order_id],
      coalesce(v_current_pending_by_order -> v_source_order_id, '[]'::jsonb) || jsonb_build_array(v_summary_item),
      true
    );
  end loop;

  -- Current-order rows checked by the operator are written off immediately.
  for rec in
    select value as row_data
      from jsonb_array_elements(p_current_order_rows) value
     where coalesce((value->>'write_off_now')::boolean, false) = true
  loop
    v_paint_id := null;
    v_paint_name := null;
    v_stock_name := null;
    v_stock_qty := null;
    v_amount := null;
    v_source_order_id := coalesce(nullif(trim(rec.row_data->>'source_order_id'), ''), p_order_id);
    v_paint_id := public.safe_paint_id(coalesce(rec.row_data->>'paint_id', rec.row_data->>'material_id'));
    v_paint_name := nullif(trim(coalesce(rec.row_data->>'paint_name', rec.row_data->>'name')), '');
    v_amount := coalesce(
      nullif(rec.row_data->>'actual_used_amount', '')::double precision,
      nullif(rec.row_data->>'used_qty', '')::double precision,
      nullif(rec.row_data->>'qty_g', '')::double precision,
      nullif(rec.row_data->>'qty_grams', '')::double precision,
      nullif(rec.row_data->>'qty_kg', '')::double precision * 1000,
      0
    );
    if v_amount <= 0 then
      raise exception 'Для краски % укажите фактический расход больше 0.', coalesce(v_paint_name, v_paint_id::text, 'без названия');
    end if;

    if v_paint_id is null then
      select p.id, p.description into v_paint_id, v_paint_name
        from paints p
       where v_paint_name is not null and lower(trim(p.description)) = lower(trim(v_paint_name))
       order by p.id
       limit 1
       for update;
    else
      select p.description, p.quantity into v_stock_name, v_stock_qty
        from paints p
       where p.id = v_paint_id
       for update;
    end if;
    if v_stock_qty is null then
      select p.description, p.quantity into v_stock_name, v_stock_qty
        from paints p
       where p.id = v_paint_id
       for update;
    end if;
    if v_paint_id is null or v_stock_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(v_paint_name, v_paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = v_paint_id
       and r.order_id::text <> v_source_order_id;
    v_available := v_stock_qty - v_reserved_other;
    if v_available < v_amount then
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %',
        coalesce(v_stock_name, v_paint_name, v_paint_id::text), round(v_available::numeric, 2), round(v_amount::numeric, 2);
    end if;

    insert into paints_writeoffs(paint_id, qty, reason, by_name)
    values (
      v_paint_id,
      v_amount,
      format('Списание флексопечати по заказу %s', v_source_order_id),
      coalesce(nullif(trim(p_actor), ''), nullif(trim(p_employee_id), ''), 'system')
    );

    update paints set quantity = greatest(quantity - v_amount, 0) where id = v_paint_id;

    update order_paint_reservations
       set used_qty = v_amount,
           released_qty = greatest(reserved_qty - v_amount, 0),
           paint_name = coalesce(paint_name, v_paint_name, v_stock_name),
           updated_at = now()
     where order_id::text = v_source_order_id and paint_id = v_paint_id;
    if not found then
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (v_source_order_id, v_paint_id, coalesce(v_paint_name, v_stock_name), v_amount, v_amount, 0)
      on conflict (order_id, paint_id) where paint_id is not null
      do update set used_qty = excluded.used_qty,
                    released_qty = greatest(order_paint_reservations.reserved_qty - excluded.used_qty, 0),
                    updated_at = now();
    end if;
    v_touched := array_append(v_touched, v_paint_id);

    v_unit := coalesce(nullif(trim(rec.row_data->>'unit'), ''), 'г');
    v_amount_text := trim(to_char(round(v_amount::numeric, 2), 'FM999999999990.##')) || ' ' || v_unit;
    v_summary_item := format('%s: %s', coalesce(v_paint_name, v_stock_name, v_paint_id::text, 'без названия'), v_amount_text);
    v_current_written_off_by_order := jsonb_set(
      v_current_written_off_by_order,
      array[v_source_order_id],
      coalesce(v_current_written_off_by_order -> v_source_order_id, '[]'::jsonb) || jsonb_build_array(v_summary_item),
      true
    );
  end loop;

  -- Previously queued rows are locked and may be consumed only while still pending.
  for rec in
    select value as row_data
      from jsonb_array_elements(p_pending_rows) value
     where coalesce((value->>'write_off_now')::boolean, false) = true
  loop
    v_paint_id := null;
    v_paint_name := null;
    v_stock_name := null;
    v_stock_qty := null;
    v_amount := null;
    v_pending_writeoff_id := nullif(trim(rec.row_data->>'pending_writeoff_id'), '')::uuid;
    if v_pending_writeoff_id is null then
      raise exception 'Для строки очереди списания не указан pending_writeoff_id.';
    end if;

    select * into v_pending
      from order_paint_pending_writeoffs
     where id = v_pending_writeoff_id
     for update;
    if not found then
      raise exception 'Очередь списания % не найдена.', v_pending_writeoff_id;
    end if;
    if v_pending.status <> 'pending' then
      raise exception 'Краска по заказу % уже обработана или имеет статус %, повторное списание запрещено.', v_pending.order_id, v_pending.status;
    end if;

    -- Pending write-off ownership comes only from order_paint_pending_writeoffs,
    -- never from task comments or client-supplied source fields.
    v_source_order_id := v_pending.order_id;
    v_source_task_id := v_pending.task_id;
    v_paint_id := coalesce(public.safe_paint_id(rec.row_data->>'paint_id'), v_pending.paint_id);
    v_paint_name := coalesce(nullif(trim(rec.row_data->>'paint_name'), ''), v_pending.paint_name);
    v_amount := coalesce(
      nullif(rec.row_data->>'actual_used_amount', '')::double precision,
      v_pending.actual_used_amount,
      v_pending.planned_amount,
      0
    );
    if v_amount <= 0 then
      raise exception 'Для очереди списания % укажите фактический расход больше 0.', v_pending_writeoff_id;
    end if;

    if v_paint_id is null then
      select p.id, p.description, p.quantity into v_paint_id, v_stock_name, v_stock_qty
        from paints p
       where v_paint_name is not null and lower(trim(p.description)) = lower(trim(v_paint_name))
       order by p.id
       limit 1
       for update;
    else
      select p.description, p.quantity into v_stock_name, v_stock_qty
        from paints p
       where p.id = v_paint_id
       for update;
    end if;
    if v_paint_id is null or v_stock_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(v_paint_name, v_paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = v_paint_id
       and r.order_id::text <> v_source_order_id;
    v_available := v_stock_qty - v_reserved_other;
    if v_available < v_amount then
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %',
        coalesce(v_stock_name, v_paint_name, v_paint_id::text), round(v_available::numeric, 2), round(v_amount::numeric, 2);
    end if;

    insert into paints_writeoffs(paint_id, qty, reason, by_name)
    values (
      v_paint_id,
      v_amount,
      format('Списание флексопечати по заказу %s из очереди', v_source_order_id),
      coalesce(nullif(trim(p_actor), ''), nullif(trim(p_employee_id), ''), 'system')
    );

    update paints set quantity = greatest(quantity - v_amount, 0) where id = v_paint_id;

    update order_paint_reservations
       set used_qty = v_amount,
           released_qty = greatest(reserved_qty - v_amount, 0),
           paint_name = coalesce(paint_name, v_paint_name, v_stock_name),
           updated_at = now()
     where order_id::text = v_source_order_id and paint_id = v_paint_id;
    if not found then
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (v_source_order_id, v_paint_id, coalesce(v_paint_name, v_stock_name), v_amount, v_amount, 0)
      on conflict (order_id, paint_id) where paint_id is not null
      do update set used_qty = excluded.used_qty,
                    released_qty = greatest(order_paint_reservations.reserved_qty - excluded.used_qty, 0),
                    updated_at = now();
    end if;

    update order_paint_pending_writeoffs
       set status = 'written_off',
           paint_id = v_paint_id,
           paint_name = coalesce(v_paint_name, v_stock_name),
           actual_used_amount = v_amount,
           unit = coalesce(nullif(trim(rec.row_data->>'unit'), ''), v_pending.unit, 'г'),
           written_off_at = now(),
           written_off_by = v_user_id,
           updated_at = now()
     where id = v_pending_writeoff_id
       and status = 'pending';
    get diagnostics v_rows_updated = row_count;
    if v_rows_updated = 0 then
      raise exception 'Очередь списания % уже обработана, повторное списание запрещено.', v_pending_writeoff_id;
    end if;

    v_touched := array_append(v_touched, v_paint_id);

    v_unit := coalesce(nullif(trim(rec.row_data->>'unit'), ''), v_pending.unit, 'г');
    v_amount_text := trim(to_char(round(v_amount::numeric, 2), 'FM999999999990.##')) || ' ' || v_unit;
    v_summary_item := format('%s: %s', coalesce(v_paint_name, v_stock_name, v_paint_id::text, 'без названия'), v_amount_text);
    v_deferred_written_off_by_order := jsonb_set(
      v_deferred_written_off_by_order,
      array[v_source_order_id],
      coalesce(v_deferred_written_off_by_order -> v_source_order_id, '[]'::jsonb) || jsonb_build_array(v_summary_item),
      true
    );
  end loop;

  for rec in
    select paint_id
      from order_paint_reservations
     where order_id::text = p_order_id
       and greatest(reserved_qty - used_qty - released_qty, 0) > 0
     for update
  loop
    update order_paint_reservations
       set released_qty = greatest(reserved_qty - used_qty, 0),
           updated_at = now()
     where order_id::text = p_order_id and paint_id = rec.paint_id;
    v_touched := array_append(v_touched, rec.paint_id);
  end loop;

  perform recalculate_paint_reserved_qty((select array_agg(distinct x) from unnest(v_touched) as x where x is not null));

  v_written_text := coalesce((
    select string_agg(elem.item #>> '{}', ', ' order by elem.ordinality)
      from jsonb_array_elements(coalesce(v_current_written_off_by_order -> p_order_id, '[]'::jsonb))
           with ordinality as elem(item, ordinality)
  ), '—');
  v_pending_text := coalesce((
    select string_agg(elem.item #>> '{}', ', ' order by elem.ordinality)
      from jsonb_array_elements(coalesce(v_current_pending_by_order -> p_order_id, '[]'::jsonb))
           with ordinality as elem(item, ordinality)
  ), '—');
  v_event_message := format(
    'Флексопечать завершена. Списана краска: %s. Оставлены в ожидании: %s.',
    v_written_text,
    v_pending_text
  );
  insert into order_events(order_id, event_type, description, message, payload)
  values (
    p_order_id,
    'flex_printing_completed',
    v_event_message,
    v_event_message,
    jsonb_build_object(
      'task_id', p_task_id,
      'stage_id', p_stage_id,
      'written_off', coalesce(v_current_written_off_by_order -> p_order_id, '[]'::jsonb),
      'left_pending', coalesce(v_current_pending_by_order -> p_order_id, '[]'::jsonb)
    )
  );

  for v_event_order_id, v_event_items in
    select key, value
      from jsonb_each(v_deferred_written_off_by_order)
     where key <> p_order_id
  loop
    v_written_text := coalesce((
      select string_agg(elem.item #>> '{}', ', ' order by elem.ordinality)
        from jsonb_array_elements(v_event_items)
             with ordinality as elem(item, ordinality)
    ), '—');
    v_event_message := format(
      'Выполнено отложенное списание краски после последующей флексопечати: %s.',
      v_written_text
    );
    insert into order_events(order_id, event_type, description, message, payload)
    values (
      v_event_order_id,
      'flex_printing_deferred_paint_writeoff',
      v_event_message,
      v_event_message,
      jsonb_build_object(
        'completed_order_id', p_order_id,
        'task_id', p_task_id,
        'stage_id', p_stage_id,
        'written_off', v_event_items
      )
    );
  end loop;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  if p_quantity_done is not null and trim(p_quantity_done) <> '' then
    if coalesce(array_length(v_task.assignees, 1), 0) > 1 then
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'quantity_team_total',
        'text', p_quantity_done,
        'userId', v_user_id,
        'timestamp', v_now_ms
      ));
      foreach v_assignee in array v_task.assignees loop
        v_comments := v_comments || jsonb_build_array(jsonb_build_object(
          'id', gen_random_uuid()::text,
          'type', 'user_done',
          'text', 'done',
          'userId', v_assignee,
          'timestamp', v_now_ms + 1
        ));
      end loop;
    else
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'quantity_done',
        'text', p_quantity_done,
        'userId', v_user_id,
        'timestamp', v_now_ms
      ));
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'user_done',
        'text', 'done',
        'userId', v_user_id,
        'timestamp', v_now_ms + 1
      ));
    end if;
  end if;

  if p_comment is not null and trim(p_comment) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'finish_note',
      'text', p_comment,
      'userId', v_user_id,
      'timestamp', v_now_ms + 2
    ));
  end if;

  update tasks
     set status = 'completed',
         started_at = null,
         comments = v_comments
   where id::text = p_task_id;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$function$
;

-- ==========================================================================
-- complete_task_stage(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_quantity_done text, p_comment text, p_joint_user_ids jsonb, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.complete_task_stage(p_task_id text, p_order_id text, p_stage_id text, p_employee_id text, p_quantity_done text DEFAULT NULL::text, p_comment text DEFAULT NULL::text, p_joint_user_ids jsonb DEFAULT '[]'::jsonb, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task tasks%rowtype;
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_comments jsonb;
  v_user_id text := coalesce(nullif(trim(p_employee_id), ''), nullif(trim(p_actor), ''), 'system');
  v_joint_ids text[] := array[]::text[];
  v_helper_id text;
  v_offset int := 0;
begin
  if coalesce(trim(p_task_id), '') = '' then raise exception 'task_id is required'; end if;
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  if coalesce(trim(p_stage_id), '') = '' then raise exception 'stage_id is required'; end if;
  if p_joint_user_ids is null then p_joint_user_ids := '[]'::jsonb; end if;

  select * into v_task
    from tasks
   where id::text = p_task_id and order_id::text = p_order_id and stage_id::text = p_stage_id
   for update;
  if not found then
    raise exception 'Задача % не найдена для заказа %.', p_task_id, p_order_id;
  end if;
  if v_task.status = 'completed' then
    raise exception 'Этап уже завершен.';
  end if;
  if v_task.status not in ('inProgress', 'paused', 'problem', 'waiting', 'pending', 'planned') then
    raise exception 'Нельзя завершить этап из статуса %.', v_task.status;
  end if;
  if v_user_id <> 'system' and array_position(coalesce(v_task.assignees, array[]::text[]), v_user_id) is null then
    raise exception 'Сотрудник не назначен исполнителем этапа.';
  end if;

  select array_agg(distinct trim(value)) into v_joint_ids
    from jsonb_array_elements_text(p_joint_user_ids)
   where trim(value) <> '';
  v_joint_ids := coalesce(v_joint_ids, array[]::text[]);

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  if array_length(v_joint_ids, 1) is not null then
    foreach v_helper_id in array v_joint_ids loop
      if v_helper_id = v_user_id then continue; end if;
      if p_quantity_done is not null and trim(p_quantity_done) <> '' then
        v_comments := v_comments || jsonb_build_array(jsonb_build_object(
          'id', gen_random_uuid()::text,
          'type', 'quantity_share',
          'text', p_quantity_done,
          'userId', v_helper_id,
          'timestamp', v_now_ms + v_offset
        ));
        v_offset := v_offset + 1;
      end if;
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'user_done',
        'text', 'done',
        'userId', v_helper_id,
        'timestamp', v_now_ms + v_offset
      ));
      v_offset := v_offset + 1;
    end loop;

    if p_quantity_done is not null and trim(p_quantity_done) <> '' then
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'quantity_team_total',
        'text', p_quantity_done,
        'userId', v_user_id,
        'timestamp', v_now_ms + v_offset
      ));
      v_offset := v_offset + 1;
    end if;
  elsif p_quantity_done is not null and trim(p_quantity_done) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_done',
      'text', p_quantity_done,
      'userId', v_user_id,
      'timestamp', v_now_ms + v_offset
    ));
    v_offset := v_offset + 1;
  end if;

  if p_quantity_done is not null and trim(p_quantity_done) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'user_done',
      'text', 'done',
      'userId', v_user_id,
      'timestamp', v_now_ms + v_offset
    ));
    v_offset := v_offset + 1;
  end if;

  if p_comment is not null and trim(p_comment) <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'finish_note',
      'text', p_comment,
      'userId', v_user_id,
      'timestamp', v_now_ms + v_offset
    ));
  end if;

  update tasks
     set comments = v_comments,
         status = 'completed',
         started_at = null
   where id::text = p_task_id;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$function$
;

-- ==========================================================================
-- copy_template_to_plan(p_order_id uuid, p_template_id uuid)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.copy_template_to_plan(p_order_id uuid, p_template_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_plan_id uuid;
begin
  if p_order_id is null or p_template_id is null then
    return null;
  end if;

  -- Ensure plan exists (one plan per order)
  select id into v_plan_id
  from public.prod_plans
  where order_id = p_order_id
  limit 1;

  if v_plan_id is null then
    insert into public.prod_plans(order_id, template_id, title, plan_code, note, created_by)
    select
      o.id,
      p_template_id,
      coalesce((o.product->>'name'), o.assignment_id, 'План для заказа'),
      o.assignment_id,
      null,
      auth.uid()
    from public.orders o
    where o.id = p_order_id
    returning id into v_plan_id;
  else
    -- If template changed, reset stages
    update public.prod_plans
      set template_id = p_template_id
    where id = v_plan_id;
    delete from public.prod_plan_stages where plan_id = v_plan_id;
  end if;

  -- Copy stages from template -> plan
  insert into public.prod_plan_stages(
    plan_id, template_stage_id, seq, name, note,
    position_id, workplace_id, expected_minutes,
    created_by
  )
  select
    v_plan_id, ts.id, ts.seq, ts.name, ts.note,
    ts.position_id, ts.workplace_id, ts.expected_minutes,
    auth.uid()
  from public.prod_template_stages ts
  where ts.template_id = p_template_id
  order by ts.seq;

  return v_plan_id;
end $function$
;

-- ==========================================================================
-- create_user_folder(folder_name text, folder_parent_id uuid)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.create_user_folder(folder_name text, folder_parent_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  created_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if folder_parent_id is not null then
    if not exists (
      select 1
      from public.folders parent
      where parent.id = folder_parent_id
        and parent.owner_id = auth.uid()
    ) then
      raise exception 'Parent folder not found or access denied';
    end if;
  end if;

  insert into public.folders (owner_id, parent_id, name, path)
  values (
    auth.uid(),
    folder_parent_id,
    coalesce(nullif(trim(folder_name), ''), 'Новая папка'),
    ''
  )
  returning id into created_id;

  return created_id;
end;
$function$
;

-- ==========================================================================
-- documents_sync_type_collection()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.documents_sync_type_collection()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- если код пишет только collection — подставим type
  if new.type is null and new.collection is not null then
    new.type := new.collection;
  end if;

  -- если код пишет только type — подставим collection
  if new.collection is null and new.type is not null then
    new.collection := new.type;
  end if;

  return new;
end
$function$
;

-- ==========================================================================
-- finalize_order_paper_reservations(p_order_id text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.finalize_order_paper_reservations(p_order_id text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record;
  v_order_id order_paper_reservations.order_id%type;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := p_order_id;

  -- Блокируем строки резерва заказа, чтобы избежать двойного списания.
  for rec in
    select r.paper_id, r.qty
    from order_paper_reservations r
    where r.order_id = v_order_id
    for update
  loop
    if rec.qty <= 0 then
      continue;
    end if;

    insert into papers_writeoffs(paper_id, qty, reason, by_name)
    values (
      rec.paper_id,
      rec.qty,
      format('Списание после завершения заказа %s', p_order_id),
      coalesce(nullif(trim(p_actor), ''), 'system')
    );
  end loop;

  delete from order_paper_reservations
   where order_id = v_order_id;
end;
$function$
;

-- ==========================================================================
-- find_forms(q text, limit_count integer)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.find_forms(q text, limit_count integer DEFAULT 50)
 RETURNS SETOF forms
 LANGUAGE sql
 STABLE
AS $function$
  SELECT * FROM public.forms
  WHERE series ILIKE '%'||q||'%' OR CAST(number AS text) ILIKE '%'||q||'%'
  ORDER BY series, number
  LIMIT limit_count;
$function$
;

-- ==========================================================================
-- fn_pens_apply_arrival()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.fn_pens_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.warehouse_pens
     set quantity = quantity + new.qty,
         updated_at = now()
   where id = new.item_id;
  return new;
end;
$function$
;

-- ==========================================================================
-- fn_pens_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.fn_pens_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.warehouse_pens
     set quantity = new.factual,
         updated_at = now()
   where id = new.item_id;
  return new;
end;
$function$
;

-- ==========================================================================
-- fn_pens_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.fn_pens_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.warehouse_pens
     set quantity = greatest(0, quantity - new.qty),
         updated_at = now()
   where id = new.item_id;
  return new;
end;
$function$
;

-- ==========================================================================
-- fn_set_updated_at()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.fn_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end;
$function$
;

-- ==========================================================================
-- form_allocate(p_series text, p_title text, p_description text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.form_allocate(p_series text DEFAULT 'F'::text, p_title text DEFAULT NULL::text, p_description text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, series text, number integer, code text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_next int;
  v_prefix text;
  v_suffix text;
begin
  with upd as (
    update public.forms_series
       set last_number = last_number + 1
     where series = p_series
     returning last_number, prefix, suffix
  ), ins as (
    insert into public.forms_series (series, prefix, suffix, last_number)
    select p_series, '', '', 1
    where not exists (select 1 from upd)
    returning last_number, prefix, suffix
  )
  select last_number, coalesce(prefix,''), coalesce(suffix,'')
    into v_next, v_prefix, v_suffix
  from upd
  union all
  select last_number, prefix, suffix from ins;

  insert into public.forms(series, number, prefix, suffix, title, description, created_by)
  values (p_series, v_next, v_prefix, v_suffix, p_title, p_description, auth.uid())
  returning forms.id, forms.series, forms.number, forms.code
  into id, series, number, code;

  return;
end
$function$
;

-- ==========================================================================
-- get_order_generation_chain(p_order_id text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.get_order_generation_chain(p_order_id text)
 RETURNS TABLE(id uuid, restarted_from_order_id uuid, restart_root_order_id uuid, restart_generation integer, created_at timestamp with time zone, order_date timestamp with time zone, completed_at timestamp with time zone, updated_at timestamp with time zone, status text)
 LANGUAGE sql
 STABLE
AS $function$
  with target as (
    select coalesce(o.restart_root_order_id, o.id) as root_id
    from public.orders o
    where o.id = p_order_id::uuid
  )
  select
    o.id,
    o.restarted_from_order_id,
    o.restart_root_order_id,
    coalesce(o.restart_generation, 0),
    o.created_at,
    o.order_date,
    o.completed_at,
    o.updated_at,
    o.status::text
  from public.orders o
  join target t
    on o.id = t.root_id
    or o.restart_root_order_id = t.root_id
  order by coalesce(o.restart_generation, 0), o.created_at;
$function$
;

-- ==========================================================================
-- get_order_restart_history(p_order_id text, p_limit integer)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.get_order_restart_history(p_order_id text, p_limit integer DEFAULT 200)
 RETURNS TABLE(id uuid, restarted_from_order_id uuid, completed_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
  with recursive chain as (
    select
      o.id,
      o.restarted_from_order_id,
      o.completed_at,
      o.updated_at,
      0 as depth,
      array[o.id] as visited
    from public.orders o
    where o.id = p_order_id::uuid
    union all
    select
      p.id,
      p.restarted_from_order_id,
      p.completed_at,
      p.updated_at,
      c.depth + 1,
      c.visited || p.id
    from public.orders p
    join chain c on p.id = c.restarted_from_order_id
    where not p.id = any(c.visited)                -- защита от циклов
      and c.depth < greatest(coalesce(p_limit, 200), 1)
  )
  select c.id, c.restarted_from_order_id, c.completed_at, c.updated_at
  from chain c
  order by c.depth
  limit greatest(coalesce(p_limit, 200), 1) + 1;
$function$
;

-- ==========================================================================
-- guard_carryover_paint_removal()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.guard_carryover_paint_removal()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_name text := public.normalize_paint_name(old.name);
  v_pending record;
  v_customer text;
begin
  if v_name = '' then
    return null;
  end if;

  -- Заказ удалён целиком в этой же транзакции (каскад) — список красок
  -- заказа перестаёт существовать, защищать нечего.
  if not exists (select 1 from public.orders o where o.id = old.order_id) then
    return null;
  end if;

  -- Паттерн delete+insert: если на момент COMMIT краска с таким именем
  -- снова есть в списке заказа, удаления по сути не было.
  if exists (
    select 1
    from public.order_paints p
    where p.order_id = old.order_id
      and public.normalize_paint_name(p.name) = v_name
  ) then
    return null;
  end if;

  select w.id, w.order_id
    into v_pending
  from public.order_paint_pending_writeoffs w
  where w.status = 'pending'
    and w.order_id <> old.order_id::text
    and public.normalize_paint_name(w.paint_name) = v_name
  order by w.created_at
  limit 1;

  if v_pending.id is null then
    return null;
  end if;

  select o.customer into v_customer
  from public.orders o
  where o.id::text = v_pending.order_id;

  -- Текст показывается пользователю как есть (_humanizeRpcError берёт message).
  raise exception 'Краска «%» перешла из заказа «%» и ещё не списана — удалить её из списка нельзя',
    old.name,
    coalesce(nullif(v_customer, ''), v_pending.order_id)
    using errcode = 'P0001';
end;
$function$
;

-- ==========================================================================
-- inventory_set(type text, item uuid, counted numeric, note text, by_name text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.inventory_set(type text, item uuid, counted numeric, note text, by_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  if type='stationery' then
    insert into public.warehouse_stationery_inventories(item_id, counted_qty, note, created_by, by_name)
    values (item, counted, note, auth.uid(), by_name);

  elsif type='pens' then
    insert into public.warehouse_pens_inventories(item_id, counted_qty, note, created_by, by_name)
    values (item, counted, note, auth.uid(), by_name);

  elsif type='paper' then
    insert into public.warehouse_paper_inventories(item_id, counted_qty, note, created_by, by_name)
    values (item, counted, note, auth.uid(), by_name);
  end if;
end;
$function$
;

-- ==========================================================================
-- log_prod_stage_status()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.log_prod_stage_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if (tg_op='UPDATE') and (old.status is distinct from new.status) then
    insert into public.prod_stage_history(stage_id, old_status, new_status, changed_by)
    values (old.id, old.status, new.status, coalesce(new.updated_by, auth.uid()));
  end if;
  return new;
end$function$
;

-- ==========================================================================
-- materials_apply_arrival()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.materials_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.materials set quantity = coalesce(quantity,0) + new.qty, updated_at = now()
  where id = new.material_id;
  return new;
end $function$
;

-- ==========================================================================
-- materials_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.materials_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.materials
     set quantity = new.counted_qty,
         updated_at = now()
   where id = new.material_id;
  return new;
end$function$
;

-- ==========================================================================
-- materials_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.materials_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.materials
     set quantity = greatest(0, quantity - new.qty),
         updated_at = now()
   where id = new.material_id;
  return new;
end$function$
;

-- ==========================================================================
-- next_form_number(p_series text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.next_form_number(p_series text)
 RETURNS integer
 LANGUAGE sql
AS $function$
  WITH mx AS (
    SELECT COALESCE(MAX(number),0) AS m FROM public.forms WHERE series = p_series
  )
  SELECT n FROM generate_series(1, (SELECT m FROM mx)+1) n
  WHERE NOT EXISTS (
    SELECT 1 FROM public.forms f WHERE f.series = p_series AND f.number = n
  )
  ORDER BY n
  LIMIT 1;
$function$
;

-- ==========================================================================
-- normalize_paint_name(value text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.normalize_paint_name(value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select lower(regexp_replace(btrim(coalesce(value, '')), '\s+', ' ', 'g'));
$function$
;

-- ==========================================================================
-- paints_apply_arrival()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.paints_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.paints set quantity = coalesce(quantity,0) + new.qty, updated_at = now()
  where id = new.paint_id;
  return new;
end $function$
;

-- ==========================================================================
-- paints_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.paints_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.paints
     set quantity = new.counted_qty,
         updated_at = now()
   where id = new.paint_id;
  return new;
end$function$
;

-- ==========================================================================
-- paints_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.paints_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.paints
     set quantity = greatest(0, quantity - new.qty),
         updated_at = now()
   where id = new.paint_id;
  return new;
end$function$
;

-- ==========================================================================
-- paper_consume(p_name text, p_format text, p_grammage text, p_qty_m numeric, p_order_id uuid, p_reason text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.paper_consume(p_name text, p_format text, p_grammage text, p_qty_m numeric, p_order_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_item_id uuid;
  v_stock numeric;
begin
  if p_qty_m <= 0 then
    raise exception 'Расход должен быть > 0';
  end if;

  select id into v_item_id
  from paper_items
  where lower(name) = lower(p_name)
    and format = p_format
    and grammage = p_grammage;

  if v_item_id is null then
    raise exception 'Такой бумаги (номенклатура/формат/грамаж) нет на складе';
  end if;

  select coalesce(sum(qty_m),0) into v_stock
  from paper_moves
  where item_id = v_item_id;

  if v_stock < p_qty_m then
    raise exception 'На складе не хватает материала: есть % м, нужно % м', v_stock, p_qty_m;
  end if;

  insert into paper_moves (item_id, qty_m, order_id, reason)
  values (v_item_id, -p_qty_m, p_order_id, coalesce(p_reason, 'Расход'));

  return v_item_id;
end;
$function$
;

-- ==========================================================================
-- paper_receive(p_name text, p_format text, p_grammage text, p_qty_m numeric, p_reason text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.paper_receive(p_name text, p_format text, p_grammage text, p_qty_m numeric, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_item_id uuid;
begin
  if p_qty_m <= 0 then
    raise exception 'Приход должен быть > 0';
  end if;

  insert into paper_items (name, format, grammage)
  values (p_name, p_format, p_grammage)
  on conflict (lower(name), format, grammage)
  do update set name = excluded.name
  returning id into v_item_id;

  insert into paper_moves (item_id, qty_m, reason)
  values (v_item_id, p_qty_m, coalesce(p_reason, 'Приход'));

  return v_item_id;
end;
$function$
;

-- ==========================================================================
-- papers_apply_arrival()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.papers_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.papers set quantity = coalesce(quantity,0) + new.qty, updated_at = now()
  where id = new.paper_id;
  return new;
end $function$
;

-- ==========================================================================
-- papers_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.papers_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.papers
     set quantity = new.counted_qty,
         updated_at = now()
   where id = new.paper_id;
  return new;
end$function$
;

-- ==========================================================================
-- papers_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.papers_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.papers
     set quantity = greatest(0, quantity - new.qty),
         updated_at = now()
   where id = new.paper_id;
  return new;
end$function$
;

-- ==========================================================================
-- pens_arrival(p_item_id uuid, p_qty numeric, p_note text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.pens_arrival(p_item_id uuid, p_qty numeric, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.warehouse_pens_arrivals(item_id, qty, note)
  values (p_item_id, p_qty, nullif(trim(coalesce(p_note,'')), ''));
end;
$function$
;

-- ==========================================================================
-- pens_inventory(p_item_id uuid, p_factual numeric, p_note text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.pens_inventory(p_item_id uuid, p_factual numeric, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.warehouse_pens_inventories(item_id, factual, note)
  values (p_item_id, p_factual, nullif(trim(coalesce(p_note,'')), ''));
end;
$function$
;

-- ==========================================================================
-- pens_upsert(p_name text, p_color text, p_unit text, p_note text, p_low_threshold numeric, p_critical_threshold numeric)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.pens_upsert(p_name text, p_color text, p_unit text DEFAULT 'пар'::text, p_note text DEFAULT NULL::text, p_low_threshold numeric DEFAULT NULL::numeric, p_critical_threshold numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare v_id uuid;
begin
  select id
    into v_id
    from public.warehouse_pens
   where unique_lower_key = lower(trim(p_name)) || '|' || lower(trim(p_color))
   limit 1;

  if v_id is null then
    insert into public.warehouse_pens(name, color, unit, note, low_threshold, critical_threshold)
    values (trim(p_name), trim(p_color), coalesce(nullif(trim(p_unit), ''), 'пар'), nullif(trim(coalesce(p_note,'')), ''), p_low_threshold, p_critical_threshold)
    returning id into v_id;
  else
    update public.warehouse_pens
       set unit = coalesce(nullif(trim(p_unit), ''), unit),
           note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note),
           low_threshold = coalesce(p_low_threshold, low_threshold),
           critical_threshold = coalesce(p_critical_threshold, critical_threshold)
     where id = v_id;
  end if;

  return v_id;
end;
$function$
;

-- ==========================================================================
-- pens_writeoff(p_item_id uuid, p_qty numeric, p_reason text, p_order_id uuid)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.pens_writeoff(p_item_id uuid, p_qty numeric, p_reason text DEFAULT NULL::text, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.warehouse_pens_writeoffs(item_id, qty, reason, order_id)
  values (p_item_id, p_qty, nullif(trim(coalesce(p_reason,'')), ''), p_order_id);
end;
$function$
;

-- ==========================================================================
-- prod_create_plan_from_template(p_order_id uuid, p_template_id uuid, p_plan_code text, p_title text, p_note text, p_created_by uuid)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.prod_create_plan_from_template(p_order_id uuid, p_template_id uuid, p_plan_code text, p_title text, p_note text, p_created_by uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_plan_id uuid;
begin
  insert into public.prod_plans(order_id, template_id, plan_code, title, note, created_by, updated_by)
  values (p_order_id, p_template_id, p_plan_code, p_title, p_note, p_created_by, p_created_by)
  returning id into v_plan_id;

  insert into public.prod_plan_stages(
    plan_id, template_stage_id, seq, name, note,
    position_id, workplace_id, expected_minutes,
    created_by, updated_by
  )
  select
    v_plan_id, pts.id, pts.seq, pts.name, pts.note,
    pts.position_id, pts.workplace_id, pts.expected_minutes,
    p_created_by, p_created_by
  from public.prod_template_stages pts
  where pts.template_id = p_template_id
  order by pts.seq;

  return v_plan_id;
end
$function$
;

-- ==========================================================================
-- recalculate_paint_reserved_qty(p_paint_ids text[])
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.recalculate_paint_reserved_qty(p_paint_ids text[] DEFAULT NULL::text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.paints p
     set reserved_qty = coalesce((
       select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
       from public.order_paint_reservations r
       where r.paint_id = p.id::text
     ), 0)
   where p_paint_ids is null
      or p.id::text = any(p_paint_ids);
end;
$function$
;

-- ==========================================================================
-- recalculate_paint_reserved_qty(p_paint_ids uuid[])
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.recalculate_paint_reserved_qty(p_paint_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    declare
      v_paint_ids uuid[];
    begin
      select array_agg(distinct paint_id)
        into v_paint_ids
        from unnest(p_paint_ids) as paint_id
       where paint_id is not null;

      if coalesce(array_length(v_paint_ids, 1), 0) = 0 then
        return;
      end if;

      update paints p
         set reserved_qty = coalesce((
               select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
                 from order_paint_reservations r
                where r.paint_id = p.id
             ), 0)
       where p.id = any(v_paint_ids);
    end;
    $function$
;

-- ==========================================================================
-- release_order_paint_reservations(p_order_id text, p_reason text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.release_order_paint_reservations(p_order_id text, p_reason text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_touched public.paints.id%type[];
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  select array_agg(distinct paint_id) into v_touched
    from order_paint_reservations
   where order_id::text = p_order_id and paint_id is not null;

  update order_paint_reservations
     set released_qty = greatest(reserved_qty - used_qty, 0),
         updated_at = now()
   where order_id::text = p_order_id;

  perform recalculate_paint_reserved_qty(v_touched);
end;
$function$
;

-- ==========================================================================
-- release_order_paper_reservations(p_order_id text, p_reason text, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.release_order_paper_reservations(p_order_id text, p_reason text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order_id order_paper_reservations.order_id%type;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := p_order_id;

  delete from order_paper_reservations
   where order_id = v_order_id;
end;
$function$
;

-- ==========================================================================
-- safe_paint_id(p_value text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.safe_paint_id(p_value text)
 RETURNS uuid
 LANGUAGE sql
 IMMUTABLE
AS $function$
        select case
          when nullif(trim(p_value), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then nullif(trim(p_value), '')::uuid
          else null
        end
      $function$
;

-- ==========================================================================
-- save_order_paints(p_order_id text, p_paints jsonb)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.save_order_paints(p_order_id text, p_paints jsonb DEFAULT '[]'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order_id public.orders.id%type;
  v_order_id_uuid uuid;
  v_order_paints_order_id_type text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := trim(p_order_id);

  if p_paints is null then
    p_paints := '[]'::jsonb;
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_order_paints_order_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'order_paints'
     and a.attname = 'order_id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_order_paints_order_id_type is null then
    raise exception 'public.order_paints.order_id column was not found';
  end if;

  if v_order_paints_order_id_type = 'uuid' then
    v_order_id_uuid := trim(p_order_id)::uuid;

    execute 'delete from public.order_paints where order_id = $1'
      using v_order_id_uuid;

    execute $sql$
      insert into public.order_paints(order_id, name, info, qty_kg)
      select
        $1,
        nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') as name,
        nullif(trim(coalesce(item->>'info', item->>'memo')), '') as info,
        case
          when nullif(trim(item->>'qty_kg'), '') is not null then
            replace(trim(item->>'qty_kg'), ',', '.')::double precision
          when nullif(trim(item->>'qtyGrams'), '') is not null then
            replace(trim(item->>'qtyGrams'), ',', '.')::double precision / 1000
          when nullif(trim(item->>'qty_grams'), '') is not null then
            replace(trim(item->>'qty_grams'), ',', '.')::double precision / 1000
          else null
        end as qty_kg
      from jsonb_array_elements($2) as item
      where nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') is not null
    $sql$ using v_order_id_uuid, p_paints;
  else
    execute 'delete from public.order_paints where order_id = $1'
      using trim(p_order_id);

    execute $sql$
      insert into public.order_paints(order_id, name, info, qty_kg)
      select
        $1,
        nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') as name,
        nullif(trim(coalesce(item->>'info', item->>'memo')), '') as info,
        case
          when nullif(trim(item->>'qty_kg'), '') is not null then
            replace(trim(item->>'qty_kg'), ',', '.')::double precision
          when nullif(trim(item->>'qtyGrams'), '') is not null then
            replace(trim(item->>'qtyGrams'), ',', '.')::double precision / 1000
          when nullif(trim(item->>'qty_grams'), '') is not null then
            replace(trim(item->>'qty_grams'), ',', '.')::double precision / 1000
          else null
        end as qty_kg
      from jsonb_array_elements($2) as item
      where nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') is not null
    $sql$ using trim(p_order_id), p_paints;
  end if;
end;
$function$
;

-- ==========================================================================
-- set_created_by_default()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.set_created_by_default()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.created_by is null then
    new.created_by = auth.uid();
  end if;
  return new;
end $function$
;

-- ==========================================================================
-- set_created_by_default_files()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.set_created_by_default_files()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.created_by is null then
    new.created_by = auth.uid();
  end if;
  return new;
end $function$
;

-- ==========================================================================
-- set_updated_at()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end; $function$
;

-- ==========================================================================
-- stationery_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.stationery_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.stationery
     set quantity = new.counted_qty,
         updated_at = now()
   where id = new.item_id;
  return new;
end$function$
;

-- ==========================================================================
-- stationery_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.stationery_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.stationery
     set quantity = greatest(0, quantity - new.qty),
         updated_at = now()
   where id = new.item_id;
  return new;
end$function$
;

-- ==========================================================================
-- sync_order_paint_reservations(p_order_id text, p_reservations jsonb, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.sync_order_paint_reservations(p_order_id text, p_reservations jsonb DEFAULT '[]'::jsonb, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record;
  v_available double precision;
  v_reserved_other double precision;
  v_paint_name text;
  v_total_qty double precision;
  v_stock_name text;
  v_touched public.paints.id%type[] := '{}';
  v_order_id public.orders.id%type;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;
  v_order_id := trim(p_order_id);

  if p_reservations is null then
    p_reservations := '[]'::jsonb;
  end if;

  for rec in
    with requested as (
      select
        public.safe_paint_id(coalesce(value->>'paint_id', value->>'material_id')) as paint_id,
        nullif(trim(coalesce(value->>'paint_name', value->>'name')), '') as paint_name,
        coalesce(
          nullif(value->>'reserved_qty', '')::double precision,
          nullif(value->>'qty', '')::double precision,
          nullif(value->>'qty_g', '')::double precision,
          nullif(value->>'qty_grams', '')::double precision,
          nullif(value->>'qty_kg', '')::double precision * 1000,
          0
        ) as qty
      from jsonb_array_elements(p_reservations)
    ), resolved as (
      select
        coalesce(req.paint_id, p_by_name.id) as paint_id,
        coalesce(req.paint_name, p_by_name.description) as paint_name,
        req.qty
      from requested req
      left join lateral (
        select p.id, p.description
          from paints p
         where req.paint_id is null
           and req.paint_name is not null
           and lower(trim(p.description)) = lower(trim(req.paint_name))
         order by p.id
         limit 1
      ) p_by_name on true
      where req.paint_id is not null or req.paint_name is not null
    ), aggregated as (
      select paint_id, max(paint_name) as paint_name, sum(qty) as qty
      from resolved
      group by paint_id
    )
    select a.paint_id, a.paint_name, a.qty, p.quantity as total_qty, p.description as stock_name
    from aggregated a
    left join paints p on p.id = a.paint_id
    order by a.paint_id nulls last, a.paint_name
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя зарезервировать отрицательное количество краски (%).', coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
    end if;

    if rec.paint_id is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select p.quantity, p.description
      into v_total_qty, v_stock_name
      from paints p
     where p.id = rec.paint_id
     for update;

    if not found or v_total_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id::text <> p_order_id;

    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paint_name := coalesce(v_stock_name, rec.stock_name, rec.paint_name, rec.paint_id::text);
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %',
        v_paint_name, round(v_available::numeric, 2), round(rec.qty::numeric, 2);
    end if;

    v_touched := array_append(v_touched, rec.paint_id);
  end loop;

  v_touched := v_touched || array(
    select distinct paint_id
      from order_paint_reservations
     where order_id::text = p_order_id and paint_id is not null
  );

  for rec in
    with requested as (
      select
        public.safe_paint_id(coalesce(value->>'paint_id', value->>'material_id')) as paint_id,
        nullif(trim(coalesce(value->>'paint_name', value->>'name')), '') as paint_name,
        coalesce(
          nullif(value->>'reserved_qty', '')::double precision,
          nullif(value->>'qty', '')::double precision,
          nullif(value->>'qty_g', '')::double precision,
          nullif(value->>'qty_grams', '')::double precision,
          nullif(value->>'qty_kg', '')::double precision * 1000,
          0
        ) as qty
      from jsonb_array_elements(p_reservations)
    ), resolved as (
      select coalesce(req.paint_id, p_by_name.id) as paint_id,
             coalesce(req.paint_name, p_by_name.description) as paint_name,
             req.qty
      from requested req
      left join lateral (
        select p.id, p.description
          from paints p
         where req.paint_id is null
           and req.paint_name is not null
           and lower(trim(p.description)) = lower(trim(req.paint_name))
         order by p.id
         limit 1
      ) p_by_name on true
      where req.paint_id is not null or req.paint_name is not null
    )
    select paint_id, max(paint_name) as paint_name, sum(qty) as qty
    from resolved
    where paint_id is not null
    group by paint_id
  loop
    if rec.qty <= 0 then
      delete from order_paint_reservations
       where order_id::text = p_order_id and paint_id = rec.paint_id;
    else
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (v_order_id, rec.paint_id, rec.paint_name, rec.qty, 0, 0)
      on conflict (order_id, paint_id) where paint_id is not null
      do update
      set paint_name = coalesce(excluded.paint_name, order_paint_reservations.paint_name),
          reserved_qty = excluded.reserved_qty,
          used_qty = 0,
          released_qty = 0,
          updated_at = now();
    end if;
  end loop;

  delete from order_paint_reservations r
   where r.order_id::text = p_order_id
     and not exists (
       with requested as (
         select public.safe_paint_id(coalesce(value->>'paint_id', value->>'material_id')) as paint_id,
                nullif(trim(coalesce(value->>'paint_name', value->>'name')), '') as paint_name,
                coalesce(
                  nullif(value->>'reserved_qty', '')::double precision,
                  nullif(value->>'qty', '')::double precision,
                  nullif(value->>'qty_g', '')::double precision,
                  nullif(value->>'qty_grams', '')::double precision,
                  nullif(value->>'qty_kg', '')::double precision * 1000,
                  0
                ) as qty
         from jsonb_array_elements(p_reservations)
       )
       select 1
       from requested req
       left join lateral (
         select p.id
           from paints p
          where req.paint_id is null
            and req.paint_name is not null
            and lower(trim(p.description)) = lower(trim(req.paint_name))
          order by p.id
          limit 1
       ) p_by_name on true
       where coalesce(req.paint_id, p_by_name.id) = r.paint_id
         and req.qty > 0
     );

  perform recalculate_paint_reserved_qty((select array_agg(distinct x) from unnest(v_touched) as x where x is not null));
end;
$function$
;

-- ==========================================================================
-- sync_order_paper_reservations(p_order_id text, p_reservations jsonb, p_actor text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.sync_order_paper_reservations(p_order_id text, p_reservations jsonb DEFAULT '[]'::jsonb, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record;
  v_order_id order_paper_reservations.order_id%type;
  v_paper_id order_paper_reservations.paper_id%type;
  v_total_qty double precision;
  v_available double precision;
  v_reserved_other double precision;
  v_paper_name text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  if p_reservations is null then
    p_reservations := '[]'::jsonb;
  end if;

  v_order_id := p_order_id;

  -- Валидируем вход и блокируем нужные позиции бумаги для конкурентной безопасности.
  for rec in
    with requested as (
      select
        nullif(trim(value->>'paper_id'), '') as paper_id,
        coalesce(nullif(value->>'qty', '')::double precision, 0) as qty
      from jsonb_array_elements(p_reservations)
    ),
    aggregated as (
      select paper_id, sum(qty) as qty
      from requested
      where paper_id is not null
      group by paper_id
    )
    select a.paper_id, a.qty
    from aggregated a
    order by a.paper_id
  loop
    v_paper_id := rec.paper_id;

    select p.quantity, p.description
      into v_total_qty, v_paper_name
      from papers p
     where p.id = v_paper_id
     for update;

    if rec.qty < 0 then
      raise exception 'Нельзя зарезервировать отрицательное количество бумаги (%).', rec.paper_id;
    end if;

    if v_total_qty is null then
      raise exception 'Бумага % не найдена на складе.', rec.paper_id;
    end if;

    select coalesce(sum(r.qty), 0)
      into v_reserved_other
      from order_paper_reservations r
     where r.paper_id = v_paper_id
       and r.order_id <> v_order_id;

    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paper_name := coalesce(v_paper_name, rec.paper_id);
      raise exception 'Недостаточно доступного остатка бумаги "%": доступно %, требуется %.',
        v_paper_name, round(v_available::numeric, 2), round(rec.qty::numeric, 2);
    end if;
  end loop;

  -- Upsert по каждой бумаге.
  for rec in
    with requested as (
      select
        nullif(trim(value->>'paper_id'), '') as paper_id,
        coalesce(nullif(value->>'qty', '')::double precision, 0) as qty
      from jsonb_array_elements(p_reservations)
    )
    select paper_id, sum(qty) as qty
    from requested
    where paper_id is not null
    group by paper_id
  loop
    v_paper_id := rec.paper_id;

    if rec.qty <= 0 then
      delete from order_paper_reservations
       where order_id = v_order_id
         and paper_id = v_paper_id;
    else
      insert into order_paper_reservations(order_id, paper_id, qty)
      values (v_order_id, v_paper_id, rec.qty)
      on conflict (order_id, paper_id)
      do update
      set qty = excluded.qty,
          updated_at = now();
    end if;
  end loop;

  -- Удаляем резервы, которых больше нет в составе заказа.
  delete from order_paper_reservations r
   where r.order_id = v_order_id
     and not exists (
       select 1
       from jsonb_array_elements(p_reservations) j
       where nullif(trim(j->>'paper_id'), '') = r.paper_id::text
         and coalesce(nullif(j->>'qty', '')::double precision, 0) > 0
     );
end;
$function$
;

-- ==========================================================================
-- task_comments_to_array(p_comments jsonb)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.task_comments_to_array(p_comments jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_comments is null then '[]'::jsonb
    when jsonb_typeof(p_comments) = 'array' then p_comments
    when jsonb_typeof(p_comments) = 'object' then coalesce((select jsonb_agg(value) from jsonb_each(p_comments)), '[]'::jsonb)
    else '[]'::jsonb
  end
$function$
;

-- ==========================================================================
-- task_quantity_value(p_value text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.task_quantity_value(p_value text)
 RETURNS double precision
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v text := replace(coalesce(p_value, ''), ',', '.');
  m text[];
begin
  m := regexp_match(v, '=\s*(-?\d+(?:\.\d+)?)');
  if m is not null then return m[1]::double precision; end if;

  m := regexp_match(v, '(-?\d+(?:\.\d+)?)\s*пач', 'i');
  if m is not null then
    declare
      packs double precision := m[1]::double precision;
      in_pack_match text[] := regexp_match(v, '[x×*]\s*(-?\d+(?:\.\d+)?)');
    begin
      if in_pack_match is not null then
        return packs * in_pack_match[1]::double precision;
      end if;
    end;
  end if;

  begin
    return nullif(trim(v), '')::double precision;
  exception when others then
    m := regexp_match(v, '-?\d+(?:\.\d+)?');
    if m is not null then return m[1]::double precision; end if;
  end;
  return 0;
end;
$function$
;

-- ==========================================================================
-- tg_orders_sync_prod_plan()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.tg_orders_sync_prod_plan()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_tid uuid;
begin
  -- Only for authenticated sessions to satisfy RLS of prod_* tables
  if coalesce((auth.jwt() ->> 'role') = 'authenticated', false) is not true then
    return new;
  end if;

  -- determine template id
  v_tid := public._infer_template_id_from_order(new);

  if v_tid is null then
    return new;
  end if;

  -- create/sync
  perform public.copy_template_to_plan(new.id, v_tid);

  return new;
end $function$
;

-- ==========================================================================
-- tg_set_updated_at()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

-- ==========================================================================
-- trg_orders_sync_form_fields()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.trg_orders_sync_form_fields()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_series text; v_number int; v_code text;
begin
  if new.form_id is null then
    return new;
  end if;

  select series, number, code
    into v_series, v_number, v_code
  from public.forms
  where id = new.form_id;

  new.form_series := v_series;
  new.new_form_no := v_number;
  new.form_code   := v_code;
  return new;
end$function$
;

-- ==========================================================================
-- trg_orders_sync_form_no()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.trg_orders_sync_form_no()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare v_num integer;
begin
  if new.form_id is not null then
    select number into v_num from public.forms where id = new.form_id;
    new.new_form_no := v_num;
  end if;
  return new;
end
$function$
;

-- ==========================================================================
-- upsert_form(p_series text, p_number integer, p_title text, p_description text, p_size text, p_product_type text, p_colors text, p_image_url text, p_status text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.upsert_form(p_series text, p_number integer, p_title text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_size text DEFAULT NULL::text, p_product_type text DEFAULT NULL::text, p_colors text DEFAULT NULL::text, p_image_url text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS forms
 LANGUAGE plpgsql
AS $function$
DECLARE
  v public.forms;
BEGIN
  INSERT INTO public.forms (series, number, title, description, size, product_type, colors, image_url, status)
  VALUES (p_series, p_number, p_title, p_description, p_size, p_product_type, p_colors, NULLIF(p_image_url,''), p_status)
  ON CONFLICT (series, number) DO UPDATE
    SET title        = EXCLUDED.title,
        description  = EXCLUDED.description,
        size         = EXCLUDED.size,
        product_type = EXCLUDED.product_type,
        colors       = EXCLUDED.colors,
        image_url    = COALESCE(NULLIF(EXCLUDED.image_url,''), public.forms.image_url),
        status       = EXCLUDED.status,
        updated_at   = now()
  RETURNING * INTO v;
  RETURN v;
END
$function$
;

-- ==========================================================================
-- warehouse_pens_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.warehouse_pens_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.warehouse_pens
     set quantity = new.counted_qty,
         updated_at = now()
   where id = new.item_id;
  return new;
end $function$
;

-- ==========================================================================
-- wh_stationery_apply_arrival()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.wh_stationery_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.warehouse_stationery s
     set quantity = coalesce(s.quantity,0) + coalesce(new.qty,0), updated_at = now()
   where s.id = new.item_id;
  return new;
end $function$
;

-- ==========================================================================
-- wh_stationery_apply_inventory()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.wh_stationery_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_factual numeric;
begin
  v_factual := coalesce(new.factual, new.counted_qty, 0);
  update public.warehouse_stationery s
     set quantity  = v_factual,
         updated_at = now()
   where s.id::text = new.item_id::text;
  return new;
end$function$
;

-- ==========================================================================
-- wh_stationery_apply_writeoff()
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.wh_stationery_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.warehouse_stationery s
     set quantity  = greatest(0, coalesce(s.quantity,0) - coalesce(new.qty,0)),
         updated_at = now()
   where s.id::text = new.item_id::text;
  return new;
end$function$
;

-- ==========================================================================
-- writeoff(type text, item uuid, qty numeric, reason text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.writeoff(type text, item uuid, qty numeric, reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  if type = 'paint' then
    insert into public.paints_writeoffs(paint_id, qty, reason, created_by) values (item, qty, reason, auth.uid());
  elsif type = 'material' then
    insert into public.materials_writeoffs(material_id, qty, reason, created_by) values (item, qty, reason, auth.uid());
  elsif type = 'paper' then
    insert into public.papers_writeoffs(paper_id, qty, reason, created_by) values (item, qty, reason, auth.uid());
  elsif type = 'stationery' then
    insert into public.stationery_writeoffs(item_id, qty, reason, created_by) values (item, qty, reason, auth.uid());
  end if;
end;
$function$
;

-- ==========================================================================
-- writeoff(type text, item uuid, qty numeric, reason text, by_name text)
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.writeoff(type text, item uuid, qty numeric, reason text, by_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  if type='paint' then
    insert into public.paints_writeoffs(paint_id, qty, reason, created_by, by_name)
    values (item, qty, reason, auth.uid(), by_name);
  elsif type='material' then
    insert into public.materials_writeoffs(material_id, qty, reason, created_by, by_name)
    values (item, qty, reason, auth.uid(), by_name);
  elsif type='paper' then
    insert into public.papers_writeoffs(paper_id, qty, reason, created_by, by_name)
    values (item, qty, reason, auth.uid(), by_name);
  elsif type='stationery' then
    insert into public.stationery_writeoffs(item_id, qty, reason, created_by, by_name)
    values (item, qty, reason, auth.uid(), by_name);
  end if;
end $function$
;
