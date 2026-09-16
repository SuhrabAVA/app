-- Снимок определений public-функций Supabase
-- Снят: 2026-09-16 10:13 UTC
-- Функций: 138
-- Снимает: MCP execute_sql (запрос в scripts/dump_supabase_functions.sql)
--
-- ЭТО СНИМОК ПРОДА, НЕ МИГРАЦИЯ. Не применять как есть.
-- Зачем: видеть в git, какая версия функции была на проде, и ловить
-- расхождение с миграциями (строка md5 у каждой функции совпадает с
-- schema_change_log.definition_md5).

-- _infer_template_id_from_order(orders)
-- md5: 7e9cf5831c459f39c49a113b3802ad06
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

-- acquire_order_edit(uuid,uuid,text)
-- md5: 67d5d0b2b62618ce758e5ec69396a272
CREATE OR REPLACE FUNCTION public.acquire_order_edit(p_order_id uuid, p_token uuid, p_editor_name text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select order_edit_private.acquire(p_order_id, p_token, p_editor_name);
$function$
;

-- active_order_edits()
-- md5: b4027ecdb7f02673a337ce697145411e
CREATE OR REPLACE FUNCTION public.active_order_edits()
 RETURNS TABLE(order_id uuid, editor_name text)
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select * from order_edit_private.active_locks();
$function$
;

-- advance_order_after_task_completion(text,text,text,text)
-- md5: 1897d02de6c8447f80af0d4f6d674214
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
  v_completed_all_group boolean;
  v_has_pending_after boolean;
  v_actual_qty double precision;
  v_order_completed boolean;
  v_paper_stage_key text;
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
            -- Новый учёт: тираж лежит записями quantity_stage_total, по одной
            -- на сегмент (пересмена, завершение), поэтому берётся их СУММА.
            -- Персональные доли участников (quantity_share) сюда не входят:
            -- их сумма — это тираж, умноженный на число участников.
            when exists (
              select 1 from jsonb_array_elements(public.task_comments_to_array(comments)) c
               where c->>'type' = 'quantity_stage_total'
            ) then (
              select coalesce(sum(public.task_quantity_value(c->>'text')), 0)
                from jsonb_array_elements(public.task_comments_to_array(comments)) c
               where c->>'type' = 'quantity_stage_total'
            )
            -- Легаси-задачи, закрытые до перехода: поведение не меняем.
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

      null; -- actual_qty пишет только recompute_order_actual_qty (20260914)
    end if;
  end if;

  -- Списание бумаги на своём этапе маршрута (order_paper_writeoff_stage_key).
  --
  -- Готовность считаем по ГРУППОВОМУ ключу, а не по stage_id: у переключаемых
  -- этапов в группе несколько рабочих мест, и «этап закрыт» — это когда закрыты
  -- все задачи группы. Именно групповой ключ возвращает
  -- order_paper_writeoff_stage_key, поэтому сравниваются сравнимые величины.
  -- Повторный вызов безвреден: finalize_order_paper_reservations одноразова
  -- (orders.paper_written_off_at).
  select bool_and(status = 'completed')
    into v_completed_all_group
    from tasks
   where order_id::text = p_order_id
     and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key;

  if coalesce(v_completed_all_group, false)
     and to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
    v_paper_stage_key := public.order_paper_writeoff_stage_key(p_order_id);
    if v_paper_stage_key is not null and v_paper_stage_key = v_group_key then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
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

    -- Страховка для заказов без маршрута: этап списания не находится, и
    -- списать бумагу больше негде. Для остальных вызов уже ничего не делает.
    if to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
    end if;

    -- Бронь краски завершённого заказа возвращается на склад. Краски с
    -- непогашенным отложенным списанием функция оставляет сама (20260911).
    if to_regprocedure('public.release_order_paint_reservations(text,text,text)') is not null then
      perform public.release_order_paint_reservations(p_order_id, 'order_completed', p_actor);
    end if;
  end if;
  -- Факт заказа: единое правило «после упаковки» (20260914).
  perform public.recompute_order_actual_qty(p_order_id, p_stage_id);
end;
$function$
;

-- apply_customer_to_flex_paint_writeoff_reason()
-- md5: 28ba72c65c59a2d22f7aa5acf1e6c1c5
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

-- apply_template_to_order(uuid,uuid,text)
-- md5: 169ec5a27de02323d91a8ea39a0bbd0c
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

-- arrival_add(text,uuid,numeric,text,text)
-- md5: 9b0a760d568d95bfc86611d07de9050d
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

-- arrival_add(text,uuid,numeric,text)
-- md5: 77c9b8f166ebcf2b28fbc905fd5240b7
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

-- complete_flex_printing_stage_with_paint_queue(text,text,text,text,jsonb,jsonb,text,text,text)
-- md5: 2be5fa98fefa2f1447f1c0107999856c
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
  v_needs_shares boolean := false;
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

    if v_paint_id is null and coalesce(v_paint_name, '') <> '' then select p.id into v_paint_id from paints p where public.normalize_paint_name(p.description) = public.normalize_paint_name(v_paint_name) order by p.id limit 1; end if; if v_paint_id is null and coalesce(v_paint_name, '') = '' then
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
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %. [diag paint=% order=% stock=% reserved=%]',
        coalesce(v_stock_name, v_paint_name, v_paint_id::text), round(v_available::numeric, 2), round(v_amount::numeric, 2), coalesce(v_paint_id::text, '?'), coalesce(v_source_order_id, '?'), round(coalesce(v_stock_qty, 0)::numeric, 2), round(coalesce(v_reserved_other, 0)::numeric, 2);
    end if;

    insert into paints_writeoffs(paint_id, qty, reason, by_name)
    values (
      v_paint_id,
      v_amount,
      format('Списание флексопечати по заказу %s', v_source_order_id),
      coalesce(nullif(trim(p_actor), ''), nullif(trim(p_employee_id), ''), 'system')
    );

    -- остаток уменьшает триггер на paints_writeoffs (20260911)

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
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %. [diag paint=% order=% stock=% reserved=%]',
        coalesce(v_stock_name, v_paint_name, v_paint_id::text), round(v_available::numeric, 2), round(v_amount::numeric, 2), coalesce(v_paint_id::text, '?'), coalesce(v_source_order_id, '?'), round(coalesce(v_stock_qty, 0)::numeric, 2), round(coalesce(v_reserved_other, 0)::numeric, 2);
    end if;

    insert into paints_writeoffs(paint_id, qty, reason, by_name)
    values (
      v_paint_id,
      v_amount,
      format('Списание флексопечати по заказу %s из очереди', v_source_order_id),
      coalesce(nullif(trim(p_actor), ''), nullif(trim(p_employee_id), ''), 'system')
    );

    -- остаток уменьшает триггер на paints_writeoffs (20260911)

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
       set released_qty = greatest(reserved_qty - used_qty - public.order_paint_pending_debt_grams(p_order_id, paint_id, paint_name), 0),
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
    -- Тираж этапа — одна запись, доли считает
    -- recompute_task_quantity_shares. Флексопечать входит в список рабочих
    -- мест со split_quantity_by_time = false: бригада обслуживает одну
    -- машину, поэтому расчёт запишет каждому участнику полное количество.
    -- Отдельная запись тиража всё равно нужна — из неё считается факт заказа.
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_stage_total',
      'text', p_quantity_done,
      'userId', v_user_id,
      'timestamp', v_now_ms
    ));
    v_needs_shares := true;

    if coalesce(array_length(v_task.assignees, 1), 0) > 1 then
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

  if v_needs_shares then
    perform public.recompute_task_quantity_shares(p_task_id);
  end if;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$function$
;

-- complete_task_stage(text,text,text,text,text,text,jsonb,text)
-- md5: 81724146395d911aa6841fa9951c002f
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
  v_needs_shares boolean := false;
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
    -- Совместный режим. Тираж этапа фиксируется ОДНОЙ записью
    -- quantity_stage_total, а персональные доли считает
    -- recompute_task_quantity_shares по фактически отработанному времени.
    --
    -- Раньше здесь каждому помощнику писалось полное Q. Из-за этого помощник,
    -- пришедший на последний час пятичасового этапа, получал столько же,
    -- сколько отработавший смену, а orders.actual_qty (он суммирует записи
    -- количества задачи) вырастал во столько раз, сколько было участников.
    foreach v_helper_id in array v_joint_ids loop
      if v_helper_id = v_user_id then continue; end if;
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
        'type', 'quantity_stage_total',
        'text', p_quantity_done,
        'userId', v_user_id,
        'timestamp', v_now_ms + v_offset
      ));
      v_offset := v_offset + 1;
      v_needs_shares := true;
    end if;
  elsif p_quantity_done is not null and trim(p_quantity_done) <> '' then
    -- Отдельный исполнитель: делить не с кем, запись остаётся личной и
    -- читается обоими контурами, как и раньше.
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

  -- Доли считаются ПОСЛЕ записи тиража: расчёт читает quantity_stage_total из
  -- той же строки. Функция идемпотентна — повторный вызов ничего не удвоит.
  if not v_needs_shares and exists (select 1 from jsonb_array_elements(v_comments) c where c->>'type' = 'quantity_stage_total') then v_needs_shares := true; end if; if v_needs_shares then
    perform public.recompute_task_quantity_shares(p_task_id);
  end if;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$function$
;

-- copy_template_to_plan(uuid,uuid)
-- md5: a263712f0aecc237a149e629061ee0f8
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

-- copy_variant_sub_stages(uuid,uuid)
-- md5: 5296e9bfa966095c7a659d4ea09c2a76
CREATE OR REPLACE FUNCTION public.copy_variant_sub_stages(p_from_variant_id uuid, p_to_variant_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_from_stage    uuid;
  v_to_stage      uuid;
  v_from_config   uuid;
  v_to_config     uuid;
  v_stage         record;
  v_new_stage     uuid;
  v_copied        integer := 0;
  v_new_ids       uuid[] := '{}';
  v_partner       uuid;
  v_partner_level integer;
  v_partner_key   text;
  v_partner_title text;
  v_resolved      uuid;
  v_title         text;
  i               integer;
begin
  if p_from_variant_id is null or p_to_variant_id is null then
    raise exception
      'Не удалось скопировать под-этапы: не указан вариант.'
      using errcode = '22023';
  end if;

  if p_from_variant_id = p_to_variant_id then
    raise exception
      'Не удалось скопировать под-этапы: источник и приёмник совпадают.'
      using errcode = '22023';
  end if;

  select w.stage_id, s.config_id into v_from_stage, v_from_config
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_from_variant_id;

  select w.stage_id, s.config_id into v_to_stage, v_to_config
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_to_variant_id;

  if v_from_stage is null or v_to_stage is null then
    raise exception
      'Не удалось скопировать под-этапы: вариант не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_from_stage <> v_to_stage then
    raise exception
      'Не удалось скопировать под-этапы: варианты принадлежат разным этапам.'
      using errcode = '22023';
  end if;

  if v_from_config <> v_to_config then
    raise exception
      'Не удалось скопировать под-этапы: варианты из разных версий настроек.'
      using errcode = '22023';
  end if;

  for v_stage in
    select * from product_type_stages
     where parent_variant_id = p_from_variant_id
     order by position, stage_group_key
  loop
    if exists (
      select 1 from product_type_stages s
       where s.parent_variant_id = p_to_variant_id
         and s.stage_group_key = v_stage.stage_group_key
    ) then
      continue;
    end if;

    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last,
      execution_mode, parallel_with_stage_id)
    values (
      v_stage.config_id, p_to_variant_id, 1, v_stage.stage_group_key,
      v_stage.title, v_stage.position, v_stage.selection_mode,
      v_stage.is_enabled, v_stage.is_pinned_last,
      v_stage.execution_mode, v_stage.parallel_with_stage_id)
    returning id into v_new_stage;

    v_new_ids := v_new_ids || v_new_stage;

    insert into product_type_stage_workplaces(
      stage_id, workplace_id, variant_title, is_default, sort_order)
    select v_new_stage, workplace_id, variant_title, is_default, sort_order
      from product_type_stage_workplaces
     where stage_id = v_stage.id;

    insert into product_type_stage_conditions(
      stage_id, predicate, negate, param_text)
    select v_new_stage, predicate, negate, param_text
      from product_type_stage_conditions
     where stage_id = v_stage.id;

    v_copied := v_copied + 1;
  end loop;

  -- Перевод партнёров-под-этапов на ветку приёмника. Второй проход: партнёр
  -- мог быть скопирован позже своего потребителя.
  for i in 1 .. coalesce(array_length(v_new_ids, 1), 0) loop
    select s.parallel_with_stage_id, s.title, p.level, p.stage_group_key, p.title
      into v_partner, v_title, v_partner_level, v_partner_key, v_partner_title
      from product_type_stages s
      left join product_type_stages p on p.id = s.parallel_with_stage_id
     where s.id = v_new_ids[i];

    -- Партнёр верхнего уровня общий для обеих веток — ссылка уже верна.
    if v_partner is null or v_partner_level = 0 then
      continue;
    end if;

    select id into v_resolved
      from product_type_stages
     where parent_variant_id = p_to_variant_id
       and stage_group_key = v_partner_key;

    -- Оставить ссылку на чужую ветку нельзя, обнулить — значит тихо сменить
    -- режим этапа, поэтому копирование отказывает целиком.
    if v_resolved is null then
      raise exception
        'Не удалось скопировать под-этапы: «%» идёт параллельно с «%», а '
        'этого под-этапа у варианта-приёмника нет. Скопируйте или создайте '
        'его первым.', v_title, v_partner_title
        using errcode = 'P0002';
    end if;

    update product_type_stages
       set parallel_with_stage_id = v_resolved
     where id = v_new_ids[i];
  end loop;

  return v_copied;
end;
$function$
;

-- create_product_type_config_draft(uuid)
-- md5: 20443a01c52eb6320ffb2445563718d4
CREATE OR REPLACE FUNCTION public.create_product_type_config_draft(p_product_type_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_draft      uuid;
  v_published  uuid;
  v_version    integer;
  v_stage      record;
  v_wp         record;
  v_new_stage  uuid;
  v_new_wp     uuid;
  v_new_parent uuid;
begin
  if p_product_type_id is null then
    raise exception
      'Не удалось создать черновик: не указан тип продукта.'
      using errcode = '22023';
  end if;

  -- Снимок версий этого типа фиксируется до COMMIT: параллельное открытие
  -- редактора подождёт и увидит уже созданный черновик.
  perform 1 from product_type_configs
   where product_type_id = p_product_type_id
   for update;

  select id into v_draft
    from product_type_configs
   where product_type_id = p_product_type_id
     and status = 'draft'
   order by version desc
   limit 1;

  if v_draft is not null then
    return v_draft;
  end if;

  select id into v_published
    from product_type_configs
   where product_type_id = p_product_type_id
     and status = 'published';

  select coalesce(max(version), 0) + 1 into v_version
    from product_type_configs
   where product_type_id = p_product_type_id;

  -- Формула переносится из публикуемой версии, а не берётся по умолчанию:
  -- черновик обязан быть её точной копией, иначе публикация правки подписи
  -- заодно меняла бы способ расчёта факта.
  insert into product_type_configs(
    product_type_id, version, status, note, actual_qty_formula)
  values (
    p_product_type_id, v_version, 'draft',
    'Черновик правки настроек типа продукта.',
    (select actual_qty_formula from product_type_configs
      where id = v_published))
  returning id into v_draft;

  -- У типа продукта может не быть опубликованной версии (свежая категория) —
  -- тогда копировать нечего и черновик стартует пустым.
  if v_published is null then
    return v_draft;
  end if;

  insert into product_type_form_blocks(config_id, block_code, is_visible, is_required)
  select v_draft, block_code, is_visible, is_required
    from product_type_form_blocks
   where config_id = v_published;

  -- Условия обязательности блоков едут вместе с блоками: без этой копии
  -- нажатие «Начать правку» молча стирало бы все условия — черновик
  -- становится опубликованной версией при первой же публикации.
  insert into product_type_form_block_conditions(
    config_id, block_code, predicate, negate, param_text)
  select v_draft, block_code, predicate, negate, param_text
    from product_type_form_block_conditions
   where config_id = v_published;

  -- Карты «старый id → новый»: рабочих мест — для parent_variant_id,
  -- этапов — для parallel_with_stage_id.
  --
  -- Имена схемы обязательны. При search_path = 'public', 'pg_temp' временная
  -- схема идёт ПОСЛЕ public, поэтому неквалифицированное имя досталось бы
  -- одноимённой постоянной таблице, появись такая, — и функция бесшумно
  -- писала бы карту не туда. Сегодня таких таблиц нет; квалификация снимает
  -- зависимость от этого обстоятельства.
  --
  -- drop if exists — на случай двух вызовов в одной транзакции: ON COMMIT
  -- DROP срабатывает лишь на коммите.
  drop table if exists pg_temp._draft_wp_map;
  create temporary table pg_temp._draft_wp_map(
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  drop table if exists pg_temp._draft_stage_map;
  create temporary table pg_temp._draft_stage_map(
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  -- Сначала верхний уровень: его рабочие места станут родителями под-этапов.
  --
  -- parallel_with_stage_id намеренно не заполняется здесь: партнёр — это id
  -- этапа той же версии, и на момент вставки его копия может ещё не
  -- существовать. Проставляется одним UPDATE после обоих проходов.
  for v_stage in
    select * from product_type_stages
     where config_id = v_published and level = 0
     order by position, stage_group_key
  loop
    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last, execution_mode)
    values (
      v_draft, null, 0, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last, v_stage.execution_mode)
    returning id into v_new_stage;

    insert into pg_temp._draft_stage_map(old_id, new_id)
    values (v_stage.id, v_new_stage);

    for v_wp in
      select * from product_type_stage_workplaces
       where stage_id = v_stage.id
       order by sort_order
    loop
      insert into product_type_stage_workplaces(
        stage_id, workplace_id, variant_title, is_default, sort_order)
      values (v_new_stage, v_wp.workplace_id, v_wp.variant_title,
              v_wp.is_default, v_wp.sort_order)
      returning id into v_new_wp;

      insert into pg_temp._draft_wp_map(old_id, new_id) values (v_wp.id, v_new_wp);
    end loop;

    insert into product_type_stage_conditions(
      stage_id, predicate, negate, param_text)
    select v_new_stage, predicate, negate, param_text
      from product_type_stage_conditions
     where stage_id = v_stage.id;
  end loop;

  -- Теперь под-этапы: родитель уже скопирован, его новый id есть в карте.
  for v_stage in
    select * from product_type_stages
     where config_id = v_published and level = 1
     order by position, stage_group_key
  loop
    select new_id into v_new_parent
      from pg_temp._draft_wp_map
     where old_id = v_stage.parent_variant_id;

    if v_new_parent is null then
      raise exception
        'Не удалось создать черновик: под-этап «%» ссылается на вариант, '
        'которого нет в опубликованной версии.', v_stage.title
        using errcode = '23503';
    end if;

    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last, execution_mode)
    values (
      v_draft, v_new_parent, 1, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last, v_stage.execution_mode)
    returning id into v_new_stage;

    insert into pg_temp._draft_stage_map(old_id, new_id)
    values (v_stage.id, v_new_stage);

    insert into product_type_stage_workplaces(
      stage_id, workplace_id, variant_title, is_default, sort_order)
    select v_new_stage, workplace_id, variant_title, is_default, sort_order
      from product_type_stage_workplaces
     where stage_id = v_stage.id;

    insert into product_type_stage_conditions(
      stage_id, predicate, negate, param_text)
    select v_new_stage, predicate, negate, param_text
      from product_type_stage_conditions
     where stage_id = v_stage.id;
  end loop;

  -- Партнёры: ссылка переводится на копию партнёра внутри черновика. Если бы
  -- id переносился как есть, черновик указывал бы на этап ОПУБЛИКОВАННОЙ
  -- версии — validate_product_type_config поймал бы это как
  -- parallel_partner_foreign_config, но лишь при публикации.
  update product_type_stages d
     set parallel_with_stage_id = pm.new_id
    from pg_temp._draft_stage_map sm
    join product_type_stages src on src.id = sm.old_id
    join pg_temp._draft_stage_map pm on pm.old_id = src.parallel_with_stage_id
   where d.id = sm.new_id;

  return v_draft;
end;
$function$
;

-- create_user_folder(text,uuid)
-- md5: 716903f6a737d9323bc682ae455ccb28
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

-- data_health_report()
-- md5: 7e2fb0dec62fc4ee473fb534c18e6055
CREATE OR REPLACE FUNCTION public.data_health_report()
 RETURNS TABLE(code text, severity text, title text, affected bigint, hint text, sample jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
with
debts as (
  select w.order_id, w.paint_id, max(w.paint_name) as paint_name,
         sum(coalesce(w.actual_used_amount, w.planned_amount, 0)) as debt,
         min(w.created_at) as since
    from order_paint_pending_writeoffs w
   where w.status = 'pending'
   group by w.order_id, w.paint_id
),
debt_cover as (
  select d.*,
         coalesce((
           select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
             from order_paint_reservations r
            where r.order_id = d.order_id
              and (r.paint_id = d.paint_id
                   or (d.paint_id is null
                       and normalize_paint_name(r.paint_name) = normalize_paint_name(d.paint_name)))
         ), 0) as covered,
         p.quantity as stock,
         o.customer,
         o.status as order_status
    from debts d
    left join paints p on p.id = d.paint_id
    left join orders o on o.id::text = d.order_id
),
task_facts as (
  select t.id, t.order_id, t.stage_id, t.status, t.completed_at,
         (select w.name from workplaces w where w.id::text = t.stage_id) as workplace,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' = 'time_event'
              and task_json_payload(c->>'text') is not null
              and (task_json_payload(c->>'text')->>'endTime') is null
         ) as has_open_interval,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' = 'quantity_stage_total'
              and task_quantity_value(c->>'text') > 0
         ) as has_stage_total,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' in ('quantity_done', 'quantity_share', 'quantity_team_total')
         ) as has_personal
    from tasks t
),
dup_qty as (
  select distinct t.id as task_id, a->>'userId' as user_id, a->>'text' as qty_text
    from tasks t
    cross join lateral jsonb_array_elements(task_comments_to_array(t.comments)) a
    cross join lateral jsonb_array_elements(task_comments_to_array(t.comments)) b
   where a->>'type' = 'quantity_done'
     and b->>'type' = 'quantity_done'
     and a->>'id' is distinct from b->>'id'
     and a->>'userId' = b->>'userId'
     and a->>'text' = b->>'text'
     and task_comment_millis(b->>'timestamp') > task_comment_millis(a->>'timestamp')
     and task_comment_millis(b->>'timestamp') - task_comment_millis(a->>'timestamp') < 180000
),
paper_stage as (
  select o.id, o.customer, order_paper_writeoff_stage_key(o.id::text) as stage_key,
         (select sum(r.qty) from order_paper_reservations r where r.order_id = o.id) as reserved_m
    from orders o
   where o.paper_written_off_at is null
     and o.status not in ('draft', 'completed')
),
paper_ledger as (
  select p.id, p.description, p.quantity,
         coalesce(inv.counted_qty, 0)
         + coalesce((select sum(a.qty) from papers_arrivals a
                      where a.paper_id = p.id and a.canceled_at is null and (inv.created_at is null or a.created_at > inv.created_at)), 0)
         - coalesce((select sum(w.qty) from papers_writeoffs w
                      where w.paper_id = p.id and w.canceled_at is null and (inv.created_at is null or w.created_at > inv.created_at)), 0)
           as ledger
    from papers p
    left join lateral (
      select i.counted_qty, i.created_at from papers_inventories i
       where i.paper_id = p.id and i.canceled_at is null order by i.created_at desc limit 1
    ) inv on true
),
paint_ledger as (
  select p.id, p.description, p.quantity,
         coalesce(inv.counted_qty, 0)
         + coalesce((select sum(a.qty) from paints_arrivals a
                      where a.paint_id = p.id and a.canceled_at is null and (inv.created_at is null or a.created_at > inv.created_at)), 0)
         - coalesce((select sum(w.qty) from paints_writeoffs w
                      where w.paint_id = p.id and w.canceled_at is null and (inv.created_at is null or w.created_at > inv.created_at)), 0)
           as ledger
    from paints p
    left join lateral (
      select i.counted_qty, i.created_at from paints_inventories i
       where i.paint_id = p.id and i.canceled_at is null order by i.created_at desc limit 1
    ) inv on true
),
required_triggers(tbl, name) as (
  values
    ('tasks', 'tasks_close_intervals_on_complete'),
    ('tasks', 'tasks_guard_active_assignees'),
    ('paints_writeoffs', 'trg_paints_writeoff_apply'),
    ('paints_arrivals', 'trg_paints_arrival_apply'),
    ('paints_inventories', 'trg_paints_inventory_apply'),
    ('papers_writeoffs', 'trg_papers_writeoff_apply'),
    ('papers_arrivals', 'trg_papers_arrival_apply'),
    ('papers_inventories', 'trg_papers_inventory_apply'),
    ('order_paint_pending_writeoffs', 'release_reserve_when_debt_gone')
),
missing_triggers as (
  select rt.tbl, rt.name
    from required_triggers rt
   where not exists (
     select 1 from pg_trigger tg
      where tg.tgrelid = to_regclass('public.' || rt.tbl)
        and tg.tgname = rt.name
        and not tg.tgisinternal
   )
),
checks as (
  select 'missing_triggers' as code, 'critical' as severity,
         'Нет обязательного триггера' as title,
         (select count(*) from missing_triggers) as affected,
         'Без триггера остаток склада или интервалы времени перестают обновляться. Накатить миграцию, создающую триггер.' as hint,
         (select jsonb_agg(tbl || '.' || name) from missing_triggers) as sample
  union all
  select 'paint_debt_without_reserve', 'critical', 'Краска под отложенным списанием без брони', count(*),
         'Краску заберёт другой заказ, списание долга упадёт с «Недостаточно краски». Если остатка не хватает — инвентаризация.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name, 'долг_г', debt, 'бронь_г', covered, 'остаток_г', stock) x
              from debt_cover where debt > covered + 0.5 order by since limit 10) s)
    from debt_cover where debt > covered + 0.5
  union all
  select 'paint_debt_exceeds_stock', 'warning', 'Долг по краске больше складского остатка', count(*),
         'Списать такой долг нельзя — проверка остатка откажет. Нужна инвентаризация краски.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name, 'долг_г', debt, 'остаток_г', stock) x
              from debt_cover where paint_id is not null and debt > coalesce(stock, 0) order by since limit 10) s)
    from debt_cover where paint_id is not null and debt > coalesce(stock, 0)
  union all
  select 'paint_debt_unknown_paint', 'warning', 'Отложенное списание без краски склада', count(*),
         'Имя краски в долге не совпало ни с одной карточкой склада. Завести краску или исправить имя.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name, 'долг_г', debt) x
              from debt_cover where paint_id is null order by since limit 10) s)
    from debt_cover where paint_id is null
  union all
  select 'paint_debt_stale', 'info', 'Отложенное списание висит больше 14 дней', count(*),
         'Долг держит бронь краски. Если краску уже израсходовали иначе — списать вручную.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name, 'с', since::date, 'долг_г', debt) x
              from debt_cover where since < now() - interval '14 days' order by since limit 10) s)
    from debt_cover where since < now() - interval '14 days'
  union all
  select 'completed_task_open_interval', 'critical', 'Завершённый этап с открытым интервалом времени', count(*),
         'Время «тикает» после завершения: неверные часы и доли. Проверить триггер tasks_close_intervals_on_complete.',
         (select jsonb_agg(x) from (select jsonb_build_object('задача', id, 'рм', workplace) x from task_facts where status = 'completed' and has_open_interval limit 10) s)
    from task_facts where status = 'completed' and has_open_interval
  union all
  select 'completed_task_without_completed_at', 'warning', 'Завершённый этап без времени завершения', count(*),
         'Время завершения берётся из updated_at и сдвигается любой правкой строки.',
         (select jsonb_agg(x) from (select jsonb_build_object('задача', id, 'рм', workplace) x from task_facts where status = 'completed' and completed_at is null limit 10) s)
    from task_facts where status = 'completed' and completed_at is null
  union all
  select 'completed_task_without_personal_qty', 'critical', 'Закрытый этап с тиражом, но без личного количества', count(*),
         'Выработка сотрудников не попадёт в аналитику и сдельную. Выполнить recompute_task_quantity_shares(задача).',
         (select jsonb_agg(x) from (select jsonb_build_object('задача', id, 'рм', workplace) x from task_facts where status = 'completed' and has_stage_total and not has_personal limit 10) s)
    from task_facts where status = 'completed' and has_stage_total and not has_personal
  union all
  select 'duplicate_quantity_done', 'warning', 'Повтор личного количества (тот же человек и число в пределах 3 минут)', count(*),
         'Скорее всего двойное нажатие «Завершить». Сверить с цехом и удалить лишнюю запись через правку количества.',
         (select jsonb_agg(x) from (select jsonb_build_object('задача', task_id, 'сотрудник', user_id, 'количество', qty_text) x from dup_qty limit 10) s)
    from dup_qty
  union all
  select 'paper_stage_closed_not_written_off', 'warning', 'Этап списания бумаги закрыт, бумага не списана', count(*),
         'Бронь держит метры, которых на складе физически нет. Выполнить finalize_order_paper_reservations(заказ).',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(ps.customer, ps.id::text), 'бронь_м', ps.reserved_m) x
              from paper_stage ps
             where ps.stage_key is not null and coalesce(ps.reserved_m, 0) > 0
               and exists (select 1 from tasks t where t.order_id = ps.id and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key)
               and not exists (select 1 from tasks t where t.order_id = ps.id and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key and t.status <> 'completed')
             limit 10) s)
    from paper_stage ps
   where ps.stage_key is not null and coalesce(ps.reserved_m, 0) > 0
     and exists (select 1 from tasks t where t.order_id = ps.id and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key)
     and not exists (select 1 from tasks t where t.order_id = ps.id and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key and t.status <> 'completed')
  union all
  select 'paint_reserved_cache_mismatch', 'warning', 'Кэш брони краски не совпадает с бронями заказов', count(*),
         'Выполнить recalculate_paint_reserved_qty(null) для этих красок.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('краска', p.description, 'кэш_г', p.reserved_qty) x from paints p
             where abs(coalesce(p.reserved_qty, 0) - coalesce((select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)) from order_paint_reservations r where r.paint_id = p.id), 0)) > 0.5
             limit 10) s)
    from paints p
   where abs(coalesce(p.reserved_qty, 0) - coalesce((select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)) from order_paint_reservations r where r.paint_id = p.id), 0)) > 0.5
  union all
  select 'paper_stock_ledger_mismatch', 'info', 'Остаток бумаги не сходится с журналом склада', count(*),
         'Остаток правили в обход журнала (возврат, ручная правка, отмена списания). Провести инвентаризацию.',
         (select jsonb_agg(x) from (select jsonb_build_object('бумага', description, 'остаток', quantity, 'по_журналу', round(ledger::numeric, 2)) x from paper_ledger where abs(quantity - ledger) > 1 order by abs(quantity - ledger) desc limit 10) s)
    from paper_ledger where abs(quantity - ledger) > 1
  union all
  select 'paint_stock_ledger_mismatch', 'info', 'Остаток краски не сходится с журналом склада', count(*),
         'Остаток правили в обход журнала (возврат, ручная правка, отмена списания). Провести инвентаризацию.',
         (select jsonb_agg(x) from (select jsonb_build_object('краска', description, 'остаток', quantity, 'по_журналу', round(ledger::numeric, 2)) x from paint_ledger where abs(quantity - ledger) > 1 order by abs(quantity - ledger) desc limit 10) s)
    from paint_ledger where abs(quantity - ledger) > 1
  union all
  select 'auto_writeoff_without_order', 'critical', 'Автосписание склада без заказа', count(*),
         'Списание по заказу записано без order_id. Проверить триггер aa_writeoffs_fill_trace и вызывающую функцию.',
         (select jsonb_agg(x) from (select jsonb_build_object('таблица', t, 'причина', reason, 'когда', created_at) x from (
            select 'papers' t, reason, created_at from papers_writeoffs where source like 'paper%' and order_id is null and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz
            union all select 'paints', reason, created_at from paints_writeoffs where source in ('flex_now', 'flex_queue') and order_id is null and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz) a limit 10) s)
    from (select 1 from papers_writeoffs where source like 'paper%' and order_id is null and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz
          union all select 1 from paints_writeoffs where source in ('flex_now', 'flex_queue') and order_id is null and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz) x
  union all
  select 'writeoff_without_employee', 'info', 'Списание склада без привязки к сотруднику', count(*),
         'В by_name не id и не однозначное ФИО сотрудника — кто списал, по базе не установить.',
         (select jsonb_agg(distinct by_name) from (select by_name from papers_writeoffs where employee_id is null and coalesce(by_name, '') not in ('', 'system') and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz
            union all select by_name from paints_writeoffs where employee_id is null and coalesce(by_name, '') not in ('', 'system') and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz) s)
    from (select 1 from papers_writeoffs where employee_id is null and coalesce(by_name, '') not in ('', 'system') and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz
          union all select 1 from paints_writeoffs where employee_id is null and coalesce(by_name, '') not in ('', 'system') and created_at >= '2026-09-14 09:45:08.213835+00'::timestamptz) y
  union all
  select 'functions_changed_recently', 'info', 'Функции базы, изменённые за 7 дней', (select count(distinct object_identity) from schema_change_log   where object_type in ('function', 'procedure') and changed_at > now() - interval '7 days'),
         'Сверьте со списком миграций: изменение не из миграции — повод разобраться, кто и зачем.',
         (select jsonb_agg(x) from (select jsonb_build_object('функция', object_identity, 'когда', max(changed_at), 'откуда', string_agg(distinct coalesce(application_name, '?'), ', '), 'раз', count(*)) x   from schema_change_log where object_type in ('function', 'procedure') and changed_at > now() - interval '7 days'   group by object_identity order by max(changed_at) desc limit 10) s)
  union all
  select 'orphan_paint_rows', 'info', 'Брони и долги краски удалённых заказов',
         (select count(*) from order_paint_reservations r where not exists (select 1 from orders o where o.id::text = r.order_id))
         + (select count(*) from order_paint_pending_writeoffs w where w.status = 'pending' and not exists (select 1 from orders o where o.id::text = w.order_id)),
         'Заказа нет, а строки остались. Бронь таких строк занимает краску зря.', null
)
select c.code, c.severity, c.title, c.affected, c.hint, c.sample
  from checks c
 where c.affected > 0
 order by case c.severity when 'critical' then 0 when 'warning' then 1 else 2 end, c.affected desc;
$function$
;

-- delete_app_installer(text)
-- md5: 4db9a9b66231f716c9aa089d41f48d03
CREATE OR REPLACE FUNCTION public.delete_app_installer(p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_platform text := lower(btrim(coalesce(p_platform, '')));
  v_row      public.app_installers%rowtype;
begin
  select * into v_row from public.app_installers where platform = v_platform;
  if not found then
    return jsonb_build_object('removed', false, 'object_path', null);
  end if;

  update public.app_installer_releases
     set replaced_at = coalesce(replaced_at, now()),
         file_url    = '',
         object_path = ''
   where platform = v_platform;

  delete from public.app_installers where platform = v_platform;

  return jsonb_build_object('removed', true, 'object_path', v_row.object_path);
end;
$function$
;

-- documents_sync_type_collection()
-- md5: 1bc71b30785d8cab14cea534f9941e14
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

-- employee_id_from_actor(text)
-- md5: 02b22d9496bd435ebab104cdcb645853
CREATE OR REPLACE FUNCTION public.employee_id_from_actor(p_actor text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- by_name бывает id сотрудника, ФИО («Иванов Иван Иванович», иногда с
  -- хвостом «Склад» или «.») или «system». ФИО принимается только
  -- однозначное: однофамильцев лучше оставить без привязки, чем привязать
  -- не к тому.
  with a as (
    select trim(coalesce(p_actor, '')) as raw,
           trim(regexp_replace(regexp_replace(lower(coalesce(p_actor, '')),
                '[^[:alpha:][:space:]]', ' ', 'g'), '\s+', ' ', 'g')) as norm
  ),
  by_id as (
    select e.id from employees e, a where e.id = a.raw
  ),
  by_name as (
    select e.id
      from employees e, a
     where a.norm <> ''
       and trim(regexp_replace(regexp_replace(lower(concat_ws(' ', e.last_name, e.first_name, e.patronymic)),
                '[^[:alpha:][:space:]]', ' ', 'g'), '\s+', ' ', 'g')) = a.norm
  )
  select coalesce(
    (select id from by_id limit 1),
    (select min(id) from by_name having count(*) = 1)
  );
$function$
;

-- employee_verify_password(text,text)
-- md5: e21a16431e654eb1090e4b9518a4cd0f
CREATE OR REPLACE FUNCTION public.employee_verify_password(p_employee_id text, p_password text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_hash text;
begin
  select h.password_hash into v_hash
    from employee_password_hashes h
    join employees e on e.id = h.employee_id
   where h.employee_id = p_employee_id
     and coalesce(e.is_fired, false) = false;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(trim(coalesce(p_password, '')), v_hash);
end
$function$
;

-- employees_sync_password_hash()
-- md5: ce516310abadd2c1d20882291fa71f73
CREATE OR REPLACE FUNCTION public.employees_sync_password_hash()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if coalesce(trim(new.password), '') = '' then
    return null;
  end if;
  if tg_op = 'UPDATE'
     and new.password is not distinct from old.password
     and exists (select 1 from employee_password_hashes h where h.employee_id = new.id) then
    return null;
  end if;

  insert into employee_password_hashes(employee_id, password_hash, updated_at)
  values (new.id, extensions.crypt(trim(new.password), extensions.gen_salt('bf', 8)), now())
  on conflict (employee_id) do update
    set password_hash = excluded.password_hash,
        updated_at = excluded.updated_at;
  return null;
end
$function$
;

-- finalize_order_paper_reservations(text,text)
-- md5: 19117ceb508ec00fb00ac3aab7899998
CREATE OR REPLACE FUNCTION public.finalize_order_paper_reservations(p_order_id text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record; v_order_id order_paper_reservations.order_id%type; v_already timestamptz; v_label text; v_reason text; v_shipped timestamptz; v_source text;
begin
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  v_order_id := p_order_id;
  select o.paper_written_off_at, nullif(btrim(o.customer), ''), o.shipped_at into v_already, v_label, v_shipped from public.orders o where o.id::text = p_order_id;
  -- Расход записан по факту (record_order_paper_usage): остаток брони возвращается,
  -- длина в заказе = итог. Повторное закрытие после «Возобновить» пересчитывает итог.
  if exists (select 1 from public.papers_writeoffs w where w.order_id = v_order_id and w.canceled_at is null and w.task_id is not null) then
    delete from public.order_paper_reservations where order_id = v_order_id;
    perform public.order_paper_apply_fact_lengths(p_order_id);
    update public.orders set paper_written_off_at = coalesce(paper_written_off_at, now()) where id::text = p_order_id;
    return;
  end if;
  if v_already is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;
  -- Расхода по факту нет (старая сборка, заказ без маршрута): списываем бронь, как раньше.
  v_reason := format('Списание бумаги по заказу %s', coalesce(v_label, p_order_id));
  v_source := case
    when exists (select 1 from public.tasks t where t.order_id::text = p_order_id and t.status <> 'completed') then 'paper_stage'
    when v_shipped is not null then 'paper_shipment'
    else 'paper_order_completed' end;
  for rec in select r.paper_id, r.qty from public.order_paper_reservations r where r.order_id = v_order_id for update loop
    if rec.qty <= 0 then continue; end if;
    insert into public.papers_writeoffs(paper_id, qty, reason, by_name, order_id, source)
    values (rec.paper_id, rec.qty, v_reason, coalesce(nullif(trim(p_actor), ''), 'system'), v_order_id, v_source);
  end loop;
  update public.orders set paper_written_off_at = now() where id::text = p_order_id;
  delete from public.order_paper_reservations where order_id = v_order_id;
end;
$function$
;

-- find_forms(text,integer)
-- md5: 1e5da61a6adf7e18976084f8b592f3f7
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

-- fn_pens_apply_arrival()
-- md5: 80cabf2768715831a4917aa249142f23
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

-- fn_pens_apply_inventory()
-- md5: 5a4dfb01f0b9ea6171dffe8032fefa48
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

-- fn_pens_apply_writeoff()
-- md5: 864a7c4ad8de27d7c31abfb1547a80fb
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

-- fn_set_updated_at()
-- md5: 2c082e458decc59b141e8e97261c3e4b
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

-- form_allocate(text,text,text)
-- md5: 325ce51ff774ef8031e27449ea858646
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

-- get_order_generation_chain(text)
-- md5: 2c8d36dd61f2632bfd5583b82af8d165
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

-- get_order_restart_history(text,integer)
-- md5: eb56e7658f41739270454652a1153ea7
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

-- guard_carryover_paint_removal()
-- md5: 070d55dfc9acb7eb11037b1894aafdc8
CREATE OR REPLACE FUNCTION public.guard_carryover_paint_removal()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_name text := public.normalize_paint_name(old.name);
  v_assignment_created boolean;
  v_status text;
  v_pending record;
  v_customer text;
begin
  if v_name = '' then
    return null;
  end if;

  -- Заказ удалён целиком в этой же транзакции (каскад) — список красок
  -- заказа перестаёт существовать, защищать нечего.
  select o.assignment_created, o.status
    into v_assignment_created, v_status
  from public.orders o
  where o.id = old.order_id;

  if not found then
    return null;
  end if;

  -- Дозапускной заказ — это план, а не производство: его состав правят
  -- свободно. Завершённый заказ красок больше не расходует.
  if not coalesce(v_assignment_created, false)
     or coalesce(v_status, '') = 'completed' then
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

  -- Сирота (заказ-источник удалён) блокировать ничего не может: показать
  -- такую строку оператору всё равно негде.
  select w.id, w.order_id
    into v_pending
  from public.order_paint_pending_writeoffs w
  where w.status = 'pending'
    and w.order_id <> old.order_id::text
    and public.normalize_paint_name(w.paint_name) = v_name
    and exists (select 1 from public.orders o2 where o2.id::text = w.order_id)
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

-- insert_product_type_stage(uuid,text,text,text,uuid)
-- md5: 777b023155a81f9c368193d9e6b80edd
CREATE OR REPLACE FUNCTION public.insert_product_type_stage(p_config_id uuid, p_stage_group_key text, p_title text, p_workplace_id text, p_parent_variant_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rank          integer;
  v_level         integer;
  v_parent_stage  uuid;
  v_parent_mode   text;
  v_parent_config uuid;
  v_stage         uuid;
begin
  if p_config_id is null or p_stage_group_key is null
     or p_title is null or p_workplace_id is null then
    raise exception
      'Не удалось создать этап: не хватает данных.'
      using errcode = '22023';
  end if;

  -- Блокировка версии до COMMIT: два одновременных добавления иначе получили
  -- бы один и тот же ранг и слиплись бы в одну группу.
  perform 1 from product_type_configs where id = p_config_id for update;

  if not found then
    raise exception
      'Не удалось создать этап: версия настроек не найдена. Обновите экран.'
      using errcode = 'P0002';
  end if;

  v_level := case when p_parent_variant_id is null then 0 else 1 end;

  if p_parent_variant_id is not null then
    select w.stage_id, s.selection_mode, s.config_id
      into v_parent_stage, v_parent_mode, v_parent_config
      from product_type_stage_workplaces w
      join product_type_stages s on s.id = w.stage_id
     where w.id = p_parent_variant_id;

    if v_parent_stage is null then
      raise exception
        'Не удалось создать под-этап: вариант не найден. Обновите экран.'
        using errcode = 'P0002';
    end if;

    if v_parent_config <> p_config_id then
      raise exception
        'Не удалось создать под-этап: вариант принадлежит другой версии '
        'настроек. Обновите экран.'
        using errcode = '22023';
    end if;

    if v_parent_mode <> 'one_of' then
      raise exception
        'Не удалось создать под-этап: этап-владелец не переключаемый.'
        using errcode = '22023';
    end if;
  end if;

  select coalesce(max(position), 0) + 1 into v_rank
    from product_type_stages
   where config_id = p_config_id
     and not is_pinned_last;

  -- Закреплённый этап уходит на ранг выше нового. Это и есть та вторая
  -- половина операции, ради атомарности которой функция существует.
  update product_type_stages
     set position = v_rank + 1
   where config_id = p_config_id
     and is_pinned_last;

  insert into product_type_stages(
    config_id, parent_variant_id, level, stage_group_key, title,
    position, selection_mode)
  values (
    p_config_id, p_parent_variant_id, v_level, p_stage_group_key, p_title,
    v_rank, 'all')
  returning id into v_stage;

  insert into product_type_stage_workplaces(
    stage_id, workplace_id, is_default, sort_order)
  values (v_stage, p_workplace_id, false, 1);

  return v_stage;
end;
$function$
;

-- inventory_set(text,uuid,numeric,text,text)
-- md5: 29027d8b1de622509ee1a04f4e87b6b1
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

-- log_prod_stage_status()
-- md5: c01ac278f8950173e5865c9490324ee7
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

-- log_schema_change()
-- md5: 33b377bec021df2f19501be5f09707f6
CREATE OR REPLACE FUNCTION public.log_schema_change()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    begin
      if r.schema_name is null or r.schema_name not in ('public', 'production') then
        continue;
      end if;
      if r.object_identity like 'public.schema_change_log%' then
        continue;
      end if;
      insert into public.schema_change_log(event, command_tag, object_type, object_identity, definition_md5, statement)
      values (
        'ddl_command_end',
        r.command_tag,
        r.object_type,
        r.object_identity,
        case when r.object_type in ('function', 'procedure')
             then md5(pg_get_functiondef(r.objid)) end,
        left(current_query(), 20000)
      );
    exception when others then
      null;
    end;
  end loop;
exception when others then
  null;
end
$function$
;

-- log_schema_drop()
-- md5: 8330201e12fbfc7ae96e3f15e60af948
CREATE OR REPLACE FUNCTION public.log_schema_drop()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in select * from pg_event_trigger_dropped_objects() loop
    begin
      if r.schema_name is null or r.schema_name not in ('public', 'production') then
        continue;
      end if;
      if not r.original then
        continue;
      end if;
      insert into public.schema_change_log(event, command_tag, object_type, object_identity, statement)
      values ('sql_drop', tg_tag, r.object_type, r.object_identity, left(current_query(), 20000));
    exception when others then
      null;
    end;
  end loop;
exception when others then
  null;
end
$function$
;

-- mark_app_update_seen(text,uuid,boolean)
-- md5: 196cc7f6c19fe9dcf2235140c1f5cdc9
CREATE OR REPLACE FUNCTION public.mark_app_update_seen(p_employee_id text, p_notification_id uuid DEFAULT NULL::uuid, p_downloaded boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer := 0;
begin
  if btrim(coalesce(p_employee_id, '')) = '' then
    return 0;
  end if;

  update public.app_update_notifications
     set seen_at       = coalesce(seen_at, now()),
         downloaded_at = case
                           when p_downloaded then coalesce(downloaded_at, now())
                           else downloaded_at
                         end
   where employee_id = p_employee_id
     and (p_notification_id is null or id = p_notification_id);

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

-- materials_apply_arrival()
-- md5: 6356fcca2d9b36ae4e0e54e4eaa9ed44
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

-- materials_apply_inventory()
-- md5: 2dc543fe0ace44434fe6ece9ea8619cc
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

-- materials_apply_writeoff()
-- md5: 35d45736ffdaa5e8fbe513ab0725dc24
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

-- next_form_number(text)
-- md5: 90b0004a977e6c3b19671ffa552bc9ec
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

-- normalize_paint_name(text)
-- md5: 8c3e903cb882d071c8f3e2581118a2a2
CREATE OR REPLACE FUNCTION public.normalize_paint_name(value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select lower(regexp_replace(btrim(coalesce(value, '')), '\s+', ' ', 'g'));
$function$
;

-- order_actual_qty_compute(text,text)
-- md5: 9f45948fadbd63e12ede9a5c35f7e414
CREATE OR REPLACE FUNCTION public.order_actual_qty_compute(p_order_id text, p_completed_stage_id text DEFAULT NULL::text)
 RETURNS double precision
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_has_packaging boolean;
  v_packaging_done boolean;
  v_packaging_ms bigint;
  v_result double precision;
  v_stage text := nullif(trim(coalesce(p_completed_stage_id, '')), '');
begin
  if coalesce(trim(p_order_id), '') = '' then return null; end if;
  if not exists (select 1 from orders o where o.id::text = p_order_id) then return null; end if;

  select count(*) > 0, coalesce(bool_and(r.status = 'completed'), false), max(r.completion_ms)
    into v_has_packaging, v_packaging_done, v_packaging_ms
    from public.order_actual_qty_rows(p_order_id) r
   where r.is_pack;

  -- Факт — только то, что зафиксировано после завершения упаковки: её
  -- собственные записи и этапы, записавшие количество не раньше её закрытия.
  -- Из них берётся ОДНА группа этапа — записавшая количество последней.
  if v_has_packaging then
    if not v_packaging_done then return null; end if;
    select g.total into v_result
      from (select r.grp, sum(r.qty) as total, max(r.latest_ms) as latest
              from public.order_actual_qty_rows(p_order_id) r
             where r.qty > 0 and (r.is_pack or r.latest_ms >= v_packaging_ms)
             group by r.grp) g
     order by g.latest desc
     limit 1;
    return v_result;
  end if;

  -- Заказ без упаковки (легаси): количество последнего этапа маршрута.
  if v_stage is null then return null; end if;
  if not exists (select 1 from tasks t where t.order_id::text = p_order_id and t.stage_id = v_stage)
     or exists (select 1 from tasks t
                 where t.order_id::text = p_order_id and t.stage_id = v_stage
                   and t.status <> 'completed') then
    return null;
  end if;
  if not public.order_stage_is_last(p_order_id, v_stage) then return null; end if;

  select coalesce(sum(q.qty), 0) into v_result
    from tasks t
    cross join lateral public.task_order_quantity_measure(t.comments, t.assignees, null, 1) q
   where t.order_id::text = p_order_id and t.stage_id = v_stage;
  return v_result;
end
$function$
;

-- order_actual_qty_rows(text)
-- md5: 78d11cc5ae1138569f872f2af2539fe5
CREATE OR REPLACE FUNCTION public.order_actual_qty_rows(p_order_id text)
 RETURNS TABLE(stage_id text, grp text, status text, is_pack boolean, completion_ms bigint, qty double precision, latest_ms bigint)
 LANGUAGE sql
 STABLE
AS $function$
  select t.stage_id,
         coalesce(nullif(trim(coalesce(t.stage_group_key, '')), ''), t.stage_id),
         t.status,
         public.stage_is_packaging(t.stage_id, w.name, t.stage_group_key),
         coalesce(
           nullif(greatest(coalesce(t.completed_at, 0), 0), 0),
           nullif((select max(public.task_comment_millis(e->>'timestamp'))
                     from jsonb_array_elements(public.task_comments_to_array(t.comments)) e
                    where e->>'type' in ('user_done', 'quantity_done', 'quantity_team_total', 'finish_note')), 0),
           floor(extract(epoch from t.updated_at) * 1000)::bigint,
           0),
         q.qty,
         q.latest_ms
    from public.tasks t
    left join public.workplaces w on w.id::text = t.stage_id
    cross join lateral public.task_order_quantity_measure(
      t.comments, t.assignees, w.unit, public.order_pack_size(p_order_id)) q
   where t.order_id::text = p_order_id;
$function$
;

-- order_pack_size(text)
-- md5: 0d871d05c6d3abece2f2d260af6a1eec
CREATE OR REPLACE FUNCTION public.order_pack_size(p_order_id text)
 RETURNS double precision
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce((
           select replace(mm.arr[1], ',', '.')::double precision
             from unnest(o.additional_params) with ordinality as p(val, ord)
             cross join lateral (
               select regexp_match(substr(trim(p.val), char_length('упаковка:') + 1),
                                   '\d+(?:[.,]\d+)?') as arr
             ) mm
            where lower(trim(p.val)) like 'упаковка:%'
              and mm.arr is not null
              and replace(mm.arr[1], ',', '.')::double precision > 0
            order by p.ord
            limit 1), 1)
    from public.orders o
   where o.id::text = p_order_id;
$function$
;

-- order_paint_pending_debt_grams(text,uuid,text)
-- md5: 78d7d2549088feb67007d8e2ad76343f
CREATE OR REPLACE FUNCTION public.order_paint_pending_debt_grams(p_order_id text, p_paint_id uuid, p_paint_name text DEFAULT NULL::text)
 RETURNS double precision
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Строка долга с paint_id сравнивается только по id: иначе две краски с
  -- одинаковым именем (на складе такие есть) делили бы один долг на двоих.
  select coalesce(sum(coalesce(w.actual_used_amount, w.planned_amount, 0)), 0)
    from public.order_paint_pending_writeoffs w
   where w.order_id = p_order_id
     and w.status = 'pending'
     and (
       (p_paint_id is not null and w.paint_id = p_paint_id)
       or (
         w.paint_id is null
         and coalesce(trim(p_paint_name), '') <> ''
         and public.normalize_paint_name(w.paint_name)
             = public.normalize_paint_name(p_paint_name)
       )
     );
$function$
;

-- order_paper_apply_fact_lengths(text)
-- md5: e0943ed18bd8077488b61446ae94321a
CREATE OR REPLACE FUNCTION public.order_paper_apply_fact_lengths(p_order_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order public.orders%rowtype; v_totals jsonb; v_list jsonb; v_first jsonb; v_first_total numeric;
begin
  select * into v_order from public.orders where id::text = p_order_id for update;
  if not found then return; end if;
  select coalesce(jsonb_object_agg(w.paper_id::text, w.qty), '{}'::jsonb) into v_totals
    from (select paper_id, sum(qty) as qty from public.papers_writeoffs where order_id = v_order.id and canceled_at is null group by paper_id) w;
  -- Бумага в двух слотах сразу: итог не разделить — такой слот не трогаем.
  if jsonb_typeof(v_order.material_list) = 'array' and jsonb_array_length(v_order.material_list) > 0 then
    select jsonb_agg(
             case when (select count(*) from jsonb_array_elements(v_order.material_list) d where d->>'id' = e.value->>'id') = 1
                 then e.value || jsonb_build_object('quantity', coalesce((v_totals->>(e.value->>'id'))::numeric, 0))
                      || case when e.ord = 1 then '{}'::jsonb
                              else jsonb_build_object('extra', coalesce(case when jsonb_typeof(e.value->'extra') = 'object' then e.value->'extra' end, '{}'::jsonb)
                                     || jsonb_build_object('lengthL', coalesce((v_totals->>(e.value->>'id'))::numeric, 0))) end
               else e.value end order by e.ord)
      into v_list from jsonb_array_elements(v_order.material_list) with ordinality as e(value, ord);
    v_first := v_list->0;
  else
    v_list := v_order.material_list;
    v_first := case when jsonb_typeof(v_order.material) = 'object' then v_order.material end;
    if v_first is not null then
      v_first := v_first || jsonb_build_object('quantity', coalesce((v_totals->>(v_first->>'id'))::numeric, 0));
    end if;
  end if;
  v_first_total := case when v_first is not null then (v_totals->>(v_first->>'id'))::numeric end;
  update public.orders
     set material_list = coalesce(v_list, material_list),
         material = case when v_first is not null and jsonb_typeof(material) = 'object' and material->>'id' = v_first->>'id'
                         then material || jsonb_build_object('quantity', coalesce(v_first_total, 0)) else material end,
         product = case when v_first is not null and jsonb_typeof(product) = 'object'
                        then product || jsonb_build_object('length', coalesce(v_first_total, 0)) else product end
   where id = v_order.id;
end;
$function$
;

-- order_paper_slots(text)
-- md5: 4be11edcc4aee56f7b7b415bacb309af
CREATE OR REPLACE FUNCTION public.order_paper_slots(p_order_id text)
 RETURNS TABLE(slot_index integer, paper_id uuid, plan_qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Слот 0 — «Бумага №1»: длина в product.length; остальные — extra.lengthL,
  -- запасной вариант quantity (как order_details_card.dart, _paperLengthValue).
  with o as (select o.* from public.orders o where o.id::text = p_order_id),
  slots as (
    select case
             when jsonb_typeof(o.material_list) = 'array' and jsonb_array_length(o.material_list) > 0 then o.material_list
             when jsonb_typeof(o.material) = 'object' then jsonb_build_array(o.material)
             else '[]'::jsonb
           end as items, o.product
      from o)
  select (e.ord - 1)::int,
         case when e.value->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (e.value->>'id')::uuid end,
         greatest(coalesce(
           case when e.ord = 1 then nullif(public.task_quantity_value(s.product->>'length'), 0) end,
           nullif(public.task_quantity_value(e.value->'extra'->>'lengthL'), 0),
           nullif(public.task_quantity_value(e.value->>'quantity'), 0),
           0), 0)::numeric
    from slots s cross join lateral jsonb_array_elements(s.items) with ordinality as e(value, ord);
$function$
;

-- order_paper_usage_state(text)
-- md5: 681b8b2cd66f928a5ba572e6f4014a1f
CREATE OR REPLACE FUNCTION public.order_paper_usage_state(p_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order public.orders%rowtype;
  v_papers jsonb;
begin
  select * into v_order from public.orders where id::text = p_order_id;
  if not found then return null; end if;
  with slots as (select * from public.order_paper_slots(p_order_id)),
  written as (
    select w.paper_id, sum(w.qty) as qty from public.papers_writeoffs w
     where w.order_id = v_order.id and w.canceled_at is null group by w.paper_id),
  first_slot as (select paper_id, min(slot_index) as slot_index from slots where paper_id is not null group by paper_id),
  rows as (
    select s.slot_index, s.paper_id, s.plan_qty,
           case when fs.slot_index = s.slot_index then coalesce(w.qty, 0) else 0 end as written, true as in_order
      from slots s left join first_slot fs on fs.paper_id = s.paper_id left join written w on w.paper_id = s.paper_id
    union all
    select 1000 + row_number() over (order by w.paper_id)::int, w.paper_id, 0, w.qty, false
      from written w where not exists (select 1 from slots s where s.paper_id = w.paper_id))
  select coalesce(jsonb_agg(jsonb_build_object(
           'slot_index', r.slot_index, 'paper_id', r.paper_id, 'name', p.description, 'format', p.format,
           'grammage', p.grammage, 'unit', coalesce(nullif(p.unit, ''), 'м'), 'in_order', r.in_order,
           'plan', round(r.plan_qty, 3), 'written', round(r.written, 3),
           'remaining', round(greatest(r.plan_qty - r.written, 0), 3),
           'reserved', round(coalesce((select sum(x.qty) from public.order_paper_reservations x where x.order_id = v_order.id and x.paper_id = r.paper_id), 0)::numeric, 3),
           'stock', round(coalesce(p.quantity, 0), 3),
           'available_for_order', round(greatest(coalesce(p.quantity, 0) - coalesce((select sum(x.qty) from public.order_paper_reservations x where x.paper_id = r.paper_id and x.order_id <> v_order.id), 0)::numeric, 0), 3)
         ) order by r.slot_index), '[]'::jsonb)
    into v_papers from rows r left join public.papers p on p.id = r.paper_id;
  return jsonb_build_object('order_id', v_order.id, 'stage_key', public.order_paper_writeoff_stage_key(p_order_id),
    'closed', v_order.paper_written_off_at is not null,
    'has_fact_usage', exists (select 1 from public.papers_writeoffs w where w.order_id = v_order.id and w.canceled_at is null and w.task_id is not null),
    'papers', v_papers);
end;
$function$
;

-- order_paper_writeoff_stage_key(text)
-- md5: 75ee0ebff61cf7a19478921e588197d0
CREATE OR REPLACE FUNCTION public.order_paper_writeoff_stage_key(p_order_id text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- Этап бумаги (15.09.2026): ПЕРВЫЙ по маршруту из Бабинорезки/Флексопечати,
  -- без них — первый шаг маршрута. id — как в lib/modules/orders/production_ids.dart.
  c_bobbin constant text := 'b92a89d1-8e95-4c6d-b990-e308486e4bf1'; -- Бабинорезка
  c_flexo  constant text := '0571c01c-f086-47e4-81b2-5d8b2ab91218'; -- Флексопечать
  v_key text;
begin
  if coalesce(trim(p_order_id), '') = '' then return null; end if;
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id) into v_key
    from public.prod_plans p join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id and s.stage_id in (c_bobbin, c_flexo)
   order by s.step_no nulls last, s.seq nulls last, s.created_at limit 1;
  if v_key is not null then return v_key; end if;
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id) into v_key
    from public.prod_plans p join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
   order by s.step_no nulls last, s.seq nulls last, s.created_at limit 1;
  return v_key;
end;
$function$
;

-- order_stage_is_last(text,text)
-- md5: 3d95cf9c75945c261a1aba938add0888
CREATE OR REPLACE FUNCTION public.order_stage_is_last(p_order_id text, p_stage_id text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_plan_ids uuid[];
  v_max int;
begin
  select array_agg(id) into v_plan_ids from prod_plans where order_id::text = p_order_id;
  if coalesce(array_length(v_plan_ids, 1), 0) = 1
     and exists (select 1 from prod_plan_stages s where s.plan_id = v_plan_ids[1]) then
    select greatest(coalesce(max(coalesce(s.step_no, s.seq, 0)), 0), 0) into v_max
      from prod_plan_stages s where s.plan_id = v_plan_ids[1];
    return exists (
      select 1 from prod_plan_stages s
       where s.plan_id = v_plan_ids[1]
         and coalesce(s.step_no, s.seq, 0) = v_max
         and coalesce(nullif(s.stage_id, ''), s.id::text) = p_stage_id);
  end if;
  return not exists (
    select 1 from tasks t
     where t.order_id::text = p_order_id
       and coalesce(t.stage_id, '') not in ('', p_stage_id)
       and lower(coalesce(t.status, '')) <> 'completed');
end
$function$
;

-- orders_guard_actual_qty()
-- md5: 395d488b2478d8f933b877c3f621b2dd
CREATE OR REPLACE FUNCTION public.orders_guard_actual_qty()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.actual_qty is distinct from old.actual_qty
     and coalesce(current_setting('app.actual_qty_writer', true), '') <> 'server' then
    new.actual_qty := old.actual_qty;
  end if;
  return new;
end
$function$
;

-- paint_reservation_has_pending_debt(text,uuid,text)
-- md5: d513bf3b82fab0681b1d94344223c189
CREATE OR REPLACE FUNCTION public.paint_reservation_has_pending_debt(p_order_id text, p_paint_id uuid, p_paint_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from order_paint_pending_writeoffs w
     where w.order_id::text = p_order_id
       and w.status = 'pending'
       and (
         (p_paint_id is not null and w.paint_id = p_paint_id)
         or (
           coalesce(trim(p_paint_name), '') <> ''
           and public.normalize_paint_name(w.paint_name)
               = public.normalize_paint_name(p_paint_name)
         )
       )
  );
$function$
;

-- paints_apply_arrival()
-- md5: 7c126cab1c9e09900680e9015371f670
CREATE OR REPLACE FUNCTION public.paints_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update paints set quantity = coalesce(quantity, 0) + new.qty, updated_at = now() where id = new.paint_id;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- paints_apply_inventory()
-- md5: 07d0068cf37237d1b28bf4f2339eb83f
CREATE OR REPLACE FUNCTION public.paints_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update paints set quantity = new.counted_qty, updated_at = now()
   where id = new.paint_id and quantity is distinct from new.counted_qty;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- paints_apply_writeoff()
-- md5: d186e586311923858685fe55e7908cf0
CREATE OR REPLACE FUNCTION public.paints_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_stock numeric;
begin
  select quantity into v_stock from paints where id = new.paint_id for update;
  perform set_config('app.stock_writer', 'journal', true);
  if coalesce(v_stock, 0) >= new.qty then
    update paints set quantity = v_stock - new.qty, updated_at = now() where id = new.paint_id;
  else
    update paints set quantity = 0, updated_at = now() where id = new.paint_id;
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.paint_id, 0, coalesce(v_stock, 0) - new.qty, 'shortage',
            format('Недостача: списано %s при остатке %s', new.qty, coalesce(v_stock, 0)),
            new.by_name, new.created_by);
  end if;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- paper_consume(text,text,text,numeric,uuid,text)
-- md5: 31b4f1d8be16af833eae6aae6072ea31
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

-- paper_receive(text,text,text,numeric,text)
-- md5: 9f98b09e0ac73a3d058f5efc541cec85
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

-- papers_apply_arrival()
-- md5: f822e0f63e45e9a12e38e6be17294f72
CREATE OR REPLACE FUNCTION public.papers_apply_arrival()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update papers set quantity = coalesce(quantity, 0) + new.qty, updated_at = now() where id = new.paper_id;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- papers_apply_inventory()
-- md5: f675ccbe3d7d14555fd41c70c942addd
CREATE OR REPLACE FUNCTION public.papers_apply_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update papers set quantity = new.counted_qty, updated_at = now()
   where id = new.paper_id and quantity is distinct from new.counted_qty;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- papers_apply_writeoff()
-- md5: c66aaa9e8a2a11e50b5c06940dab5ed4
CREATE OR REPLACE FUNCTION public.papers_apply_writeoff()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_stock numeric;
begin
  select quantity into v_stock from papers where id = new.paper_id for update;
  perform set_config('app.stock_writer', 'journal', true);
  if coalesce(v_stock, 0) >= new.qty then
    update papers set quantity = v_stock - new.qty, updated_at = now() where id = new.paper_id;
  else
    -- Списали больше, чем числится: остаток обнуляется, а недостача не
    -- исчезает — она остаётся записью, которую видно в журнале.
    update papers set quantity = 0, updated_at = now() where id = new.paper_id;
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.paper_id, 0, coalesce(v_stock, 0) - new.qty, 'shortage',
            format('Недостача: списано %s при остатке %s', new.qty, coalesce(v_stock, 0)),
            new.by_name, new.created_by);
  end if;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$
;

-- pens_arrival(uuid,numeric,text)
-- md5: 56941e7b9039e1f1f00ad9c5cfde7843
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

-- pens_inventory(uuid,numeric,text)
-- md5: b16db998e40ca93a85f3700e8ecf2cc2
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

-- pens_upsert(text,text,text,text,numeric,numeric)
-- md5: e598b8ab14c5d98e05ccaddd6bf1d52c
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

-- pens_writeoff(uuid,numeric,text,uuid)
-- md5: 19c9dc40bcdf17fee3bba0d9390a4f29
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

-- prod_create_plan_from_template(uuid,uuid,text,text,text,uuid)
-- md5: 3759a58f998be150551499ccd71d0f0d
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

-- prune_task_event_requests(interval)
-- md5: 73fdcb37b3b77a66354c46f6fb1aee1e
CREATE OR REPLACE FUNCTION public.prune_task_event_requests(p_keep interval DEFAULT '7 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deleted integer;
begin
  delete from public.task_event_requests
   where created_at < now() - p_keep;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$function$
;

-- prune_workplace_queue_positions()
-- md5: b8d96a1e0fb419ff58db8df9f6810716
CREATE OR REPLACE FUNCTION public.prune_workplace_queue_positions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deleted integer;
begin
  delete from workplace_queue_positions p
   where
     -- заказа больше нет
     not exists (select 1 from orders o where o.id::text = p.order_id)
     -- заказ закрыт: в очередь он не вернётся
     or exists (
       select 1 from orders o
        where o.id::text = p.order_id
          and (o.status = 'completed' or o.shipped_at is not null)
     )
     -- строка ссылается на задачу, которой больше нет
     or (
       p.task_id is not null
       and not exists (select 1 from tasks t where t.id::text = p.task_id)
     );

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$
;

-- publish_app_installer(text,text,text,text,text,text,bigint,boolean,text,text,uuid,text)
-- md5: a2025d79a065d715891317b76bdbfbc5
CREATE OR REPLACE FUNCTION public.publish_app_installer(p_platform text, p_version text, p_release_notes text, p_file_name text, p_object_path text, p_file_url text, p_size_bytes bigint DEFAULT NULL::bigint, p_is_required boolean DEFAULT false, p_published_by text DEFAULT NULL::text, p_published_by_name text DEFAULT NULL::text, p_chat_sender_id uuid DEFAULT NULL::uuid, p_chat_room_id text DEFAULT 'general'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_platform   text := lower(btrim(coalesce(p_platform, '')));
  v_version    text := btrim(coalesce(p_version, ''));
  v_notes      text := btrim(coalesce(p_release_notes, ''));
  v_previous   public.app_installers%rowtype;
  v_release_id uuid;
  v_notified   integer := 0;
  v_os_label   text;
  v_chat_body  text;
begin
  if v_platform not in ('windows','android','macos','linux','ios') then
    raise exception 'Неизвестная платформа: %', p_platform;
  end if;
  if v_version = '' then
    raise exception 'Укажите версию установщика';
  end if;
  if v_notes = '' then
    raise exception 'Опишите, что изменилось в этой версии';
  end if;
  if btrim(coalesce(p_object_path, '')) = ''
     or btrim(coalesce(p_file_url, '')) = '' then
    raise exception 'Файл установщика не загружен';
  end if;

  select * into v_previous from public.app_installers where platform = v_platform;

  update public.app_installer_releases
     set replaced_at = now(),
         file_url    = '',
         object_path = ''
   where platform = v_platform and replaced_at is null;

  insert into public.app_installer_releases (
    platform, version, release_notes, file_name, object_path, file_url,
    size_bytes, is_required, published_by, published_by_name
  ) values (
    v_platform, v_version, v_notes, p_file_name, p_object_path, p_file_url,
    p_size_bytes, coalesce(p_is_required, false), p_published_by, p_published_by_name
  )
  returning id into v_release_id;

  insert into public.app_installers (
    platform, version, release_notes, file_name, object_path, file_url,
    size_bytes, is_required, published_at, published_by, published_by_name
  ) values (
    v_platform, v_version, v_notes, p_file_name, p_object_path, p_file_url,
    p_size_bytes, coalesce(p_is_required, false), now(), p_published_by, p_published_by_name
  )
  on conflict (platform) do update set
    version           = excluded.version,
    release_notes     = excluded.release_notes,
    file_name         = excluded.file_name,
    object_path       = excluded.object_path,
    file_url          = excluded.file_url,
    size_bytes        = excluded.size_bytes,
    is_required       = excluded.is_required,
    published_at      = excluded.published_at,
    published_by      = excluded.published_by,
    published_by_name = excluded.published_by_name;

  insert into public.app_update_notifications (
    release_id, employee_id, platform, version, release_notes
  )
  select v_release_id, e.id, v_platform, v_version, v_notes
    from public.employees e
   where e.is_fired = false
  on conflict (release_id, employee_id) do nothing;

  get diagnostics v_notified = row_count;

  update public.app_installer_releases
     set notified_count = v_notified
   where id = v_release_id;

  v_os_label := case v_platform
                  when 'windows' then 'Windows'
                  when 'android' then 'Android'
                  when 'macos'   then 'macOS'
                  when 'linux'   then 'Linux'
                  else 'iOS'
                end;

  v_chat_body :=
    'Обновление приложения — ' || v_os_label || ', версия ' || v_version ||
    case when coalesce(p_is_required, false) then ' (обязательное)' else '' end ||
    E'\n\nЧто изменилось:\n' || v_notes ||
    E'\n\nСкачать: ' || p_file_url ||
    E'\n\nПрежняя версия удалена — доступна только эта.';

  begin
    insert into public.chat_messages (room_id, sender_id, sender_name, kind, body)
    values (
      coalesce(nullif(btrim(p_chat_room_id), ''), 'general'),
      p_chat_sender_id,
      coalesce(nullif(btrim(p_published_by_name), ''), 'Обновление приложения'),
      'text',
      v_chat_body
    );
  exception when others then
    raise warning 'publish_app_installer: сообщение в чат не отправлено: %', sqlerrm;
  end;

  return jsonb_build_object(
    'release_id',           v_release_id,
    'platform',             v_platform,
    'version',              v_version,
    'notified_count',       v_notified,
    'previous_object_path', v_previous.object_path
  );
end;
$function$
;

-- publish_product_type_config(uuid)
-- md5: e6091cd2cf1a21c26355b805d100d137
CREATE OR REPLACE FUNCTION public.publish_product_type_config(p_config_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_product_type_id uuid;
  v_status          text;
  v_version         integer;
  v_problem         record;
  v_problems        text := '';
  v_count           integer := 0;
begin
  if p_config_id is null then
    raise exception
      'Не удалось опубликовать настройки: не указана версия.'
      using errcode = '22023';
  end if;

  select product_type_id, status, version
    into v_product_type_id, v_status, v_version
    from product_type_configs
   where id = p_config_id
   for update;

  if not found then
    raise exception
      'Не удалось опубликовать настройки: версия не найдена. Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_status <> 'draft' then
    raise exception
      'Не удалось опубликовать настройки: версия % уже имеет статус «%», '
      'публиковать можно только черновик. Обновите экран.',
      v_version, v_status
      using errcode = '22023';
  end if;

  for v_problem in
    select message from validate_product_type_config(p_config_id) limit 3
  loop
    v_count := v_count + 1;
    v_problems := v_problems || ' ' || v_problem.message;
  end loop;

  if v_count > 0 then
    raise exception
      'Не удалось опубликовать настройки: маршрут собран неверно.%',
      v_problems
      using errcode = '23514';
  end if;

  update product_type_configs
     set status = 'archived'
   where product_type_id = v_product_type_id
     and status = 'published';

  if exists (
    select 1
      from product_type_configs
     where product_type_id = v_product_type_id
       and status = 'published'
       and id <> p_config_id
  ) then
    raise exception
      'Не удалось опубликовать настройки: параллельно опубликована другая '
      'версия. Обновите экран и повторите.'
      using errcode = '40001';
  end if;

  update product_type_configs
     set status       = 'published',
         published_at = now()
   where id = p_config_id;

  return p_config_id;
end;
$function$
;

-- realtime_sync_published_tables()
-- md5: 7ee36c8cdd30997cd34aa7fd57748169
CREATE OR REPLACE FUNCTION public.realtime_sync_published_tables()
 RETURNS TABLE(schema_name text, table_name text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select schemaname::text, tablename::text
  from pg_catalog.pg_publication_tables
  where pubname = 'supabase_realtime'
    and schemaname in ('public', 'production')
$function$
;

-- recalculate_paint_reserved_qty(text[])
-- md5: 13089b86659b7496807fbe3651b0701e
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

-- recalculate_paint_reserved_qty(uuid[])
-- md5: c36913bebd6b35759ef2067579f3b00b
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

-- recompute_order_actual_qty(text,text)
-- md5: 208a8b1da902f72d93ae82c7efe2b706
CREATE OR REPLACE FUNCTION public.recompute_order_actual_qty(p_order_id text, p_completed_stage_id text DEFAULT NULL::text)
 RETURNS double precision
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_qty double precision := public.order_actual_qty_compute(p_order_id, p_completed_stage_id);
begin
  if v_qty is null then return null; end if;

  perform set_config('app.actual_qty_writer', 'server', true);
  update orders
     set actual_qty = v_qty::numeric
   where id::text = p_order_id
     and actual_qty is distinct from v_qty::numeric;
  perform set_config('app.actual_qty_writer', '', true);

  return v_qty;
end
$function$
;

-- recompute_task_quantity_shares(text)
-- md5: f42b0e9d80c7ce468497f73079ff1ffe
CREATE OR REPLACE FUNCTION public.recompute_task_quantity_shares(p_task_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_task tasks%rowtype;
  v_comments jsonb;
  v_kept jsonb := '[]'::jsonb;
  v_split boolean;
  v_workplace text;
  v_unit text := '';
  v_report jsonb := '[]'::jsonb;
  v_row record;
  v_offset int := 0;
  v_display text;
begin
  if coalesce(trim(p_task_id), '') = '' then
    raise exception using message = 'task_id is required', errcode = '22023';
  end if;

  -- Комментарии лежат ОДНИМ jsonb в строке задачи, и на идущем этапе туда
  -- каждую минуту падают time_event. Без блокировки цикл «прочитать всё →
  -- заменить → записать всё» затирал бы записи, сделанные между чтением и
  -- записью (та же причина, что в update_task_quantity_comment).
  select * into v_task from public.tasks where id::text = p_task_id for update;
  if not found then
    raise exception 'Задача % не найдена.', p_task_id;
  end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  v_workplace := coalesce(
    nullif(trim(coalesce(v_task.captured_by_workplace_id::text, '')), ''),
    v_task.stage_id::text
  );
  select w.split_quantity_by_time, coalesce(w.unit, '')
    into v_split, v_unit
    from public.workplaces w
   where w.id::text = v_workplace;
  v_split := coalesce(v_split, true);
  v_unit := coalesce(v_unit, '');

  -- Идемпотентность: выбрасываем ТОЛЬКО свои прежние записи. Доли, введённые
  -- руками, и правки техлида (update_task_quantity_comment) не помечены
  -- generated и переживают пересчёт.
  select coalesce(jsonb_agg(t.c order by t.ord), '[]'::jsonb)
    into v_kept
    from jsonb_array_elements(v_comments) with ordinality as t(c, ord)
   where not (
     t.c->>'type' = 'quantity_share'
     and coalesce(
           public.task_quantity_payload(t.c->>'text')->>'generated', '') = 'true'
   );

  -- Отчёт — по участнику целиком (не по сегментам): его читает человек.
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', r.employee_id,
           'role', r.role,
           'seconds', r.seconds,
           'raw_share', r.raw_share,
           'final_share', r.final_share
         ) order by r.employee_id), '[]'::jsonb)
    into v_report
    from (
      select b.employee_id,
             min(b.role) as role,
             sum(b.seconds) as seconds,
             sum(b.raw_share) as raw_share,
             case when v_split then ceil(sum(b.raw_share))
                  else sum(b.raw_share) end as final_share
        from public.task_quantity_share_preview(p_task_id) b
       group by b.employee_id
    ) r;

  for v_row in
    with base as (
      select * from public.task_quantity_share_preview(p_task_id)
    ),
    totals as (
      select b.employee_id,
             sum(b.raw_share) as raw_total,
             max(b.segment_end) as last_segment
        from base b
       group by b.employee_id
    ),
    finals as (
      select t.employee_id,
             t.raw_total,
             t.last_segment,
             case when v_split then ceil(t.raw_total) else t.raw_total end
               as final_total
        from totals t
    )
    select b.employee_id,
           b.role,
           b.segment_end,
           b.seconds,
           b.raw_share,
           -- Добавка от единственного округления оседает в последней записи
           -- сотрудника: сумма его записей равна итоговой доле.
           b.raw_share + case
             when b.segment_end = f.last_segment then f.final_total - f.raw_total
             else 0
           end as share
      from base b
      join finals f on f.employee_id = b.employee_id
     order by b.segment_end, b.employee_id
  loop
    if v_row.share <= 0 then
      continue;
    end if;

    -- Целое показываем без хвоста «.00»: подпись уходит в ленту задачи и в
    -- таблицы аналитики, где «5000» читается, а «5000.00» — нет.
    v_display := case
                   when v_row.share = trunc(v_row.share)
                     then trunc(v_row.share)::bigint::text
                   else trim(to_char(v_row.share, 'FM999999999990.99'))
                 end
                 || case when v_unit <> '' then ' ' || v_unit else '' end;

    v_kept := v_kept || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_share',
      'userId', v_row.employee_id,
      'timestamp',
        floor(extract(epoch from v_row.segment_end) * 1000)::bigint + v_offset,
      'text', jsonb_build_object(
        'actual', v_row.share,
        'unit', v_unit,
        'display', v_display,
        'generated', true,
        'role', v_row.role,
        'seconds', v_row.seconds,
        'raw_share', v_row.raw_share
      )::text
    ));
    v_offset := v_offset + 1;
  end loop;

  -- Клиент читает комментарии в порядке timestamp — сортируем, как это
  -- делают остальные пишущие функции.
  select coalesce(
           jsonb_agg(c order by public.task_comment_millis(c->>'timestamp')),
           '[]'::jsonb)
    into v_comments
    from jsonb_array_elements(v_kept) c;

  update public.tasks
     set comments = v_comments
   where id::text = p_task_id;

  return jsonb_build_object(
    'task_id', p_task_id,
    'workplace_id', v_workplace,
    'split_by_time', v_split,
    'participants', v_report
  );
end
$function$
;

-- record_order_paper_usage(text,text,jsonb,text,uuid,text,text)
-- md5: a2a400f7f723e792374ae4d04e328ea5
CREATE OR REPLACE FUNCTION public.record_order_paper_usage(p_order_id text, p_task_id text, p_rows jsonb, p_kind text DEFAULT 'finish'::text, p_request_id uuid DEFAULT NULL::uuid, p_actor text DEFAULT NULL::text, p_employee_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order public.orders%rowtype; v_task record; v_stage_key text; v_label text; v_employee text;
  v_paper record; v_reserved_other numeric; v_available numeric; rec record;
begin
  if coalesce(p_kind, '') not in ('shift', 'participant', 'finish') then
    raise exception 'Неизвестный вид записи расхода бумаги: %', p_kind;
  end if;
  -- Блокировка заказа: две смены одновременно иначе прошли бы проверку остатка по одним метрам.
  select * into v_order from public.orders where id::text = p_order_id for update;
  if not found then raise exception 'Заказ % не найден.', p_order_id; end if;
  if p_request_id is not null and exists (select 1 from public.papers_writeoffs w where w.request_id = p_request_id) then
    return jsonb_build_object('duplicate', true, 'state', public.order_paper_usage_state(p_order_id));
  end if;
  select t.id, t.order_id, t.stage_id, t.stage_group_key into v_task from public.tasks t where t.id::text = p_task_id;
  if not found or v_task.order_id::text <> v_order.id::text then raise exception 'Задача этапа не найдена в заказе.'; end if;
  v_stage_key := public.order_paper_writeoff_stage_key(p_order_id);
  if v_stage_key is null or (v_stage_key <> coalesce(nullif(v_task.stage_group_key, ''), v_task.stage_id) and v_stage_key <> v_task.stage_id) then
    raise exception using errcode = 'check_violation', message = 'Расход бумаги записывается только на первом рулонном этапе заказа.';
  end if;
  v_label := coalesce(nullif(btrim(v_order.customer), ''), v_order.assignment_id, p_order_id);
  select e.id into v_employee from public.employees e where e.id = nullif(trim(p_employee_id), '');
  for rec in
    select nullif(trim(value->>'paper_id'), '') as paper_id, sum(coalesce(public.task_quantity_value(value->>'qty'), 0))::numeric as qty
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) group by 1 order by 1
  loop
    if rec.paper_id is null then continue; end if;
    if rec.qty < 0 then raise exception using errcode = 'check_violation', message = 'Расход бумаги не может быть отрицательным.'; end if;
    if rec.qty = 0 then continue; end if;
    select p.id, p.description, p.format, p.grammage, p.quantity into v_paper from public.papers p where p.id::text = rec.paper_id for update;
    if not found then raise exception 'Бумага % не найдена на складе.', rec.paper_id; end if;
    select coalesce(sum(r.qty), 0) into v_reserved_other from public.order_paper_reservations r where r.paper_id = v_paper.id and r.order_id <> v_order.id;
    v_available := coalesce(v_paper.quantity, 0) - v_reserved_other;
    if rec.qty > v_available then
      raise exception using errcode = 'check_violation',
        message = format('Не хватает бумаги «%s»: для заказа на складе %s м, а записан расход %s м. '
          'Сохранить нельзя, пока склад не пополнят (приход или инвентаризация).',
          concat_ws(' ', v_paper.description, nullif(concat_ws('/', v_paper.format, v_paper.grammage), '')),
          round(greatest(v_available, 0), 2), round(rec.qty, 2));
    end if;
    insert into public.papers_writeoffs(paper_id, qty, reason, by_name, order_id, source, employee_id, task_id, request_id)
    values (v_paper.id, rec.qty, format('Расход бумаги на этапе по заказу %s', v_label), coalesce(nullif(trim(p_actor), ''), 'system'),
            v_order.id, 'paper_stage', v_employee, p_task_id, p_request_id);
    update public.order_paper_reservations set qty = qty - rec.qty, updated_at = now() where order_id = v_order.id and paper_id = v_paper.id;
    delete from public.order_paper_reservations where order_id = v_order.id and paper_id = v_paper.id and qty <= 0.0001;
  end loop;
  return jsonb_build_object('duplicate', false, 'state', public.order_paper_usage_state(p_order_id));
end;
$function$
;

-- release_order_edit(uuid,uuid)
-- md5: f03db3f220cbbb14cafac9a2e08223b2
CREATE OR REPLACE FUNCTION public.release_order_edit(p_order_id uuid, p_token uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select order_edit_private.release(p_order_id, p_token);
$function$
;

-- release_order_paint_reservations(text,text,text)
-- md5: 4573df07735d30a5635e366c3e7ca41c
CREATE OR REPLACE FUNCTION public.release_order_paint_reservations(p_order_id text, p_reason text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_touched public.paints.id%type[];
  v_force   boolean;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  -- Удаление заказа снимает всё: см. шапку миграции.
  v_force := coalesce(trim(p_reason), '') = 'order_deleted';

  -- Пересчитать нужно только те краски, чьи строки реально уйдут.
  select array_agg(distinct r.paint_id) into v_touched
    from order_paint_reservations r
   where r.order_id::text = p_order_id
     and r.paint_id is not null
     and (
       v_force
       or not public.paint_reservation_has_pending_debt(
            p_order_id, r.paint_id, r.paint_name)
     );

  delete from order_paint_reservations r
   where r.order_id::text = p_order_id
     and (
       v_force
       or not public.paint_reservation_has_pending_debt(
            p_order_id, r.paint_id, r.paint_name)
     );

  perform recalculate_paint_reserved_qty(v_touched);
end;
$function$
;

-- release_order_paper_reservations(text,text,text)
-- md5: 6ac28d94bacb72264cc225e8435668bc
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

-- release_reserve_when_debt_gone()
-- md5: 3912ed4aed18a9cee69f1abc2f54394e
CREATE OR REPLACE FUNCTION public.release_reserve_when_debt_gone()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order_id text;
  v_status   text;
begin
  v_order_id := coalesce(old.order_id::text, new.order_id::text);
  if coalesce(trim(v_order_id), '') = '' then
    return null;
  end if;

  -- Долг ещё висит — ничего не трогаем.
  if exists (
    select 1 from order_paint_pending_writeoffs w
     where w.order_id::text = v_order_id and w.status = 'pending'
  ) then
    return null;
  end if;

  select o.status into v_status from orders o where o.id::text = v_order_id;
  if v_status is distinct from 'completed' then
    return null;
  end if;

  perform public.release_order_paint_reservations(
    v_order_id, 'pending_debt_closed', 'system');
  return null;
end;
$function$
;

-- renew_order_edit(uuid,uuid)
-- md5: 8e2b1326a60e61cf54082ceb9afb87c7
CREATE OR REPLACE FUNCTION public.renew_order_edit(p_order_id uuid, p_token uuid)
 RETURNS boolean
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select order_edit_private.renew(p_order_id, p_token);
$function$
;

-- replace_plan_stages(uuid,jsonb)
-- md5: d9156e3280d7351cd057d7501d2f9e2a
CREATE OR REPLACE FUNCTION public.replace_plan_stages(p_plan_id uuid, p_stages jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_item        jsonb;
  v_idx         integer := 0;
  v_stage_id    text;
  v_group_key   text;
  v_name        text;
  v_step_no     integer;
  v_next_seq    integer := 0;
  v_park_base   integer;
  v_used_seq    integer[] := '{}';
  v_deleted     integer := 0;
  v_inserted    integer := 0;
  v_updated     integer := 0;
  v_protected   jsonb := '[]'::jsonb;
  v_row         record;
begin
  if p_plan_id is null then
    raise exception 'Не удалось сохранить очередь: не указан план заказа.'
      using errcode = '22023';
  end if;

  if p_stages is null or jsonb_typeof(p_stages) <> 'array' then
    raise exception 'Не удалось сохранить очередь: список этапов повреждён.'
      using errcode = '22023';
  end if;

  if jsonb_array_length(p_stages) = 0 then
    raise exception
      'Не удалось сохранить очередь: список этапов пуст. Соберите очередь заново.'
      using errcode = '22023';
  end if;

  if not exists (select 1 from prod_plans where id = p_plan_id) then
    raise exception
      'Не удалось сохранить очередь: план заказа не найден. Обновите список заказов.'
      using errcode = '23503';
  end if;

  drop table if exists _incoming;
  create temporary table _incoming (
    ord        integer primary key,
    stage_id   text    not null,
    group_key  text    not null,
    name       text    not null,
    step_no    integer not null,
    match_id   uuid,
    assigned   integer
  ) on commit drop;

  for v_item in select value from jsonb_array_elements(p_stages) loop
    v_idx := v_idx + 1;

    v_stage_id := nullif(btrim(coalesce(v_item->>'stage_id', '')), '');
    if v_stage_id is null then
      raise exception
        'Не удалось сохранить очередь: у этапа № % не указано рабочее место.', v_idx
        using errcode = '22023';
    end if;

    v_group_key := coalesce(
      nullif(btrim(coalesce(v_item->>'stage_group_key', '')), ''),
      v_stage_id
    );

    v_name := coalesce(nullif(btrim(coalesce(v_item->>'name', '')), ''), v_stage_id);

    begin
      v_step_no := coalesce((v_item->>'step_no')::integer, v_idx);
    exception when others then
      raise exception
        'Не удалось сохранить очередь: у этапа «%» неверный номер шага (%).',
        v_name, v_item->>'step_no' using errcode = '22023';
    end;

    if v_step_no <= 0 then
      raise exception
        'Не удалось сохранить очередь: у этапа «%» номер шага должен быть больше нуля.',
        v_name using errcode = '22023';
    end if;

    insert into _incoming(ord, stage_id, group_key, name, step_no)
    values (v_idx, v_stage_id, v_group_key, v_name, v_step_no);
  end loop;

  if exists (
    select 1 from _incoming group by group_key, stage_id having count(*) > 1
  ) then
    raise exception
      'Не удалось сохранить очередь: одно и то же рабочее место указано дважды на одном шаге.'
      using errcode = '22023';
  end if;

  perform 1
    from prod_plan_stages
   where plan_id = p_plan_id
   for update;

  update _incoming inc
     set match_id = s.id
    from prod_plan_stages s
   where s.plan_id = p_plan_id
     and coalesce(nullif(btrim(coalesce(s.stage_group_key, '')), ''), s.stage_id)
         = inc.group_key
     and s.stage_id = inc.stage_id;

  for v_row in
    select s.stage_id, s.stage_group_key, s.name, s.seq, s.step_no,
           s.status::text as status,
           inc.step_no as requested_step_no,
           (inc.ord is null) as removed
      from prod_plan_stages s
      left join _incoming inc on inc.match_id = s.id
     where s.plan_id = p_plan_id
       and s.status <> 'waiting'
     order by s.step_no nulls last, s.seq
  loop
    if v_row.removed then
      v_protected := v_protected || jsonb_build_array(jsonb_build_object(
        'stage_id', v_row.stage_id,
        'stage_group_key', v_row.stage_group_key,
        'name', v_row.name,
        'seq', v_row.seq,
        'step_no', v_row.step_no,
        'status', v_row.status,
        'requested_step_no', null,
        'reason', 'removed'
      ));
    elsif v_row.requested_step_no is distinct from v_row.step_no then
      v_protected := v_protected || jsonb_build_array(jsonb_build_object(
        'stage_id', v_row.stage_id,
        'stage_group_key', v_row.stage_group_key,
        'name', v_row.name,
        'seq', v_row.seq,
        'step_no', v_row.step_no,
        'status', v_row.status,
        'requested_step_no', v_row.requested_step_no,
        'reason', 'moved'
      ));
    end if;
  end loop;

  with removed as (
    delete from prod_plan_stages s
     where s.plan_id = p_plan_id
       and s.status = 'waiting'
       and not exists (select 1 from _incoming inc where inc.match_id = s.id)
    returning 1
  )
  select count(*) into v_deleted from removed;

  select least(coalesce(min(seq), 0), 0) - 1
    into v_park_base
    from prod_plan_stages
   where plan_id = p_plan_id;

  with parked as (
    select s.id, row_number() over (order by s.seq) as rn
      from prod_plan_stages s
     where s.plan_id = p_plan_id
       and s.status = 'waiting'
  )
  update prod_plan_stages s
     set seq = v_park_base - parked.rn + 1
    from parked
   where s.id = parked.id;

  select coalesce(array_agg(s.seq), '{}')
    into v_used_seq
    from prod_plan_stages s
   where s.plan_id = p_plan_id
     and s.status <> 'waiting';

  for v_row in
    select inc.*
      from _incoming inc
      left join prod_plan_stages s
        on s.id = inc.match_id and s.status <> 'waiting'
     where s.id is null
     order by inc.ord
  loop
    loop
      v_next_seq := v_next_seq + 1;
      exit when not (v_next_seq = any (v_used_seq));
    end loop;

    update _incoming set assigned = v_next_seq where ord = v_row.ord;
  end loop;

  for v_row in select * from _incoming where assigned is not null order by ord loop
    if v_row.match_id is not null then
      update prod_plan_stages
         set seq             = v_row.assigned,
             step_no         = v_row.step_no,
             name            = v_row.name,
             stage_group_key = v_row.group_key,
             updated_at      = now()
       where id = v_row.match_id;
      v_updated := v_updated + 1;
    else
      insert into prod_plan_stages(
        plan_id, stage_id, stage_group_key, name, seq, step_no, status
      )
      values (
        p_plan_id, v_row.stage_id, v_row.group_key, v_row.name,
        v_row.assigned, v_row.step_no, 'waiting'
      );
      v_inserted := v_inserted + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'plan_id',   p_plan_id,
    'deleted',   v_deleted,
    'inserted',  v_inserted,
    'updated',   v_updated,
    'protected', v_protected
  );
end;
$function$
;

-- resolve_order_form(uuid,text,text,integer)
-- md5: f78de2d258d0532a85c0ab97d07e4e5e
CREATE OR REPLACE FUNCTION public.resolve_order_form(p_form_id uuid DEFAULT NULL::uuid, p_form_code text DEFAULT NULL::text, p_form_series text DEFAULT NULL::text, p_form_no integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select case when count(*) = 1 then (array_agg(f.id))[1] end
  from public.forms f
  where (p_form_id is not null and f.id = p_form_id)
     or (p_form_id is null and (
       (nullif(btrim(p_form_code), '') is not null
         and (f.code = btrim(p_form_code)
           or concat(f.series, ' ', f.number) = btrim(p_form_code)))
       or (nullif(btrim(p_form_series), '') is not null
         and f.series = btrim(p_form_series) and f.number = p_form_no)
     ));
$function$
;

-- safe_paint_id(text)
-- md5: 6167f2fd266f96ceca716c9ec2a772e0
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

-- save_order_paints(text,jsonb)
-- md5: 6264b0d92c22bc9bb5a049d86b6c47d6
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

-- set_created_by_default()
-- md5: 34e025ae8b460c249ef405048baa3819
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

-- set_created_by_default_files()
-- md5: 16c2454d8ea812592f96b602e0050195
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

-- set_product_type_stage_condition(uuid,text,text)
-- md5: 1cb5d89a4978fe887ac24f8a7a0f0595
CREATE OR REPLACE FUNCTION public.set_product_type_stage_condition(p_stage_id uuid, p_predicate text, p_param text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_title      text;
  v_param_kind text;
begin
  if p_stage_id is null then
    raise exception
      'Не удалось сохранить условие: не указан этап.'
      using errcode = '22023';
  end if;

  select title into v_title
    from product_type_stages
   where id = p_stage_id
   for update;

  if not found then
    raise exception
      'Не удалось сохранить условие: этап не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  -- «Всегда» — это отсутствие строк условий, а не отдельный предикат. Тот же
  -- принцип, что у product_type_form_blocks: таблицы хранят отклонения.
  if p_predicate is null then
    delete from product_type_stage_conditions where stage_id = p_stage_id;
    return;
  end if;

  select param_kind into v_param_kind
    from order_predicates
   where code = p_predicate;

  if not found then
    raise exception
      'Не удалось сохранить условие: неизвестное условие «%».', p_predicate
      using errcode = '23503';
  end if;

  if v_param_kind is null and p_param is not null then
    raise exception
      'Не удалось сохранить условие этапа «%»: условие «%» не принимает '
      'значения.', v_title, p_predicate
      using errcode = '22023';
  end if;

  if v_param_kind = 'handle_type'
     and coalesce(p_param, '') not in ('flat', 'twisted', 'dieCut') then
    raise exception
      'Не удалось сохранить условие этапа «%»: недопустимый тип ручки «%».',
      v_title, coalesce(p_param, '—')
      using errcode = '22023';
  end if;

  delete from product_type_stage_conditions where stage_id = p_stage_id;

  insert into product_type_stage_conditions(stage_id, predicate, param_text)
  values (p_stage_id, p_predicate, p_param);
end;
$function$
;

-- set_product_type_stage_default_variant(uuid)
-- md5: 6b1c48d8ff439acb9ad89945b52cef40
CREATE OR REPLACE FUNCTION public.set_product_type_stage_default_variant(p_variant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stage_id uuid;
  v_mode     text;
begin
  if p_variant_id is null then
    raise exception
      'Не удалось назначить вариант по умолчанию: не указан вариант.'
      using errcode = '22023';
  end if;

  select w.stage_id, s.selection_mode into v_stage_id, v_mode
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_variant_id;

  if not found then
    raise exception
      'Не удалось назначить вариант по умолчанию: вариант не найден. '
      'Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_mode <> 'one_of' then
    raise exception
      'Не удалось назначить вариант по умолчанию: этап не переключаемый.'
      using errcode = '22023';
  end if;

  perform 1 from product_type_stage_workplaces
   where stage_id = v_stage_id
   for update;

  update product_type_stage_workplaces
     set is_default = false
   where stage_id = v_stage_id
     and is_default
     and id <> p_variant_id;

  update product_type_stage_workplaces
     set is_default = true
   where id = p_variant_id
     and not is_default;
end;
$function$
;

-- set_product_type_stage_positions(uuid,jsonb)
-- md5: 1041e514107bdedfcc6c98863426b9e4
CREATE OR REPLACE FUNCTION public.set_product_type_stage_positions(p_config_id uuid, p_ordered_groups jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_ids      uuid[];
  v_ranks    integer[];
  v_listed   integer;
  v_expected integer;
  v_updated  integer := 0;
  v_sub      text;
  v_switch   text;
begin
  if p_config_id is null then
    raise exception
      'Не удалось сохранить порядок этапов: не указана версия настроек.'
      using errcode = '22023';
  end if;

  if p_ordered_groups is null or jsonb_typeof(p_ordered_groups) <> 'array' then
    raise exception
      'Не удалось сохранить порядок этапов: список этапов повреждён.'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_ordered_groups) as g(items)
     where jsonb_typeof(g.items) <> 'array' or jsonb_array_length(g.items) = 0
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: список групп повреждён.'
      using errcode = '22023';
  end if;

  -- Фиксируем строки версии до COMMIT.
  perform 1 from product_type_stages
   where config_id = p_config_id
   for update;

  -- Разбор один раз. Одинаковый ORDER BY в обоих array_agg держит массивы
  -- выровненными: v_ids[i] лежит на ранге v_ranks[i]. Массивы, а не временная
  -- таблица: имя переменной plpgsql не зависит от search_path, в отличие от
  -- неквалифицированной временной таблицы, которую при search_path
  -- 'public','pg_temp' перехватила бы одноимённая таблица в public.
  begin
    select array_agg((m.value #>> '{}')::uuid order by g.ord, m.ord),
           array_agg(g.ord::integer order by g.ord, m.ord)
      into v_ids, v_ranks
      from jsonb_array_elements(p_ordered_groups)
             with ordinality as g(items, ord)
      cross join lateral jsonb_array_elements(g.items)
             with ordinality as m(value, ord);
  exception when invalid_text_representation then
    raise exception
      'Не удалось сохранить порядок этапов: в списке не идентификатор этапа.'
      using errcode = '22023';
  end;

  if exists (
    select 1 from unnest(v_ids) as t(id) group by t.id having count(*) > 1
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: этап указан в списке дважды.'
      using errcode = '22023';
  end if;

  v_listed := coalesce(array_length(v_ids, 1), 0);
  select count(*) into v_expected
    from product_type_stages
   where config_id = p_config_id
     and not is_pinned_last;

  if v_listed <> v_expected or exists (
    select 1
      from unnest(v_ids) as t(id)
      left join product_type_stages s
        on s.id = t.id
       and s.config_id = p_config_id
       and not s.is_pinned_last
     where s.id is null
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: список не совпадает с маршрутом. '
      'Обновите экран и повторите.'
      using errcode = '22023';
  end if;

  -- Группа однородна по уровню.
  if exists (
    select 1
      from unnest(v_ids, v_ranks) as r(stage_id, rank)
      join product_type_stages s on s.id = r.stage_id
     group by r.rank
    having count(distinct s.level) > 1
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: на одном шаге оказались общий '
      'этап и под-этап варианта. Они не взаимоисключающие, порядок между '
      'ними не определён.'
      using errcode = '22023';
  end if;

  -- Группа уровня 1 — разные варианты ОДНОГО переключателя.
  if exists (
    select 1
      from unnest(v_ids, v_ranks) as r(stage_id, rank)
      join product_type_stages s on s.id = r.stage_id and s.level = 1
      join product_type_stage_workplaces w on w.id = s.parent_variant_id
     group by r.rank
    having count(distinct w.stage_id) > 1
        or count(distinct w.id) <> count(*)
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: на одном шаге оказались под-этапы '
      'одного варианта или разных переключателей — вместе они появятся оба.'
      using errcode = '22023';
  end if;

  -- Под-этап строго позже своего переключателя. Одна проверка закрывает и
  -- подъём под-этапа, и опускание переключателя.
  select s.title, p.title
    into v_sub, v_switch
    from unnest(v_ids, v_ranks) as r(stage_id, rank)
    join product_type_stages s on s.id = r.stage_id and s.level = 1
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages p on p.id = w.stage_id
    left join unnest(v_ids, v_ranks) as pr(stage_id, rank)
           on pr.stage_id = p.id
   where pr.stage_id is null or r.rank <= pr.rank
   limit 1;

  if v_sub is not null then
    raise exception
      'Не удалось сохранить порядок этапов: под-этап «%» должен идти после '
      'переключателя «%», иначе вариант ещё не выбран.', v_sub, v_switch
      using errcode = '22023';
  end if;

  update product_type_stages s
     set position = r.rank
    from unnest(v_ids, v_ranks) as r(stage_id, rank)
   where s.id = r.stage_id
     and s.position is distinct from r.rank;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$
;

-- set_product_type_stage_selection_mode(uuid,text)
-- md5: 65e5ae46e1047d9e83094de012f78474
CREATE OR REPLACE FUNCTION public.set_product_type_stage_selection_mode(p_stage_id uuid, p_mode text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_current   text;
  v_title     text;
  v_workplace integer;
  v_deleted   integer := 0;
begin
  if p_stage_id is null then
    raise exception
      'Не удалось сменить режим этапа: не указан этап.'
      using errcode = '22023';
  end if;

  if p_mode is null or p_mode not in ('all', 'one_of') then
    raise exception
      'Не удалось сменить режим этапа: недопустимый режим «%».', p_mode
      using errcode = '22023';
  end if;

  -- Фиксируем этап и его рабочие места до COMMIT.
  select selection_mode, title into v_current, v_title
    from product_type_stages
   where id = p_stage_id
   for update;

  if not found then
    raise exception
      'Не удалось сменить режим этапа: этап не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  perform 1 from product_type_stage_workplaces
   where stage_id = p_stage_id
   for update;

  if v_current = p_mode then
    return 0;
  end if;

  if p_mode = 'one_of' then
    select count(*) into v_workplace
      from product_type_stage_workplaces
     where stage_id = p_stage_id;

    if v_workplace < 2 then
      raise exception
        'Не удалось сделать этап «%» переключаемым: нужно не меньше двух '
        'рабочих мест, сейчас %.', v_title, v_workplace
        using errcode = '22023';
    end if;

    -- Подпись варианта — имя рабочего места из справочника.
    update product_type_stage_workplaces w
       set variant_title = coalesce(
             nullif(btrim(coalesce(w.variant_title, '')), ''),
             (select name from workplaces where id = w.workplace_id))
     where w.stage_id = p_stage_id;

    -- Ровно один вариант по умолчанию: первый по sort_order.
    update product_type_stage_workplaces
       set is_default = false
     where stage_id = p_stage_id
       and is_default;

    update product_type_stage_workplaces
       set is_default = true
     where id = (
       select id from product_type_stage_workplaces
        where stage_id = p_stage_id
        order by sort_order, workplace_id
        limit 1);

  else
    -- Под-этапы вариантов теряют смысл вместе с вариантами. Их рабочие места
    -- и условия уходят каскадом по stage_id.
    with removed as (
      delete from product_type_stages s
       where s.parent_variant_id in (
         select id from product_type_stage_workplaces
          where stage_id = p_stage_id)
      returning 1
    )
    select count(*) into v_deleted from removed;
  end if;

  update product_type_stages
     set selection_mode = p_mode
   where id = p_stage_id;

  return v_deleted;
end;
$function$
;

-- set_updated_at()
-- md5: f4c6e59ca6769be7cfb69b6ac7c029e9
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at := now();
  return new;
end; $function$
;

-- stage_is_packaging(text,text,text)
-- md5: 176bdddfabc88f101514f322b2e085b6
CREATE OR REPLACE FUNCTION public.stage_is_packaging(p_stage_id text, p_stage_name text, p_group_key text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  with n as (
    select regexp_replace(replace(lower(trim(coalesce(p_stage_name, ''))), '-', '_'), '\s+', '_', 'g') as name_key,
           regexp_replace(replace(lower(trim(coalesce(p_group_key, ''))), '-', '_'), '\s+', '_', 'g') as group_key
  )
  select trim(coalesce(p_stage_id, '')) = 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1'  -- wpPackagingUuid
      or (n.name_key <> '' and (n.name_key in ('упаковка', 'packaging', 'package')
                                or n.name_key like '%упаков%' or n.name_key like '%packaging%'))
      or n.group_key in ('pack', 'packing', 'packaging', 'package', 'packaging_stage', 'package_stage',
                         'packaging_group', 'package_group', 'pack_stage', 'упаковка')
      or n.group_key like '%упаков%'
    from n;
$function$
;

-- stamp_server_shipped_at()
-- md5: d904804466104726d6593b16388d446a
CREATE OR REPLACE FUNCTION public.stamp_server_shipped_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Момент отгрузки ставит сервер: часы устройств уходят (складской ПК 15.09
  -- отставал на 58 минут, и отгрузки попадали в архив на час раньше).
  -- Обход для переноса данных: set local app.trust_client_shipped_at = 'on';
  if coalesce(current_setting('app.trust_client_shipped_at', true), '') = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.shipped_at is not null then
      new.shipped_at := now();
    end if;
    return new;
  end if;

  -- Отметку сняли (возобновление заказа) — так и оставляем.
  if new.shipped_at is not null and new.shipped_at is distinct from old.shipped_at then
    new.shipped_at := now();
  end if;
  return new;
end
$function$
;

-- stationery_apply_inventory()
-- md5: 8b84f0fcceb47e80f2258b44fecfed68
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

-- stationery_apply_writeoff()
-- md5: 14f1c40cf63cab0225eb96b69ecd59ff
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

-- stock_cancel_movement(text,text,uuid,text)
-- md5: c5d69c931c7665b89c16125e21a5469d
CREATE OR REPLACE FUNCTION public.stock_cancel_movement(p_type text, p_movement text, p_id uuid, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c_marker constant text := '[ОТМЕНЕНО]';
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_item uuid;
  v_qty numeric;
  v_source text;
  v_kind text;
  v_prev_qty numeric;
  v_canceled timestamptz;
  v_created timestamptz;
  v_text text;
  v_stock numeric;
  v_new_stock numeric;
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_movement not in ('writeoff', 'arrival', 'inventory') then
    raise exception using message = format('Неизвестное движение: %s', p_movement), errcode = '22023';
  end if;

  if p_type = 'paper' and p_movement = 'writeoff' then
    select paper_id, qty, source, canceled_at, created_at, reason
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from papers_writeoffs where id = p_id for update;
  elsif p_type = 'paint' and p_movement = 'writeoff' then
    select paint_id, qty, source, canceled_at, created_at, reason
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from paints_writeoffs where id = p_id for update;
  elsif p_type = 'paper' and p_movement = 'arrival' then
    select paper_id, qty, source, canceled_at, created_at, note
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from papers_arrivals where id = p_id for update;
  elsif p_type = 'paint' and p_movement = 'arrival' then
    select paint_id, qty, source, canceled_at, created_at, note
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from paints_arrivals where id = p_id for update;
  elsif p_type = 'paper' then
    select paper_id, counted_qty, kind, previous_qty, canceled_at, created_at, note
      into v_item, v_qty, v_kind, v_prev_qty, v_canceled, v_created, v_text
      from papers_inventories where id = p_id for update;
  else
    select paint_id, counted_qty, kind, previous_qty, canceled_at, created_at, note
      into v_item, v_qty, v_kind, v_prev_qty, v_canceled, v_created, v_text
      from paints_inventories where id = p_id for update;
  end if;

  if v_item is null then
    raise exception using message = 'Запись журнала склада не найдена.', errcode = 'P0002';
  end if;

  -- Повтор отмены — не ошибка: запись уже отменена, делать нечего.
  if v_canceled is not null or coalesce(v_text, '') ilike '%' || c_marker || '%' then
    return;
  end if;

  if p_type = 'paper' then
    select quantity into v_stock from papers where id = v_item for update;
  else
    select quantity into v_stock from paints where id = v_item for update;
  end if;

  if p_movement = 'writeoff' then
    if coalesce(v_source, 'manual') <> 'manual' then
      raise exception using
        message = 'Списание по заказу со склада не отменяется: исправьте количество в заказе или проведите инвентаризацию.',
        errcode = 'check_violation';
    end if;
    if (p_type = 'paper' and exists (select 1 from papers_inventories i
                                      where i.paper_id = v_item and i.kind = 'shortage'
                                        and i.created_at = v_created and i.canceled_at is null))
       or (p_type = 'paint' and exists (select 1 from paints_inventories i
                                         where i.paint_id = v_item and i.kind = 'shortage'
                                           and i.created_at = v_created and i.canceled_at is null)) then
      raise exception using
        message = 'Это списание превысило остаток и записано недостачей — отмена исказит остаток. Проведите инвентаризацию.',
        errcode = 'check_violation';
    end if;
    v_new_stock := coalesce(v_stock, 0) + v_qty;

  elsif p_movement = 'arrival' then
    if coalesce(v_stock, 0) < v_qty then
      raise exception using
        message = format('Недостаточно материала для отмены прихода: остаток %s, приход %s.', coalesce(v_stock, 0), v_qty),
        errcode = 'check_violation';
    end if;
    v_new_stock := v_stock - v_qty;

  else
    if v_kind in ('shortage', 'baseline') then
      raise exception using
        message = 'Запись недостачи или сверки не отменяется — проведите новую инвентаризацию.',
        errcode = 'check_violation';
    end if;
    if v_prev_qty is null then
      raise exception using
        message = 'У этой инвентаризации не сохранён остаток до неё — отменить нельзя, проведите новую.',
        errcode = 'check_violation';
    end if;
    v_new_stock := coalesce(v_stock, 0) + (v_prev_qty - v_qty);
    if v_new_stock < 0 then
      raise exception using
        message = format('Отмена даст отрицательный остаток (%s). Проведите новую инвентаризацию.', v_new_stock),
        errcode = 'check_violation';
    end if;
  end if;

  perform set_config('app.stock_writer', 'journal', true);
  if p_type = 'paper' then
    update papers set quantity = v_new_stock, updated_at = now() where id = v_item;
  else
    update paints set quantity = v_new_stock, updated_at = now() where id = v_item;
  end if;
  perform set_config('app.stock_writer', v_prev, true);

  if p_type = 'paper' and p_movement = 'writeoff' then
    update papers_writeoffs set canceled_at = now(), canceled_by = p_actor,
           reason = trim(c_marker || ' ' || coalesce(reason, '')) where id = p_id;
  elsif p_type = 'paint' and p_movement = 'writeoff' then
    update paints_writeoffs set canceled_at = now(), canceled_by = p_actor,
           reason = trim(c_marker || ' ' || coalesce(reason, '')) where id = p_id;
  elsif p_type = 'paper' and p_movement = 'arrival' then
    update papers_arrivals set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  elsif p_type = 'paint' and p_movement = 'arrival' then
    update paints_arrivals set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  elsif p_type = 'paper' then
    update papers_inventories set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  else
    update paints_inventories set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  end if;
end
$function$
;

-- stock_direct_change_to_journal()
-- md5: 1b31a10a9f3431f99d7103cfb6995ece
CREATE OR REPLACE FUNCTION public.stock_direct_change_to_journal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old numeric := case when tg_op = 'UPDATE' then old.quantity else 0 end;
  v_actor text := coalesce(nullif(current_setting('app.stock_actor', true), ''), 'не указан');
begin
  if coalesce(current_setting('app.stock_writer', true), '') = 'journal' then return null; end if;
  if new.quantity is not distinct from v_old then return null; end if;

  perform set_config('app.stock_writer', 'journal', true);
  if tg_table_name = 'papers' then
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.id, coalesce(new.quantity, 0), v_old, 'correction',
            case when tg_op = 'INSERT' then 'Начальный остаток карточки (без прихода)'
                 else 'Остаток изменён напрямую, в обход журнала' end,
            v_actor, auth.uid());
  else
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.id, coalesce(new.quantity, 0), v_old, 'correction',
            case when tg_op = 'INSERT' then 'Начальный остаток карточки (без прихода)'
                 else 'Остаток изменён напрямую, в обход журнала' end,
            v_actor, auth.uid());
  end if;
  perform set_config('app.stock_writer', '', true);
  return null;
end
$function$
;

-- stock_journal_before_insert()
-- md5: d2f506494fe0d208416b52ebadd0ff83
CREATE OR REPLACE FUNCTION public.stock_journal_before_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_merge_id uuid;
begin
  -- Вложенные if, а не «and»: plpgsql не обещает короткое замыкание, а у
  -- приходов поля previous_qty нет.
  if tg_table_name = 'papers_inventories' then
    if new.kind = 'count' then
      select i.id into v_merge_id
        from (select * from papers_inventories
               where paper_id = new.paper_id
               order by created_at desc, id desc
               limit 1) i
       where i.kind = 'correction'
         and i.canceled_at is null
         and i.by_name = 'не указан'
         and i.note = 'Остаток изменён напрямую, в обход журнала'
         and i.counted_qty = new.counted_qty
         and i.created_at > now() - interval '2 minutes'
         and exists (select 1 from papers p
                      where p.id = new.paper_id and p.quantity = new.counted_qty);
      if v_merge_id is not null then
        update papers_inventories
           set kind = 'count',
               by_name = coalesce(new.by_name, by_name),
               employee_id = coalesce(new.employee_id,
                                      public.employee_id_from_actor(new.by_name),
                                      employee_id),
               note = new.note,
               created_by = coalesce(new.created_by, created_by)
         where id = v_merge_id;
        return null;
      end if;
    end if;
    if new.previous_qty is null then
      select quantity into new.previous_qty from papers where id = new.paper_id;
    end if;
  elsif tg_table_name = 'paints_inventories' then
    if new.kind = 'count' then
      select i.id into v_merge_id
        from (select * from paints_inventories
               where paint_id = new.paint_id
               order by created_at desc, id desc
               limit 1) i
       where i.kind = 'correction'
         and i.canceled_at is null
         and i.by_name = 'не указан'
         and i.note = 'Остаток изменён напрямую, в обход журнала'
         and i.counted_qty = new.counted_qty
         and i.created_at > now() - interval '2 minutes'
         and exists (select 1 from paints p
                      where p.id = new.paint_id and p.quantity = new.counted_qty);
      if v_merge_id is not null then
        update paints_inventories
           set kind = 'count',
               by_name = coalesce(new.by_name, by_name),
               employee_id = coalesce(new.employee_id,
                                      public.employee_id_from_actor(new.by_name),
                                      employee_id),
               note = new.note,
               created_by = coalesce(new.created_by, created_by)
         where id = v_merge_id;
        return null;
      end if;
    end if;
    if new.previous_qty is null then
      select quantity into new.previous_qty from paints where id = new.paint_id;
    end if;
  end if;
  if new.employee_id is null then
    new.employee_id := public.employee_id_from_actor(new.by_name);
  end if;
  return new;
end
$function$
;

-- stock_journal_guard()
-- md5: 4da755b648b01fd8d09ea36791636472
CREATE OR REPLACE FUNCTION public.stock_journal_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_item_exists boolean;
begin
  if tg_table_name like 'papers_%' then
    select exists (select 1 from papers where id = old.paper_id) into v_item_exists;
  else
    select exists (select 1 from paints where id = old.paint_id) into v_item_exists;
  end if;

  -- Каскад от удаления самой карточки склада не мешаем: карточки уже нет.
  if not v_item_exists then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'DELETE' then
    raise exception using
      message = 'Запись журнала склада удалить нельзя — её можно только отменить.',
      errcode = 'check_violation';
  end if;

  raise exception using
    message = 'Количество и позицию в записи журнала склада менять нельзя — отмените запись и внесите новую.',
    errcode = 'check_violation';
end
$function$
;

-- stock_register_return(text,uuid,numeric,text,text)
-- md5: b571318d85f91f830aa11827f33c4c7b
CREATE OR REPLACE FUNCTION public.stock_register_return(p_type text, p_item uuid, p_qty numeric, p_note text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception using message = 'Количество возврата должно быть больше нуля.', errcode = '22023';
  end if;

  if p_type = 'paper' then
    insert into papers_arrivals(paper_id, qty, note, by_name, created_by, source)
    values (p_item, p_qty, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Возврат'), p_actor, auth.uid(), 'return');
  else
    insert into paints_arrivals(paint_id, qty, note, by_name, created_by, source)
    values (p_item, p_qty, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Возврат'), p_actor, auth.uid(), 'return');
  end if;
end
$function$
;

-- stock_set_quantity(text,uuid,numeric,text,text,text)
-- md5: cb8fdf43fcbeeea29ce75c26b20e86cb
CREATE OR REPLACE FUNCTION public.stock_set_quantity(p_type text, p_item uuid, p_qty numeric, p_kind text DEFAULT 'count'::text, p_note text DEFAULT NULL::text, p_actor text DEFAULT NULL::text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_stock numeric;
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_kind not in ('count', 'correction') then
    raise exception using message = format('Неизвестный вид записи: %s', p_kind), errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then
    raise exception using message = 'Остаток не может быть отрицательным.', errcode = '22023';
  end if;

  if p_type = 'paper' then
    select quantity into v_stock from papers where id = p_item for update;
  else
    select quantity into v_stock from paints where id = p_item for update;
  end if;
  if not found then
    raise exception using message = 'Позиция склада не найдена.', errcode = 'P0002';
  end if;

  -- Правка на то же число — не событие. Пересчёт на складе — событие всегда:
  -- «пересчитали, сошлось» тоже факт.
  if p_kind = 'correction' and v_stock = p_qty then
    return v_stock;
  end if;

  if p_type = 'paper' then
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (p_item, p_qty, v_stock, p_kind, nullif(trim(coalesce(p_note, '')), ''), p_actor, auth.uid());
  else
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (p_item, p_qty, v_stock, p_kind, nullif(trim(coalesce(p_note, '')), ''), p_actor, auth.uid());
  end if;

  return p_qty;
end
$function$
;

-- sync_linked_order_form_fields()
-- md5: 9013fb98584ac518953a3b3852e7605b
CREATE OR REPLACE FUNCTION public.sync_linked_order_form_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  update public.orders set form_id = new.id,
    new_form_no = new.number, form_series = new.series, form_code = new.code
  where form_id = new.id
    and row(new_form_no, form_series, form_code)
      is distinct from row(new.number, new.series, new.code);
  return new;
end;
$function$
;

-- sync_order_form_files(uuid)
-- md5: f8947d0ad84006355f3a8b45c4a7f516
CREATE OR REPLACE FUNCTION public.sync_order_form_files(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_form_id uuid;
begin
  select form_id into v_form_id from public.orders where id = p_order_id;
  if v_form_id is null then return; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_form_id::text, 0));
  insert into public.documents(collection, data, created_by)
  select 'form_files',
    (d.data - 'orderId') || jsonb_build_object(
      'formId', v_form_id::text, 'source', 'order', 'orderId', p_order_id::text),
    d.created_by
  from public.documents d
  where d.collection = 'order_files' and d.data->>'orderId' = p_order_id::text
    and nullif(d.data->>'objectPath', '') is not null
    and not exists (
      select 1 from public.documents linked
      where linked.collection = 'form_files'
        and linked.data->>'formId' = v_form_id::text
        and linked.data->>'objectPath' = d.data->>'objectPath'
    );
end;
$function$
;

-- sync_order_paint_reservations(text,jsonb,text)
-- md5: 26ea5ee580022c7d30842170af97bc19
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
  v_reserved_self double precision;
  v_delta double precision;
  v_paint_name text;
  v_total_qty double precision;
  v_stock_name text;
  v_touched public.paints.id%type[] := '{}';
  v_order_id public.orders.id%type;
  -- Неприкасаемый запас, граммы. Парная константа клиента —
  -- kUntouchablePaintGrams в paint_stock_rules.dart.
  v_untouchable constant double precision := 5000;
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

    -- Сколько этот заказ уже держит по этой краске.
    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_self
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id::text = p_order_id;

    v_delta := rec.qty - v_reserved_self;

    -- Не выросло — проверять нечего: бронь либо остаётся прежней, либо часть
    -- её возвращается на склад. Ровно то же правило, что и у бумаги.
    if v_delta > 0 then
      select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
        into v_reserved_other
        from order_paint_reservations r
       where r.paint_id = rec.paint_id
         and r.order_id::text <> p_order_id;

      -- Неприкасаемый запас вычитается ОДИН раз, вместе с чужими бронями.
      v_available := v_total_qty - v_reserved_other - v_untouchable;
      if v_available < rec.qty then
        v_paint_name := coalesce(v_stock_name, rec.stock_name, rec.paint_name, rec.paint_id::text);
        raise exception
          'Не хватает краски "%": нужно добавить % г к уже забронированным % г, а свободно всего % г (на складе % г, из них % г — неприкасаемый запас).',
          v_paint_name,
          round(v_delta::numeric, 2),
          round(v_reserved_self::numeric, 2),
          round(greatest(v_available - v_reserved_self, 0)::numeric, 2),
          round(v_total_qty::numeric, 2),
          round(v_untouchable::numeric, 2);
      end if;
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

-- sync_order_paper_reservations(text,jsonb,text)
-- md5: 7402c836ca14c260f36fdca14a9ae222
CREATE OR REPLACE FUNCTION public.sync_order_paper_reservations(p_order_id text, p_reservations jsonb DEFAULT '[]'::jsonb, p_actor text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec record; v_order_id order_paper_reservations.order_id%type; v_paper_id order_paper_reservations.paper_id%type;
  v_total_qty double precision; v_available double precision; v_reserved_other double precision; v_reserved_self double precision;
  v_delta double precision; v_paper_name text; v_written_off timestamptz;
begin
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  if p_reservations is null then p_reservations := '[]'::jsonb; end if;
  v_order_id := p_order_id;
  select o.paper_written_off_at into v_written_off from public.orders o where o.id::text = p_order_id;
  if v_written_off is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;
  -- Бронь = план минус уже списанное по заказу (расход смен на этапе бумаги).
  create temporary table if not exists _paper_reservation_request(paper_id uuid primary key, qty double precision not null) on commit drop;
  truncate _paper_reservation_request;
  insert into _paper_reservation_request(paper_id, qty)
  select q.paper_id, greatest(q.qty - coalesce((select sum(w.qty) from public.papers_writeoffs w
                                                 where w.order_id = v_order_id and w.paper_id = q.paper_id and w.canceled_at is null), 0), 0)
    from (select nullif(trim(value->>'paper_id'), '')::uuid as paper_id, sum(coalesce(nullif(value->>'qty', '')::double precision, 0)) as qty
            from jsonb_array_elements(p_reservations) where nullif(trim(value->>'paper_id'), '') is not null group by 1) q;
  for rec in select paper_id, qty from _paper_reservation_request order by paper_id loop
    v_paper_id := rec.paper_id;
    select p.quantity, p.description into v_total_qty, v_paper_name from public.papers p where p.id = v_paper_id for update;
    if rec.qty < 0 then raise exception 'Нельзя зарезервировать отрицательное количество бумаги (%).', rec.paper_id; end if;
    if v_total_qty is null then raise exception 'Бумага % не найдена на складе.', rec.paper_id; end if;
    select coalesce(sum(r.qty), 0) into v_reserved_self from public.order_paper_reservations r where r.paper_id = v_paper_id and r.order_id = v_order_id;
    v_delta := rec.qty - v_reserved_self;
    if v_delta <= 0 then continue; end if;
    select coalesce(sum(r.qty), 0) into v_reserved_other from public.order_paper_reservations r where r.paper_id = v_paper_id and r.order_id <> v_order_id;
    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paper_name := coalesce(v_paper_name, rec.paper_id::text);
      raise exception 'Не хватает бумаги "%": нужно добавить % м к уже забронированным % м, а свободно всего % м.',
        v_paper_name, round(v_delta::numeric, 2), round(v_reserved_self::numeric, 2), round(greatest(v_available - v_reserved_self, 0)::numeric, 2);
    end if;
  end loop;
  for rec in select paper_id, qty from _paper_reservation_request loop
    if rec.qty <= 0 then
      delete from public.order_paper_reservations where order_id = v_order_id and paper_id = rec.paper_id;
    else
      insert into public.order_paper_reservations(order_id, paper_id, qty) values (v_order_id, rec.paper_id, rec.qty)
      on conflict (order_id, paper_id) do update set qty = excluded.qty, updated_at = now();
    end if;
  end loop;
  delete from public.order_paper_reservations r where r.order_id = v_order_id
     and not exists (select 1 from _paper_reservation_request q where q.paper_id = r.paper_id and q.qty > 0);
end;
$function$
;

-- task_apply_ops(text,text,jsonb,text[],jsonb,timestamp with time zone)
-- md5: 01f3081f6ca3971d8b2fd91d967221d8
CREATE OR REPLACE FUNCTION public.task_apply_ops(p_task_id text, p_stage_id text, p_comments jsonb, p_assignees text[], p_ops jsonb, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_comments jsonb := public.task_comments_to_array(p_comments);
  v_assignees text[] := coalesce(p_assignees, array[]::text[]);
  v_now timestamptz := coalesce(p_at, clock_timestamp());
  v_now_ms bigint; v_offset int := 0; v_op jsonb; v_kind text; v_user text;
  v_subject text; v_note text; v_type text; v_open int; v_payload jsonb;
  v_event jsonb; v_ts bigint;
  v_shift_paused_users text[] := public.task_shift_pause_users(v_comments);
begin
  v_now_ms := floor(extract(epoch from v_now) * 1000);
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then
    raise exception 'ops must be a json array';
  end if;
  for v_op in select value from jsonb_array_elements(p_ops)
  loop
    v_kind := coalesce(v_op->>'op', '');
    if v_kind = 'add_assignee' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' and array_position(v_assignees, v_user) is null then
        v_assignees := array_append(v_assignees, v_user);
      end if;
    elsif v_kind = 'remove_assignee' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' then v_assignees := array_remove(v_assignees, v_user); end if;
    elsif v_kind = 'claim_stage' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' then v_assignees := array[v_user]; end if;
    elsif v_kind = 'comment' then
      if public.task_finish_record_is_repeat(v_comments, v_op->>'userId', coalesce(v_op->>'type', ''), v_op->>'text') then continue; end if;
      if coalesce(v_op->>'type', '') in ('quantity_stage_total', 'shift_pause_state', 'shift_pause')
         and array_position(v_shift_paused_users, trim(coalesce(v_op->>'userId', ''))) is not null then
        continue;
      end if;
      v_ts := v_now_ms + v_offset; v_offset := v_offset + 1;
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', coalesce(nullif(trim(coalesce(v_op->>'id', '')), ''), v_ts::text),
        'type', coalesce(v_op->>'type', ''), 'text', coalesce(v_op->>'text', ''),
        'userId', coalesce(v_op->>'userId', ''), 'timestamp', v_ts));
    elsif v_kind = 'close_interval' then
      v_subject := trim(coalesce(v_op->>'subject', '')); v_note := v_op->>'note';
      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text')
          || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then v_payload := v_payload || jsonb_build_object('note', v_note); end if;
        v_comments := jsonb_set(v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;
    elsif v_kind = 'open_interval' then
      v_subject := trim(coalesce(v_op->>'subject', ''));
      v_type := coalesce(v_op->>'type', ''); v_note := v_op->>'note';
      if v_subject = '' or v_type = '' then continue; end if;
      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text');
        if coalesce(v_payload->>'type', '') = v_type then continue; end if;
        v_payload := v_payload || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then v_payload := v_payload || jsonb_build_object('note', v_note); end if;
        v_comments := jsonb_set(v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;
      v_ts := v_now_ms + v_offset; v_offset := v_offset + 1;
      v_event := jsonb_strip_nulls(jsonb_build_object(
        'type', v_type, 'startTime', public.task_iso_utc(v_now),
        'initiatedBy', coalesce(v_op->>'initiatedBy', v_subject),
        'subjectUserId', v_subject, 'taskId', p_task_id,
        'workplaceId', coalesce(v_op->>'workplaceId', p_stage_id),
        'participantsSnapshot', coalesce(v_op->'participants', '[]'::jsonb),
        'executionMode', v_op->>'executionMode', 'helperId', v_op->>'helperId', 'note', v_note));
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', v_ts::text || '-' || v_subject, 'type', 'time_event',
        'text', v_event::text, 'userId', v_subject, 'timestamp', v_ts));
    else
      raise exception 'Неизвестная операция этапа: %', v_kind;
    end if;
  end loop;
  select coalesce(jsonb_agg(value order by public.task_comment_millis(value->>'timestamp'), ord), '[]'::jsonb)
    into v_comments from jsonb_array_elements(v_comments) with ordinality as t(value, ord);
  return jsonb_build_object('assignees', to_jsonb(v_assignees), 'comments', v_comments);
end
$function$
;

-- task_apply_stage_events(text,jsonb,text,uuid)
-- md5: 43916c44362c548da6b280c6ea9308e6
CREATE OR REPLACE FUNCTION public.task_apply_stage_events(p_task_id text, p_ops jsonb, p_expect_assignee text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task      tasks%rowtype;
  v_result    jsonb;
  v_assignees text[];
  v_known     jsonb;
begin
  if coalesce(trim(p_task_id), '') = '' then
    raise exception 'task_id is required';
  end if;

  if p_request_id is not null then
    select r.result into v_known
      from public.task_event_requests r
     where r.request_id = p_request_id;
    if found then
      return coalesce(v_known, '{}'::jsonb);
    end if;
  end if;

  select * into v_task from tasks where id::text = p_task_id for update;
  if not found then
    raise exception 'Задача % не найдена.', p_task_id;
  end if;

  v_assignees := coalesce(v_task.assignees, array[]::text[]);
  if coalesce(trim(p_expect_assignee), '') <> ''
     and array_position(v_assignees, trim(p_expect_assignee)) is null then
    raise exception 'Сотрудник % больше не назначен на этап.', p_expect_assignee;
  end if;

  if p_request_id is not null then
    insert into public.task_event_requests (request_id, task_id)
    values (p_request_id, p_task_id)
    on conflict (request_id) do nothing;

    if not found then
      select r.result into v_known
        from public.task_event_requests r
       where r.request_id = p_request_id;
      return coalesce(v_known, '{}'::jsonb);
    end if;
  end if;

  if v_task.status = 'completed' and jsonb_typeof(p_ops) = 'array' and exists (select 1 from jsonb_array_elements(p_ops) o where o->>'op' = 'open_interval') then raise exception using message = 'Этап уже завершён — начать или продолжить работу на нём нельзя. Обновите экран.', errcode = 'check_violation'; end if; v_result := public.task_apply_ops(
    p_task_id, v_task.stage_id, v_task.comments, v_assignees, p_ops);

  update tasks
     set comments  = v_result->'comments',
         assignees = array(select jsonb_array_elements_text(v_result->'assignees'))
   where id::text = p_task_id;

  if p_request_id is not null then
    update public.task_event_requests
       set result = v_result
     where request_id = p_request_id;
  end if;

  return v_result;
end
$function$
;

-- task_comment_millis(text)
-- md5: e83933b66029e6b45e8cfed96667354c
CREATE OR REPLACE FUNCTION public.task_comment_millis(p_value text)
 RETURNS bigint
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v text := trim(coalesce(p_value, ''));
  v_ms bigint;
begin
  if v = '' then return 0; end if;
  -- Метка может прийти и строкой ISO-8601 (легаси-записи).
  if v ~ '^-?\d+$' then
    v_ms := v::bigint;
  else
    begin
      v_ms := floor(extract(epoch from v::timestamptz) * 1000)::bigint;
    exception when others then
      return 0;
    end;
  end if;

  if v_ms <= 0 then return v_ms; end if;
  if v_ms > 10000000000000 then return v_ms / 1000; end if;   -- микросекунды
  if v_ms < 2000000000 then return v_ms * 1000; end if;       -- секунды
  return v_ms;
end
$function$
;

-- task_comments_to_array(jsonb)
-- md5: 1bf53c221c619edc3849593275b165d3
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

-- task_finish_record_is_repeat(jsonb,text,text,text)
-- md5: 8e9968b16828e533827c8b17d6c0cb99
CREATE OR REPLACE FUNCTION public.task_finish_record_is_repeat(p_comments jsonb, p_user text, p_type text, p_text text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_user text := trim(coalesce(p_user, ''));
  v_comments jsonb := public.task_comments_to_array(p_comments);
  v_start_ms bigint;
begin
  if v_user = '' or coalesce(p_type, '') not in ('quantity_done', 'user_done') then
    return false;
  end if;

  -- Последний вход сотрудника в работу.
  select max(public.task_comment_millis(c->>'timestamp'))
    into v_start_ms
    from jsonb_array_elements(v_comments) c
   where (
           c->>'type' = 'time_event'
           and coalesce(public.task_json_payload(c->>'text')->>'subjectUserId',
                        c->>'userId') = v_user
         )
      or (
           c->>'type' in ('start', 'resume', 'joined', 'shift_resume', 'setup_start')
           and c->>'userId' = v_user
         );

  return exists (
    select 1
      from jsonb_array_elements(v_comments) c
     where c->>'userId' = v_user
       and public.task_comment_millis(c->>'timestamp') > coalesce(v_start_ms, 0)
       and (
         c->>'type' = 'user_done'
         or (
           p_type = 'quantity_done'
           and c->>'type' = 'quantity_done'
           and trim(coalesce(c->>'text', '')) = trim(coalesce(p_text, ''))
         )
       )
  );
end
$function$
;

-- task_iso_utc(timestamp with time zone)
-- md5: 70b5fe9e1fb02bbdabe2863cc5a7237b
CREATE OR REPLACE FUNCTION public.task_iso_utc(p_at timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
$function$
;

-- task_json_payload(text)
-- md5: c1ce33bbe0f44f8c85a79907026b1f37
CREATE OR REPLACE FUNCTION public.task_json_payload(p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare v text := trim(coalesce(p_text, ''));
begin
  if v = '' or left(v, 1) <> '{' then return null; end if;
  begin return v::jsonb; exception when others then return null; end;
end
$function$
;

-- task_open_interval_index(jsonb,text)
-- md5: 4cc29a242cfb72d2dc32bb5919bc3be7
CREATE OR REPLACE FUNCTION public.task_open_interval_index(p_comments jsonb, p_subject text)
 RETURNS integer
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_elem jsonb; v_ord int; v_payload jsonb; v_subject text;
  v_ts bigint; v_best_ts bigint := -1; v_best int := null;
begin
  for v_ord, v_elem in
    select (ord - 1)::int, value
      from jsonb_array_elements(public.task_comments_to_array(p_comments))
        with ordinality as t(value, ord)
  loop
    if coalesce(v_elem->>'type', '') <> 'time_event' then continue; end if;
    v_payload := public.task_json_payload(v_elem->>'text');
    if v_payload is null then continue; end if;
    if (v_payload->>'endTime') is not null then continue; end if;
    v_subject := coalesce(v_payload->>'subjectUserId', v_elem->>'userId', '');
    if coalesce(trim(p_subject), '') <> '' and v_subject <> p_subject then continue; end if;
    v_ts := public.task_comment_millis(v_elem->>'timestamp');
    if v_ts > v_best_ts then v_best_ts := v_ts; v_best := v_ord; end if;
  end loop;
  return v_best;
end
$function$
;

-- task_order_quantity_measure(jsonb,text[],text,double precision)
-- md5: c77dc602d133ea7c28032fd0cb5bcebb
CREATE OR REPLACE FUNCTION public.task_order_quantity_measure(p_comments jsonb, p_assignees text[], p_stage_unit text, p_pack_size double precision)
 RETURNS TABLE(qty double precision, latest_ms bigint)
 LANGUAGE sql
 IMMUTABLE
AS $function$
  with c as (
    select e,
           public.task_quantity_payload(e->>'text') as payload,
           trim(coalesce(e->>'userId', e->>'user_id', '')) as author
      from jsonb_array_elements(public.task_comments_to_array(p_comments)) e
  ),
  owner as (
    select coalesce((select trim(a) from unnest(p_assignees) with ordinality u(a, ord)
                      where trim(coalesce(a, '')) <> '' order by ord limit 1), '') as id
  ),
  helpers as (
    select distinct c.author
      from c, owner
     where c.e->>'type' = 'joined' and owner.id <> '' and c.author <> '' and c.author <> owner.id
  ),
  counted as (
    select c.e,
           public.task_quantity_value(c.e->>'text') as v,
           coalesce(nullif(trim(c.payload->>'unit'), ''), coalesce(p_stage_unit, '')) as unit
      from c
     where c.e->>'type' in ('quantity_stage_total', 'quantity_share', 'quantity_done', 'quantity_team_total')
       and not coalesce(c.payload->'generated' = 'true'::jsonb, false)
       and not exists (select 1 from helpers h where h.author = c.author)
  )
  select coalesce(sum(case when regexp_replace(lower(trim(unit)), '\s+', ' ', 'g')
                                in ('уп', 'уп.', 'упак', 'упаковка', 'упаковки', 'пач', 'пачка', 'пачки', 'pack', 'packs')
                           then v * coalesce(p_pack_size, 1) else v end), 0),
         coalesce(max(public.task_comment_millis(e->>'timestamp')), 0)
    from counted;
$function$
;

-- task_quantity_payload(text)
-- md5: 74ae32c824fc6f572e5bad9724418205
CREATE OR REPLACE FUNCTION public.task_quantity_payload(p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v text := trim(coalesce(p_text, ''));
begin
  if v = '' or left(v, 1) <> '{' then return null; end if;
  begin
    return v::jsonb;
  exception when others then
    return null;
  end;
end
$function$
;

-- task_quantity_share_preview(text)
-- md5: a188a50c348765c532854bca7246da14
CREATE OR REPLACE FUNCTION public.task_quantity_share_preview(p_task_id text)
 RETURNS TABLE(employee_id text, role text, segment_end timestamp with time zone, seconds numeric, raw_share numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  -- Меньше секунды в отрезке — не участие, а рассинхрон меток (20260914).
  c_min_seconds constant numeric := 1;
  v_task tasks%rowtype;
  v_comments jsonb;
  v_assignees text[];
  v_owner text;
  v_helpers text[];
  v_split boolean;
  v_workplace text;
  v_now timestamptz := date_trunc('milliseconds', now());
  v_prev timestamptz := '-infinity'::timestamptz;
  v_seg record;
begin
  select * into v_task from public.tasks where id::text = p_task_id;
  if not found then return; end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);
  v_assignees := coalesce(v_task.assignees, array[]::text[]);
  v_owner := coalesce(v_assignees[1], '');

  -- Помощник — автор «joined», не совпадающий с основным исполнителем. То же
  -- правило действует в аналитике и в расчёте факта заказа; разъехавшись, они
  -- дали бы разные ответы на вопрос «кто здесь помощник».
  select coalesce(array_agg(distinct j.uid), array[]::text[])
    into v_helpers
    from (
      select trim(c->>'userId') as uid
        from jsonb_array_elements(v_comments) c
       where c->>'type' = 'joined'
    ) j
   where j.uid <> '' and j.uid <> v_owner;

  v_workplace := coalesce(
    nullif(trim(coalesce(v_task.captured_by_workplace_id::text, '')), ''),
    v_task.stage_id::text
  );
  select w.split_quantity_by_time into v_split
    from public.workplaces w
   where w.id::text = v_workplace;
  -- Рабочее место не найдено — делим по времени: это поведение по умолчанию
  -- для всех РМ, кроме явно перечисленных станков.
  v_split := coalesce(v_split, true);

  for v_seg in
    select m.seg_end, m.qty, m.author
      from (
        -- Метка записи — целые миллисекунды; граница считается без плавающей
        -- точки, чтобы сравнение с интервалами было точным.
        select timestamptz 'epoch'
                 + public.task_comment_millis(c->>'timestamp')
                   * interval '1 millisecond' as seg_end,
               public.task_quantity_value(c->>'text') as qty,
               coalesce(trim(c->>'userId'), '') as author
          from jsonb_array_elements(v_comments) c
         where c->>'type' = 'quantity_stage_total'
      ) m
     where m.qty > 0
     order by m.seg_end
  loop
    return query
    with worked as (
      select
        trim(p.ev->>'subjectUserId') as uid,
        sum(
          greatest(
            0::numeric,
            extract(epoch from (
              least(
                -- Интервалы пишутся с микросекундами, отрезки — с
                -- миллисекундами. Без приведения хвост интервала сдавшего
                -- смену попадал в следующий отрезок.
                date_trunc('milliseconds',
                  coalesce(nullif(p.ev->>'endTime', '')::timestamptz, v_now)),
                v_seg.seg_end
              )
              - greatest(
                  date_trunc('milliseconds', (p.ev->>'startTime')::timestamptz),
                  v_prev)
            ))::numeric
          )
        ) as secs
      from jsonb_array_elements(v_comments) c
      cross join lateral (
        select public.task_quantity_payload(c->>'text') as ev
      ) p
      where c->>'type' = 'time_event'
        and p.ev is not null
        and p.ev->>'type' = 'production'
        and coalesce(trim(p.ev->>'subjectUserId'), '') <> ''
        and coalesce(p.ev->>'startTime', '') <> ''
      group by 1
    ),
    positive as (
      select w.uid, w.secs from worked w where w.secs >= c_min_seconds
    ),
    participants as (
      select p.uid, p.secs from positive p
      union all
      -- T_total = 0: в отрезке никто не отработал ни секунды — станок стоял на
      -- пересмене или «проблеме», а тираж ввели уже после остановки. Делить не
      -- на кого, но и отдавать assignees нельзя: это ТЕКУЩИЕ исполнители, а
      -- смену мог сдавать другой человек. Засчитываем автору записи.
      select v_seg.author, 0::numeric
       where not exists (select 1 from positive)
         and v_seg.author <> ''
      union all
      -- Автор записи неизвестен (старый формат) — прежнее правило: поровну
      -- между исполнителями задачи.
      select a.uid, 0::numeric
        from unnest(v_assignees) as a(uid)
       where not exists (select 1 from positive)
         and v_seg.author = ''
         and coalesce(trim(a.uid), '') <> ''
    ),
    total as (
      select coalesce(sum(pt.secs), 0) as secs,
             greatest(count(*), 1) as head_count
        from participants pt
    )
    select
      pt.uid,
      case
        when pt.uid = v_owner then 'owner'
        when pt.uid = any(v_helpers) then 'helper'
        else 'executor'
      end,
      v_seg.seg_end,
      pt.secs,
      case
        -- Станок один на бригаду: вклад по часам не измеряется, тираж делает
        -- машина. Каждому пишется полное количество.
        when not v_split then v_seg.qty::numeric
        when t.secs > 0 then v_seg.qty::numeric * pt.secs / t.secs
        else v_seg.qty::numeric / t.head_count
      end
    from participants pt
    cross join total t;

    v_prev := v_seg.seg_end;
  end loop;

  return;
end
$function$
;

-- task_quantity_value(text)
-- md5: aea2eba7638180959f9bccc8d7a78914
CREATE OR REPLACE FUNCTION public.task_quantity_value(p_value text)
 RETURNS double precision
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_payload jsonb := public.task_quantity_payload(p_value);
  v text := replace(coalesce(p_value, ''), ',', '.');
  m text[];
begin
  if v_payload is not null and v_payload ? 'actual' then
    begin
      return (v_payload->>'actual')::double precision;
    exception when others then
      null;  -- битый actual — разбираем дальше как свободный текст
    end;
  end if;

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
end
$function$
;

-- task_shift_pause_users(jsonb)
-- md5: 03e39159b74be84a58c65aad755ec2b9
CREATE OR REPLACE FUNCTION public.task_shift_pause_users(p_comments jsonb)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(
    array_agg(distinct coalesce(
      public.task_json_payload(c->>'text')->>'subjectUserId',
      c->>'userId'
    )),
    array[]::text[]
  )
  from jsonb_array_elements(public.task_comments_to_array(p_comments)) c
  where c->>'type' = 'time_event'
    and public.task_json_payload(c->>'text') is not null
    and (public.task_json_payload(c->>'text')->>'endTime') is null
    and coalesce(public.task_json_payload(c->>'text')->>'type', '') = 'shift_change';
$function$
;

-- tasks_close_intervals_on_complete()
-- md5: 5281eb993a2bcd6deb917c034f359660
CREATE OR REPLACE FUNCTION public.tasks_close_intervals_on_complete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_comments jsonb;
  v_open int;
  v_payload jsonb;
  v_now timestamptz := clock_timestamp();
  v_guard int := 0;
begin
  if new.status <> 'completed' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'completed' then return new; end if;

  v_comments := public.task_comments_to_array(new.comments);
  loop
    v_open := public.task_open_interval_index(v_comments, null);
    exit when v_open is null;
    v_payload := public.task_json_payload(v_comments->v_open->>'text')
      || jsonb_build_object('endTime', public.task_iso_utc(v_now))
      || jsonb_build_object('note', 'stage_completed');
    v_comments := jsonb_set(
      v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
    v_guard := v_guard + 1;
    exit when v_guard > 500;
  end loop;
  new.comments := v_comments;

  -- Время завершения ставится здесь, одним местом для всех путей: RPC,
  -- пропуск этапа, ручная смена статуса.
  if new.completed_at is null then
    new.completed_at := floor(extract(epoch from v_now) * 1000)::bigint;
  end if;

  return new;
end
$function$
;

-- tasks_guard_active_assignees()
-- md5: 4da1e5618565230014a4e7ba3aad4f78
CREATE OR REPLACE FUNCTION public.tasks_guard_active_assignees()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog', 'pg_temp'
AS $function$
declare
  v_removed text;
  v_has_open boolean;
  v_comments jsonb;
begin
  if coalesce(current_setting('app.allow_assignee_drop', true), '') = 'on' then
    return new;
  end if;

  if coalesce(new.assignees, '{}') @> coalesce(old.assignees, '{}') then
    return new;
  end if;

  v_comments := public.task_comments_to_array(coalesce(new.comments, '[]'::jsonb));

  for v_removed in
    select x
      from unnest(coalesce(old.assignees, '{}'::text[])) as x
     where not (x = any (coalesce(new.assignees, '{}'::text[])))
  loop
    select exists (
      select 1
        from jsonb_array_elements(v_comments) c
       where c->>'type' = 'time_event'
         and left(coalesce(c->>'text', ''), 1) = '{'
         and ((c->>'text')::jsonb ->> 'subjectUserId') = v_removed
         and ((c->>'text')::jsonb ->> 'endTime') is null
    ) into v_has_open;

    if v_has_open then
      raise exception
        'Нельзя снять исполнителя % с задачи %: у него не закрыт интервал. Сначала закройте интервал (closeInterval), затем снимайте исполнителя.',
        v_removed, new.id
        using errcode = 'check_violation';
    end if;
  end loop;

  return new;
end;
$function$
;

-- tg_orders_fill_product_type_id()
-- md5: fc38716752ae8f5890697806721754ee
CREATE OR REPLACE FUNCTION public.tg_orders_fill_product_type_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_title text;
  v_id    uuid;
begin
  -- Клиент прислал id сам — не вмешиваемся.
  if tg_op = 'INSERT' and new.product_type_id is not null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.product_type_id is distinct from old.product_type_id then
    return new;
  end if;

  -- Ничего не изменилось: заголовок тот же, id уже стоит.
  if tg_op = 'UPDATE'
     and new.product_type_id is not null
     and new.product->>'type' is not distinct from old.product->>'type' then
    return new;
  end if;

  v_title := nullif(btrim(coalesce(new.product->>'type', '')), '');
  if v_title is null then
    return new;   -- тип не указан вовсе; прежнее значение не трогаем
  end if;

  select c.id into v_id
    from public.warehouse_categories c
   where lower(btrim(c.title)) = lower(v_title);

  -- Нашли — заполняем. Не нашли — оставляем как было и молча выходим.
  if v_id is not null then
    new.product_type_id := v_id;
  end if;

  return new;
end;
$function$
;

-- tg_orders_sync_prod_plan()
-- md5: 60dfb29160ca04db99e6535362abbfc3
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

-- tg_set_updated_at()
-- md5: 19f6a32669c21e1f5530213955c53e03
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

-- trg_orders_sync_form_fields()
-- md5: 18b7b8a35c07719aa47ede0a598fa6fe
CREATE OR REPLACE FUNCTION public.trg_orders_sync_form_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
  v_form public.forms%rowtype;
  v_refs_changed boolean := true;
begin
  if tg_op = 'UPDATE' then
    v_refs_changed := row(new.new_form_no, new.form_series, new.form_code)
      is distinct from row(old.new_form_no, old.form_series, old.form_code);
    -- Explicit detach, including the existing FK ON DELETE SET NULL.
    if old.form_id is not null and new.form_id is null and not v_refs_changed then
      new.has_form := false;
    end if;
  end if;

  if new.has_form is false then
    new.form_id := null;
    new.new_form_no := null;
    new.form_series := null;
    new.form_code := null;
    new.is_old_form := false;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.form_id is not distinct from old.form_id and v_refs_changed then
      -- An older client changes only text. Resolve the WHOLE reference.
      v_id := public.resolve_order_form(null, new.form_code, new.form_series, new.new_form_no);
    else
      v_id := public.resolve_order_form(new.form_id, new.form_code, new.form_series, new.new_form_no);
    end if;
  else
    v_id := public.resolve_order_form(new.form_id, new.form_code, new.form_series, new.new_form_no);
  end if;

  if v_id is null then
    -- Leave unrelated edits to pre-existing unresolved records possible.
    if tg_op = 'UPDATE' then
      if not v_refs_changed and new.form_id is not distinct from old.form_id
        and new.has_form is not distinct from old.has_form
        and new.is_old_form is not distinct from old.is_old_form then
        return new;
      end if;
    end if;
    -- New-form drafts can exist before a warehouse record is created.
    if new.form_id is null and new.new_form_no is null
      and nullif(btrim(new.form_series), '') is null
      and nullif(btrim(new.form_code), '') is null
      and not coalesce(new.is_old_form, false) then
      return new;
    end if;
    raise exception using errcode = '23503',
      message = 'Выберите существующую форму из списка склада: ссылка не найдена или неоднозначна';
  end if;

  select * into strict v_form from public.forms where id = v_id;
  new.has_form := true;
  new.form_id := v_id;
  new.new_form_no := v_form.number;
  new.form_series := v_form.series;
  new.form_code := v_form.code;
  return new;
end;
$function$
;

-- trg_orders_sync_form_no()
-- md5: e4ccf30347390f6504fc2372a365f2e0
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

-- trg_sync_order_form_files()
-- md5: 9f190680b6f70763ff89d40ecbceafe0
CREATE OR REPLACE FUNCTION public.trg_sync_order_form_files()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_order_id uuid;
begin
  if tg_table_name = 'orders' then
    perform public.sync_order_form_files(new.id);
  elsif new.collection = 'order_files' then
    select id into v_order_id from public.orders where id::text = new.data->>'orderId';
    if v_order_id is not null then perform public.sync_order_form_files(v_order_id); end if;
  end if;
  return new;
end;
$function$
;

-- update_task_quantity_comment(text,text,text,text,text)
-- md5: d89e7be815e92cca3601f21d20107c47
CREATE OR REPLACE FUNCTION public.update_task_quantity_comment(p_task_id text, p_comment_id text, p_new_text text, p_audit_text text, p_audit_user_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_task tasks%rowtype;
  v_comments jsonb;
  v_target jsonb;
  v_old_text text;
begin
  if coalesce(trim(p_task_id), '') = '' or coalesce(trim(p_comment_id), '') = '' then
    raise exception using
      message = 'task id and comment id are required',
      errcode = '22023';
  end if;
  if coalesce(trim(p_new_text), '') = '' then
    raise exception using
      message = 'new quantity payload is empty',
      errcode = '22023';
  end if;

  -- Блокируем строку: параллельная правка того же задания подождёт, а не
  -- перезапишет наш массив своим устаревшим снимком.
  select * into v_task
    from public.tasks
   where id::text = p_task_id
   for update;

  if not found then
    raise exception using
      message = 'task not found',
      errcode = 'P0002';
  end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  select elem
    into v_target
    from jsonb_array_elements(v_comments) as elem
   where elem->>'id' = p_comment_id
   limit 1;

  if v_target is null then
    raise exception using
      message = 'quantity record not found in task comments',
      errcode = 'P0002',
      hint = 'The record was probably rewritten by another correction. Reload analytics and retry.';
  end if;

  -- Править разрешено только записи количества: подменять произвольный
  -- комментарий (старт, паузу, проблему) эта функция не должна.
  if coalesce(v_target->>'type', '') not in
       ('quantity_done', 'quantity_team_total', 'quantity_share') then
    raise exception using
      message = 'only quantity records can be corrected',
      errcode = '22023',
      detail = coalesce(v_target->>'type', 'unknown');
  end if;

  v_old_text := v_target->>'text';

  select coalesce(
           jsonb_agg(
             case
               when elem->>'id' = p_comment_id
                 then jsonb_set(elem, '{text}', to_jsonb(p_new_text))
               else elem
             end
             order by ord
           ),
           '[]'::jsonb
         )
    into v_comments
    from jsonb_array_elements(v_comments) with ordinality as t(elem, ord);

  -- След правки виден в истории заказа наравне с обычными комментариями.
  if coalesce(trim(p_audit_text), '') <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_edit',
      'text', p_audit_text,
      'userId', coalesce(p_audit_user_id, ''),
      'timestamp', v_now_ms
    ));
  end if;

  update public.tasks
     set comments = v_comments
   where id::text = p_task_id;

  return jsonb_build_object(
    'task_id', p_task_id,
    'comment_id', p_comment_id,
    'order_id', v_task.order_id::text,
    'stage_id', v_task.stage_id::text,
    'old_text', v_old_text,
    'new_text', p_new_text
  );
end
$function$
;

-- upsert_form(text,integer,text,text,text,text,text,text,text)
-- md5: d75ad16f7ae2314c97025a4dc92a9457
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

-- validate_product_type_config(uuid)
-- md5: b57ec5013110ac651fe23acab769e42e
CREATE OR REPLACE FUNCTION public.validate_product_type_config(p_config_id uuid)
 RETURNS TABLE(code text, message text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with recursive parallel_edges as (
    select s.id as src, s.parallel_with_stage_id as dst
      from product_type_stages s
     where s.config_id = p_config_id
       and s.execution_mode = 'parallel_with'
       and s.parallel_with_stage_id is not null
  ),
  parallel_walk (start_id, node, depth) as (
    select src, dst, 1 from parallel_edges
    union all
    select w.start_id, e.dst, w.depth + 1
      from parallel_walk w
      join parallel_edges e on e.src = w.node
     where w.depth < 10
  )

  select 'stage_without_workplaces',
         format('Этап «%s» не имеет ни одного рабочего места.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id)

  union all
  select 'one_of_needs_two_variants',
         format('Переключаемый этап «%s»: вариантов меньше двух.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and (select count(*) from product_type_stage_workplaces w
           where w.stage_id = s.id) < 2

  union all
  select 'one_of_needs_default',
         format('Переключаемый этап «%s»: не выбран вариант по умолчанию.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id and w.is_default)

  union all
  select 'sub_stage_foreign_config',
         format('Под-этап «%s» принадлежит варианту из другого типа продукта.', s.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.config_id <> s.config_id

  union all
  select 'sub_stage_parent_not_switchable',
         format('Под-этап «%s» привязан к рабочему месту этапа «%s», '
                'который не является переключаемым.', s.title, parent.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.selection_mode <> 'one_of'

  union all
  select 'bad_handle_type_param',
         format('Этап «%s»: недопустимый тип ручки «%s».',
                s.title, coalesce(c.param_text, '—'))
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
   where s.config_id = p_config_id
     and c.predicate = 'handle_type_is'
     and coalesce(c.param_text, '') not in ('flat', 'twisted', 'dieCut')

  union all
  select 'unexpected_param',
         format('Этап «%s»: условие «%s» не принимает значения.', s.title, c.predicate)
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
    join order_predicates p on p.code = c.predicate
   where s.config_id = p_config_id
     and p.param_kind is null
     and c.param_text is not null

  union all
  select 'route_empty',
         'Маршрут пуст: не задано ни одного этапа.'
    from (select 1) _
   where not exists (select 1 from product_type_stages s
                      where s.config_id = p_config_id)

  union all
  select 'actual_qty_formula_missing',
         'Не выбрана формула фактического количества: без неё нельзя '
         'посчитать факт, а от него зависят отгрузка и списания со склада.'
    from product_type_configs c
   where c.id = p_config_id
     and c.actual_qty_formula is null

  union all
  select 'group_mixes_levels',
         format('Позицию %s делят общий этап и под-этап варианта — они не '
                'взаимоисключающие.', g.position)
    from (
      select s.position, count(distinct s.level) as levels
        from product_type_stages s
       where s.config_id = p_config_id and not s.is_pinned_last
       group by s.position
    ) g
   where g.levels > 1

  union all
  select 'group_across_switches',
         format('Позицию %s делят под-этапы разных переключателей.', g.position)
    from (
      select s.position, count(distinct w.stage_id) as switches
        from product_type_stages s
        join product_type_stage_workplaces w on w.id = s.parent_variant_id
       where s.config_id = p_config_id and s.level = 1
       group by s.position
    ) g
   where g.switches > 1

  union all
  select 'group_same_variant',
         format('Позицию %s делят под-этапы одного варианта — они появятся '
                'вместе.', g.position)
    from (
      select s.position,
             count(*) as total,
             count(distinct s.parent_variant_id) as variants
        from product_type_stages s
       where s.config_id = p_config_id and s.level = 1
       group by s.position
    ) g
   where g.variants <> g.total

  union all
  select 'sub_stage_before_switch',
         format('Под-этап «%s» на позиции %s стоит не позже переключателя '
                '«%s» (позиция %s).', s.title, s.position, p.title, p.position)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages p on p.id = w.stage_id
   where s.config_id = p_config_id
     and s.level = 1
     and s.position <= p.position

  union all
  select 'parallel_without_partner',
         format('Этап «%s» настроен параллельно с другим этапом, но партнёр '
                'не выбран.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.execution_mode = 'parallel_with'
     and s.parallel_with_stage_id is null

  union all
  select 'partner_without_parallel',
         format('У этапа «%s» выбран партнёр, но режим не «параллельно с '
                'этапом».', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.parallel_with_stage_id is not null
     and s.execution_mode <> 'parallel_with'

  union all
  select 'parallel_partner_foreign_config',
         format('Этап «%s»: партнёр принадлежит другому типу продукта.', s.title)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.config_id <> s.config_id

  union all
  select 'parallel_partner_after_stage',
         format('Этап «%s» (позиция %s) не может идти параллельно с «%s» '
                '(позиция %s): партнёр должен стоять раньше.',
                s.title, s.position, p.title, p.position)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.position >= s.position

  union all
  select 'parallel_partner_unreachable',
         format('Этап «%s»: партнёр «%s» принадлежит другому варианту и при '
                'его невыборе не появится в очереди.', s.title, p.title)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.level = 1
     and (s.level <> 1 or s.parent_variant_id is distinct from p.parent_variant_id)

  union all
  select 'parallel_partner_cycle',
         format('Этап «%s» участвует в замкнутой цепочке параллельных этапов: '
                'ни один из них не сможет начаться.', s.title)
    from (select distinct start_id from parallel_walk where node = start_id) c
    join product_type_stages s on s.id = c.start_id;
$function$
;

-- warehouse_pens_apply_inventory()
-- md5: 0a73c9b82b76a2c5c2b045eb2edbc58d
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

-- wh_stationery_apply_arrival()
-- md5: 4232d50db38daaed09a22432b39a0474
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

-- wh_stationery_apply_inventory()
-- md5: cc169b8fbdedc2302329b10cc7f8338d
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

-- wh_stationery_apply_writeoff()
-- md5: c4caef5169cda4d3e922569ca633b176
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

-- workplace_queue_adopt_task()
-- md5: 2bc3e2c2129d4907b141a0fad349daa2
CREATE OR REPLACE FUNCTION public.workplace_queue_adopt_task()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.workplace_queue_positions
     set task_id = new.id::text, updated_at = now()
   where task_id is null
     and order_id = new.order_id::text
     and stage_id = new.stage_id
     and coalesce(stage_group_key, '') = coalesce(nullif(new.stage_group_key, ''), new.stage_id);
  return new;
end
$function$
;

-- workplace_queue_release_task()
-- md5: 9c45ac13e9389cbbad17cf84dba8bcfc
CREATE OR REPLACE FUNCTION public.workplace_queue_release_task()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update public.workplace_queue_positions
     set task_id = null, updated_at = now()
   where task_id = old.id::text;
  return old;
end
$function$
;

-- writeoff(text,uuid,numeric,text,text)
-- md5: 04447064d3e9f3da41c5caa9e36e0f23
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

-- writeoff(text,uuid,numeric,text)
-- md5: 57e1588973d2d1299ef097d9427ae4f5
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

-- writeoffs_fill_trace()
-- md5: bb9c63b895fcdde06fd47f01bcbb8722
CREATE OR REPLACE FUNCTION public.writeoffs_fill_trace()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uuid text;
begin
  if new.order_id is null and new.reason is not null then
    v_uuid := substring(new.reason from '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
    if v_uuid is not null and exists (select 1 from orders o where o.id::text = lower(v_uuid)) then
      new.order_id := lower(v_uuid)::uuid;
    end if;
  end if;

  if new.source is null then
    new.source := case
      when tg_table_name = 'paints_writeoffs' and new.reason like 'Списание флексопечати по заказу %из очереди' then 'flex_queue'
      when tg_table_name = 'paints_writeoffs' and new.reason like 'Списание флексопечати по заказу %' then 'flex_now'
      when tg_table_name = 'papers_writeoffs' and new.reason like 'Списание бумаги по заказу %' then 'paper_order'
      else 'manual'
    end;
  end if;

  if new.employee_id is null then
    new.employee_id := public.employee_id_from_actor(new.by_name);
  end if;

  return new;
end
$function$
;
