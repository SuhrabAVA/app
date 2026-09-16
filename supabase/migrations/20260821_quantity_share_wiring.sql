-- ============================================================================
-- Подключение расчёта долей к завершению этапа (2026-08-21)
--
-- Что меняется
-- ------------
-- 1. complete_task_stage — в совместном режиме вместо «полное Q каждому
--    помощнику + quantity_team_total владельцу» пишется ОДНА запись тиража
--    quantity_stage_total, после чего вызывается
--    recompute_task_quantity_shares. Режим отдельного исполнителя не тронут:
--    там делить не с кем, quantity_done остаётся личной записью.
-- 2. complete_flex_printing_stage_with_paint_queue — то же самое. Флексопечать
--    входит в список рабочих мест со split_quantity_by_time = false, поэтому
--    расчёт запишет каждому участнику полное количество; отдельная запись
--    тиража нужна для факта заказа.
-- 3. advance_order_after_task_completion — orders.actual_qty считается по
--    quantity_stage_total (сумма записей: пересмены + завершение). Для задач
--    без этой записи поведение прежнее, легаси-заказы не пересчитываются.
--
-- ⚠ ПЕРЕД ПРИМЕНЕНИЕМ
-- -------------------
-- Тела трёх функций взяты из снимка supabase/functions_dump.sql (05.08.2026)
-- и пропатчены точечно — нетронутые части байт-в-байт совпадают со снимком.
-- Если в боевой базе эти функции с тех пор правились мимо миграций, применение
-- ОТКАТИТ те правки. Сверьте определения перед накатом:
--
--   select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('complete_task_stage',
--                        'complete_flex_printing_stage_with_paint_queue',
--                        'advance_order_after_task_completion');
--
-- Проверить расчёт, ничего не записывая:
--   select * from public.task_quantity_share_preview('<task_id>');
-- ============================================================================

begin;

do $preflight$
begin
  if to_regprocedure('public.recompute_task_quantity_shares(text)') is null then
    raise exception using
      message = 'public.recompute_task_quantity_shares(text) is missing',
      hint = 'Apply 20260821_quantity_share_rpc.sql first.';
  end if;

  if to_regprocedure('public.task_quantity_share_preview(text)') is null then
    raise exception using
      message = 'public.task_quantity_share_preview(text) is missing',
      hint = 'Apply 20260821_quantity_share_rpc.sql first.';
  end if;
end
$preflight$;

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


commit;
