-- Cast text RPC order ids through public.orders.id%type before inserting into uuid order_id columns.
-- This keeps the public RPC signature stable for the Flutter client while avoiding
-- Postgres 42804 errors on databases where orders.id/order_paint_reservations.order_id are uuid.

create or replace function public.sync_order_paint_reservations(
  p_order_id text,
  p_reservations jsonb default '[]'::jsonb,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.sync_order_paint_reservations(text, jsonb, text)
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
$$;

grant execute on function public.complete_flex_printing_stage(text, text, text, text, jsonb, text, text, text)
to authenticated, anon;
