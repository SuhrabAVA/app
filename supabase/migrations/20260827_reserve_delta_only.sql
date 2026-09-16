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
