-- Atomic task-stage completion RPCs.
-- Keeps quantity/comment writes, stock reservation finalization, task status updates,
-- and order advancement in one backend transaction.

create or replace function public.task_quantity_value(p_value text)
returns double precision
language plpgsql
immutable
as $$
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
$$;

create or replace function public.task_comments_to_array(p_comments jsonb)
returns jsonb
language sql
immutable
as $$
  select case
    when p_comments is null then '[]'::jsonb
    when jsonb_typeof(p_comments) = 'array' then p_comments
    when jsonb_typeof(p_comments) = 'object' then coalesce((select jsonb_agg(value) from jsonb_each(p_comments)), '[]'::jsonb)
    else '[]'::jsonb
  end
$$;

create or replace function public.advance_order_after_task_completion(
  p_order_id text,
  p_stage_id text,
  p_stage_group_key text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
     where order_id = p_order_id
       and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key
       and status <> 'completed';
  else
    update tasks
       set status = 'completed',
           started_at = null
     where order_id = p_order_id
       and coalesce(nullif(stage_group_key, ''), stage_id) = v_group_key
       and status <> 'completed';
  end if;

  if to_regclass('public.prod_plans') is not null and to_regclass('public.prod_plan_stages') is not null then
    select id::text into v_plan_id
      from public.prod_plans
     where order_id = p_order_id
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
   where order_id = p_order_id
     and stage_id = p_stage_id;

  if coalesce(v_completed_all_stage, false) then
    select exists(
      select 1 from tasks
       where order_id = p_order_id
         and stage_id <> p_stage_id
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
          where order_id = p_order_id and stage_id = p_stage_id
        ) s;

      update orders
         set actual_qty = v_actual_qty
       where id = p_order_id;
    end if;
  end if;

  select bool_and(status = 'completed')
    into v_order_completed
    from tasks
   where order_id = p_order_id;

  if coalesce(v_order_completed, false) then
    update orders
       set status = 'completed'
     where id = p_order_id;

    if to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
    end if;
  end if;
end;
$$;

create or replace function public.complete_task_stage(
  p_task_id text,
  p_order_id text,
  p_stage_id text,
  p_employee_id text,
  p_quantity_done text default null,
  p_comment text default null,
  p_joint_user_ids jsonb default '[]'::jsonb,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
   where id = p_task_id and order_id = p_order_id and stage_id = p_stage_id
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
   where id = p_task_id;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$$;

grant execute on function public.complete_task_stage(text, text, text, text, text, text, jsonb, text)
to authenticated, anon;

create or replace function public.complete_flex_printing_stage(
  p_task_id text,
  p_order_id text,
  p_stage_id text,
  p_employee_id text,
  p_paint_usages jsonb default '[]'::jsonb,
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
  rec record;
  rel record;
  v_reserved_other double precision;
  v_available double precision;
  v_paint_name text;
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_comments jsonb;
  v_touched text[] := array[]::text[];
  v_user_id text := coalesce(nullif(trim(p_employee_id), ''), nullif(trim(p_actor), ''), 'system');
  v_assignee text;
begin
  if coalesce(trim(p_task_id), '') = '' then raise exception 'task_id is required'; end if;
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  if coalesce(trim(p_stage_id), '') = '' then raise exception 'stage_id is required'; end if;
  if p_paint_usages is null then p_paint_usages := '[]'::jsonb; end if;

  select * into v_task
    from tasks
   where id = p_task_id and order_id = p_order_id and stage_id = p_stage_id
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

  for rec in
    with requested as (
      select
        nullif(trim(coalesce(value->>'paint_id', value->>'material_id')), '') as paint_id,
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
    for update of p
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя списать отрицательное количество краски (%).', coalesce(rec.stock_name, rec.paint_name, rec.paint_id);
    end if;
    if rec.qty = 0 then
      continue;
    end if;
    if rec.paint_id is null or rec.total_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id <> p_order_id;

    v_available := rec.total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paint_name := coalesce(rec.stock_name, rec.paint_name, rec.paint_id);
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
           paint_name = coalesce(paint_name, rec.paint_name, rec.stock_name),
           updated_at = now()
     where order_id = p_order_id and paint_id = rec.paint_id;

    if not found then
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (p_order_id, rec.paint_id, coalesce(rec.paint_name, rec.stock_name), rec.qty, rec.qty, 0)
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
     where order_id = p_order_id
       and greatest(reserved_qty - used_qty - released_qty, 0) > 0
     for update
  loop
    update order_paint_reservations
       set released_qty = greatest(reserved_qty - used_qty, 0),
           updated_at = now()
     where order_id = p_order_id and paint_id = rel.paint_id;
    v_touched := array_append(v_touched, rel.paint_id);
  end loop;

  perform recalculate_paint_reserved_qty((select array_agg(distinct x) from unnest(v_touched) as x where x is not null));

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
   where id = p_task_id;

  perform public.advance_order_after_task_completion(
    p_order_id,
    p_stage_id,
    coalesce(nullif(v_task.stage_group_key, ''), p_stage_id),
    coalesce(nullif(trim(p_actor), ''), v_user_id)
  );
end;
$$;

grant execute on function public.complete_flex_printing_stage(text, text, text, text, jsonb, text, text, text)
to authenticated, anon;
