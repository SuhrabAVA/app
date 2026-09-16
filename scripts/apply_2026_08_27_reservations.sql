-- Применить в Supabase SQL Editor одним запуском.
-- Две функции: бронь бумаги и бронь красок проверяются по разнице.
-- Схему не меняет, применяется на живой базе.

-- Резерв бумаги проверяется по разнице, а не по всей потребности (2026-08-27).
--
-- ЗАЧЕМ
-- sync_order_paper_reservations проверяла доступный остаток для КАЖДОЙ
-- запрошенной строки, даже когда метраж не менялся или уменьшался:
--
--   v_available := v_total_qty - v_reserved_other;   -- чужие брони
--   if v_available < rec.qty then raise ...
--
-- Для заказа, у которого уже есть бронь на 1700 м, перезапись тех же 1700 м
-- требовала, чтобы 1700 м нашлись в остатке заново. Пока чужие брони были
-- невелики, проверка проходила незаметно; когда склад разобрали под другие
-- заказы — обычное сохранение запущенного заказа начинало падать, а клиент
-- вдобавок считал заказ необеспеченным и выкидывал его из производства
-- в «Ожидание материалов» (ЗК-2026.08.21-5, 27.08.2026: собственная бронь
-- 1700 м, «доступно 1439.76, не хватает 260.24» — все 1700 недостающих метров
-- были его же собственными).
--
-- ПРАВИЛО
-- Бронь — не расход, а обещание склада конкретному заказу. Значит проверять
-- надо только прирост:
--   * метраж не изменился — не проверяем ничего;
--   * метраж уменьшился  — не проверяем ничего, лишнее возвращается на склад;
--   * метраж вырос       — проверяем, что прирост есть в свободном остатке.
--
-- Само сравнение остаётся прежним (v_available < rec.qty), и это не описка:
-- v_available считается БЕЗ собственной брони заказа, поэтому «хватает на всю
-- потребность» здесь арифметически тождественно «хватает на прирост». Новое —
-- условие входа в проверку: она выполняется только при росте.
--
-- ЧТО НЕ МЕНЯЕТСЯ
-- Upsert и удаление неактуальных строк остаются как были: уменьшение метража
-- само освобождает лишнее (qty = excluded.qty), а исчезнувшая из состава
-- бумага удаляется целиком. Списания склада функция по-прежнему не делает —
-- за это отвечает finalize_order_paper_reservations при отгрузке.

create or replace function public.sync_order_paper_reservations(
  p_order_id text,
  p_reservations jsonb default '[]'::jsonb,
  p_actor text default null::text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec record;
  v_order_id      order_paper_reservations.order_id%type;
  v_paper_id      order_paper_reservations.paper_id%type;
  v_total_qty     double precision;
  v_available     double precision;
  v_reserved_other double precision;
  v_reserved_self double precision;
  v_delta         double precision;
  v_paper_name    text;
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

    -- Сколько этот заказ уже держит по этой бумаге.
    select coalesce(sum(r.qty), 0)
      into v_reserved_self
      from order_paper_reservations r
     where r.paper_id = v_paper_id
       and r.order_id = v_order_id;

    v_delta := rec.qty - v_reserved_self;

    -- Не выросло — проверять нечего: заказ либо оставляет свою бронь как есть,
    -- либо возвращает часть её на склад.
    if v_delta <= 0 then
      continue;
    end if;

    select coalesce(sum(r.qty), 0)
      into v_reserved_other
      from order_paper_reservations r
     where r.paper_id = v_paper_id
       and r.order_id <> v_order_id;

    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paper_name := coalesce(v_paper_name, rec.paper_id);
      raise exception
        'Не хватает бумаги "%": нужно добавить % м к уже забронированным % м, а свободно всего % м.',
        v_paper_name,
        round(v_delta::numeric, 2),
        round(v_reserved_self::numeric, 2),
        round(greatest(v_available - v_reserved_self, 0)::numeric, 2);
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
$function$;

comment on function public.sync_order_paper_reservations(text, jsonb, text) is
  'Приводит бронь бумаги заказа к переданному составу. Наличие остатка '
  'проверяется только на прирост брони: без изменений и при уменьшении '
  'проверки нет, лишнее возвращается на склад. Списаний не делает.';


-- Бронь краски проверяется по разнице, как и бронь бумаги (2026-08-27).
--
-- Парная миграция к 20260827_reserve_delta_only.sql. sync_order_paint_reservations
-- страдала тем же: доступность проверялась для всей запрошенной массы, даже
-- когда она не менялась или уменьшалась. Заказ с бронью 500 г не мог быть
-- сохранён повторно, если остальную краску тем временем разобрали под другие
-- заказы — он не проходил проверку по собственной же брони.
--
-- Правило то же, что и у бумаги:
--   * масса не изменилась — не проверяем ничего;
--   * масса уменьшилась  — не проверяем ничего, лишнее возвращается на склад;
--   * масса выросла      — проверяем, что прирост есть в свободном остатке.
--
-- Тело функции взято из текущего состояния базы без изменений, кроме блока
-- проверки: upsert, пересчёт paints.reserved_qty и удаление неактуальных
-- строк остаются прежними. Списаний краски функция не делает — за это
-- отвечает complete_flex_printing_stage_with_paint_queue при завершении
-- флексопечати.

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

      v_available := v_total_qty - v_reserved_other;
      if v_available < rec.qty then
        v_paint_name := coalesce(v_stock_name, rec.stock_name, rec.paint_name, rec.paint_id::text);
        raise exception
          'Не хватает краски "%": нужно добавить % г к уже забронированным % г, а свободно всего % г.',
          v_paint_name,
          round(v_delta::numeric, 2),
          round(v_reserved_self::numeric, 2),
          round(greatest(v_available - v_reserved_self, 0)::numeric, 2);
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
