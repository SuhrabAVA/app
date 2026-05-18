-- Complete flex printing and atomically handle current-order and queued paint write-offs.

create or replace function public.complete_flex_printing_stage_with_paint_queue(
  p_task_id text,
  p_order_id text,
  p_stage_id text,
  p_employee_id text,
  p_current_order_rows jsonb default '[]'::jsonb,
  p_pending_rows jsonb default '[]'::jsonb,
  p_quantity_done text default null,
  p_comment text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.complete_flex_printing_stage_with_paint_queue(text, text, text, text, jsonb, jsonb, text, text, text)
to authenticated, anon;
