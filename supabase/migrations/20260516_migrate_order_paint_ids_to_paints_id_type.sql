-- Safely align order paint references with the real public.paints.id type.
-- Existing installations that created paint_id as text are migrated only when
-- public.paints.id is uuid; invalid legacy ids are preserved as name-only rows
-- with the original text kept in paint_id_text_legacy.

do $$
declare
  v_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_paint_id_type is null then
    raise exception 'public.paints.id column was not found';
  end if;

  execute 'drop function if exists public.safe_paint_id(text)';
  if v_paint_id_type = 'uuid' then
    execute $sql$
      create function public.safe_paint_id(p_value text)
      returns uuid
      language sql
      immutable
      as $fn$
        select case
          when nullif(trim(p_value), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then nullif(trim(p_value), '')::uuid
          else null
        end
      $fn$
    $sql$;
  else
    execute format($sql$
      create function public.safe_paint_id(p_value text)
      returns %1$s
      language sql
      immutable
      as $fn$
        select nullif(trim(p_value), '')::%1$s
      $fn$
    $sql$, v_paint_id_type);
  end if;
end $$;

do $$
declare
  v_table text;
  v_existing_type text;
  v_paint_id_type text;
  v_invalid_count bigint;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_paint_id_type <> 'uuid' then
    return;
  end if;

  for v_table in
    select unnest(array['order_paint_reservations', 'order_paint_pending_writeoffs'])
  loop
    select format_type(a.atttypid, a.atttypmod)
      into v_existing_type
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = v_table
       and a.attname = 'paint_id'
       and a.attnum > 0
       and not a.attisdropped;

    if v_existing_type = 'text' then
      execute format('alter table public.%I add column if not exists paint_id_uuid uuid', v_table);

      execute format($sql$
        update public.%1$I
           set paint_id_uuid = public.safe_paint_id(paint_id)
         where paint_id is not null
           and paint_id_uuid is null
           and public.safe_paint_id(paint_id) is not null
      $sql$, v_table);

      execute format($sql$
        update public.%1$I
           set paint_name = coalesce(nullif(trim(paint_name), ''), paint_id)
         where paint_id is not null
           and public.safe_paint_id(paint_id) is null
      $sql$, v_table);

      execute format(
        'select count(*) from public.%I where paint_id is not null and public.safe_paint_id(paint_id) is null',
        v_table
      ) into v_invalid_count;
      if v_invalid_count > 0 then
        raise warning '%.paint_id contains % non-uuid legacy value(s); preserving them in paint_id_text_legacy and keeping rows name-only.',
          v_table, v_invalid_count;
      end if;

      for v_existing_type in
        select conname
          from pg_constraint
         where conrelid = format('public.%I', v_table)::regclass
           and conname like format('%s%%paint_id%%fkey', v_table)
      loop
        execute format('alter table public.%I drop constraint if exists %I', v_table, v_existing_type);
      end loop;

      if v_table = 'order_paint_reservations' then
        alter table public.order_paint_reservations
          drop constraint if exists order_paint_reservations_has_paint;
        drop index if exists public.order_paint_reservations_order_paint_idx;
        drop index if exists public.order_paint_reservations_paint_idx;
      else
        alter table public.order_paint_pending_writeoffs
          drop constraint if exists order_paint_pending_writeoffs_has_paint;
        drop index if exists public.order_paint_pending_writeoffs_status_paint_idx;
        drop index if exists public.order_paint_pending_writeoffs_order_stage_paint_pending_uidx;
        drop index if exists public.order_paint_pending_writeoffs_order_stage_paint_name_pending_uidx;
      end if;

      execute format('alter table public.%I rename column paint_id to paint_id_text_legacy', v_table);
      execute format('alter table public.%I rename column paint_id_uuid to paint_id', v_table);
      execute format(
        'alter table public.%I add constraint %I foreign key (paint_id) references public.paints(id)',
        v_table,
        v_table || '_paint_id_fkey'
      );

      if v_table = 'order_paint_reservations' then
        alter table public.order_paint_reservations
          add constraint order_paint_reservations_has_paint check (
            paint_id is not null or coalesce(trim(paint_name), '') <> ''
          );
      else
        alter table public.order_paint_pending_writeoffs
          add constraint order_paint_pending_writeoffs_has_paint check (
            paint_id is not null or coalesce(trim(paint_name), '') <> ''
          );
      end if;
    end if;
  end loop;
end $$;

create unique index if not exists order_paint_reservations_order_paint_idx
  on public.order_paint_reservations(order_id, paint_id)
  where paint_id is not null;

create index if not exists order_paint_reservations_paint_idx
  on public.order_paint_reservations(paint_id);

create index if not exists order_paint_pending_writeoffs_status_paint_idx
  on public.order_paint_pending_writeoffs(status, paint_id);

create unique index if not exists order_paint_pending_writeoffs_order_stage_paint_pending_uidx
  on public.order_paint_pending_writeoffs(
    order_id,
    coalesce(task_id, ''),
    coalesce(stage_id, ''),
    paint_id
  )
  where status = 'pending' and paint_id is not null;

create unique index if not exists order_paint_pending_writeoffs_order_stage_paint_name_pending_uidx
  on public.order_paint_pending_writeoffs(
    order_id,
    coalesce(task_id, ''),
    coalesce(stage_id, ''),
    lower(trim(paint_name))
  )
  where status = 'pending'
    and paint_id is null
    and coalesce(trim(paint_name), '') <> '';

-- Refresh paint RPCs on already-migrated installations. Historical migrations above were
-- edited for fresh installs, but existing databases only execute this migration.
-- Атомарные резервы и списание красок для заказов/флексопечати.

alter table if exists public.paints
  add column if not exists reserved_qty double precision not null default 0;

do $$
declare
  v_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_paint_id_type is null then
    raise exception 'public.paints.id column was not found';
  end if;

  execute format($sql$
    create table if not exists public.order_paint_reservations (
      id uuid primary key default gen_random_uuid(),
      order_id text not null references public.orders(id) on delete cascade,
      paint_id %1$s references public.paints(id),
      paint_name text,
      reserved_qty double precision not null default 0,
      used_qty double precision not null default 0,
      released_qty double precision not null default 0,
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now(),
      constraint order_paint_reservations_qty_nonnegative check (
        reserved_qty >= 0 and used_qty >= 0 and released_qty >= 0
      ),
      constraint order_paint_reservations_has_paint check (
        paint_id is not null or coalesce(trim(paint_name), '') <> ''
      )
    )
  $sql$, v_paint_id_type);
end $$;

do $$
declare
  v_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  execute 'drop function if exists public.safe_paint_id(text)';
  if v_paint_id_type = 'uuid' then
    execute $sql$
      create function public.safe_paint_id(p_value text)
      returns uuid
      language sql
      immutable
      as $fn$
        select case
          when nullif(trim(p_value), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then nullif(trim(p_value), '')::uuid
          else null
        end
      $fn$
    $sql$;
  else
    execute format($sql$
      create function public.safe_paint_id(p_value text)
      returns %1$s
      language sql
      immutable
      as $fn$
        select nullif(trim(p_value), '')::%1$s
      $fn$
    $sql$, v_paint_id_type);
  end if;
end $$;

create unique index if not exists order_paint_reservations_order_paint_idx
  on public.order_paint_reservations(order_id, paint_id)
  where paint_id is not null;

create unique index if not exists order_paint_reservations_order_paint_name_idx
  on public.order_paint_reservations(order_id, lower(trim(paint_name)))
  where paint_id is null and coalesce(trim(paint_name), '') <> '';

create index if not exists order_paint_reservations_paint_idx
  on public.order_paint_reservations(paint_id);

create index if not exists order_paint_reservations_order_idx
  on public.order_paint_reservations(order_id);

alter table public.order_paint_reservations enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paint_reservations' and policyname='order_paint_reservations_select'
  ) then
    create policy order_paint_reservations_select on public.order_paint_reservations
      for select to authenticated, anon using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paint_reservations' and policyname='order_paint_reservations_write'
  ) then
    create policy order_paint_reservations_write on public.order_paint_reservations
      for all to authenticated using (true) with check (true);
  end if;
end $$;

do $$
declare
  v_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  execute 'drop function if exists public.recalculate_paint_reserved_qty(' || v_paint_id_type || '[])';
  execute format($sql$
    create function public.recalculate_paint_reserved_qty(p_paint_ids %1$s[] default null)
    returns void
    language plpgsql
    security definer
    set search_path = public
    as $fn$
    begin
      if p_paint_ids is null then
        update paints p
           set reserved_qty = coalesce((
                 select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
                   from order_paint_reservations r
                  where r.paint_id = p.id
               ), 0);
      else
        update paints p
           set reserved_qty = coalesce((
                 select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
                   from order_paint_reservations r
                  where r.paint_id = p.id
               ), 0)
         where p.id = any(p_paint_ids);
      end if;
    end;
    $fn$
  $sql$, v_paint_id_type);
end $$;

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
  v_touched public.paints.id%type[] := '{}';
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

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
    for update of p
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя зарезервировать отрицательное количество краски (%).', coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
    end if;

    if rec.paint_id is null or rec.total_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id <> p_order_id;

    v_available := rec.total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paint_name := coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
      raise exception 'Недостаточно краски: %. Доступно: %, требуется: %',
        v_paint_name, round(v_available::numeric, 2), round(rec.qty::numeric, 2);
    end if;

    v_touched := array_append(v_touched, rec.paint_id);
  end loop;

  v_touched := v_touched || array(
    select distinct paint_id
      from order_paint_reservations
     where order_id = p_order_id and paint_id is not null
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
       where order_id = p_order_id and paint_id = rec.paint_id;
    else
      insert into order_paint_reservations(order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (p_order_id, rec.paint_id, rec.paint_name, rec.qty, 0, 0)
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
   where r.order_id = p_order_id
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

create or replace function public.release_order_paint_reservations(
  p_order_id text,
  p_reason text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_touched public.paints.id%type[];
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  select array_agg(distinct paint_id) into v_touched
    from order_paint_reservations
   where order_id = p_order_id and paint_id is not null;

  update order_paint_reservations
     set released_qty = greatest(reserved_qty - used_qty, 0),
         updated_at = now()
   where order_id = p_order_id;

  perform recalculate_paint_reserved_qty(v_touched);
end;
$$;

grant execute on function public.release_order_paint_reservations(text, text, text)
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
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_comments jsonb;
  v_touched public.paints.id%type[] := '{}';
begin
  if coalesce(trim(p_task_id), '') = '' then raise exception 'task_id is required'; end if;
  if coalesce(trim(p_order_id), '') = '' then raise exception 'order_id is required'; end if;
  if p_paint_usages is null then p_paint_usages := '[]'::jsonb; end if;

  perform 1 from tasks where id = p_task_id and order_id = p_order_id for update;
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
    for update of p
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя списать отрицательное количество краски (%).', coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
    end if;
    if rec.qty = 0 then
      continue;
    end if;
    if rec.paint_id is null or rec.total_qty is null then
      raise exception 'Краска % не найдена на складе.', coalesce(rec.paint_name, rec.paint_id::text);
    end if;

    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_other
      from order_paint_reservations r
     where r.paint_id = rec.paint_id
       and r.order_id <> p_order_id;

    v_available := rec.total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paint_name := coalesce(rec.stock_name, rec.paint_name, rec.paint_id::text);
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

  select coalesce(comments::jsonb, '[]'::jsonb) into v_comments
    from tasks
   where id = p_task_id
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
   where id = p_task_id;

  update tasks
     set status = 'completed', started_at = null
   where order_id = p_order_id
     and stage_id = p_stage_id
     and id <> p_task_id
     and status <> 'completed';
end;
$$;

grant execute on function public.complete_flex_printing_stage(text, text, text, text, jsonb, text, text, text)
to authenticated, anon;

-- Refresh queued flex-printing RPC with paint ids typed as public.paints.id.
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
       and r.order_id <> v_source_order_id;
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
     where order_id = v_source_order_id and paint_id = v_paint_id;
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
       and r.order_id <> v_source_order_id;
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
     where order_id = v_source_order_id and paint_id = v_paint_id;
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
     where order_id = p_order_id
       and greatest(reserved_qty - used_qty - released_qty, 0) > 0
     for update
  loop
    update order_paint_reservations
       set released_qty = greatest(reserved_qty - used_qty, 0),
           updated_at = now()
     where order_id = p_order_id and paint_id = rec.paint_id;
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
   where id = p_task_id;

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
