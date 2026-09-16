-- Неприкасаемый запас краски: 5 кг на каждой краске (2026-09-08).
--
-- Склад обязан всегда держать по 5000 г каждой краски. Этот запас не
-- принадлежит ни одному заказу и в бронь не отдаётся. Вычитается он ОДИН РАЗ
-- из складского остатка, а не по 5 кг с каждого заказа: сколько бы заказов
-- краску ни просило, неприкасаемым остаётся один и тот же хвост.
--
-- Тело функции взято из 20260827_paint_reserve_delta_only.sql без изменений,
-- кроме трёх мест: объявление v_untouchable, вычет запаса в v_available и
-- текст ошибки, который теперь называет запас явно — иначе снабженец видит
-- «свободно 0» при складе в 4 кг и считает это враньём.
--
-- Чего миграция НЕ делает и почему:
--   * не трогает уже созданные брони. Проверка стоит под `if v_delta > 0`,
--     то есть срабатывает только на РОСТ потребности. Запущенные заказы,
--     набравшие бронь до этой миграции, продолжают работать: отбирать у них
--     краску задним числом нельзя. Запас восстанавливается естественно — на
--     следующем заказе, которому эта краска понадобится, проверка не пройдёт,
--     и сотрудник пополнит склад.
--   * не запрещает производственное списание. Краску, которую печатник уже
--     израсходовал, запретом не вернуть, а остановленный на нуле цех хуже
--     просевшего запаса. Списание идёт своим путём
--     (complete_flex_printing_stage_with_paint_queue) и этой функции не
--     касается. Ручное списание со склада ограничено на клиенте
--     (type_table_tabs_screen._writeOff).
--
-- Клиентская сторона правила — lib/modules/warehouse/paint_stock_rules.dart
-- (kUntouchablePaintGrams, availablePaintGrams) с тестами. Значения обязаны
-- совпадать: разойдутся — и заказ, прошедший проверку в форме, упадёт на
-- сохранении брони.

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
