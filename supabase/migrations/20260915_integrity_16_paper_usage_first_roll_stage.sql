-- ============================================================================
-- Целостность данных, шаг 16: бумага списывается по факту на ПЕРВОМ рулонном
-- этапе (2026-09-15)
--
-- Что было
-- --------
-- С 14.09 бумага списывалась автоматически после ПОСЛЕДНЕГО рулонного этапа
-- (Бабинорезка → Флексопечать → списание после Флексопечати) и ровно в
-- размере брони — плановой «Длины L». Рулон режут на Бабинорезке и уносят со
-- склада, а в системе метры неделю числятся на складе в брони: на 15.09 так
-- «висело» 14 400 м одного только «китс 7», и кладовщик подбирал остаток
-- вручную, чтобы «Кол-во» совпало с полкой.
--
-- Новое правило (решение от 15.09)
-- --------------------------------
-- * Этап бумаги — ПЕРВЫЙ по маршруту из Бабинорезки/Флексопечати; без них —
--   первый шаг маршрута; без маршрута — завершение заказа (как раньше).
-- * На этом этапе каждый исполнитель и каждая смена (пересмена, «Завершить
--   участие», закрытие этапа) пишут фактический расход по каждой бумаге.
--   Записанное сразу списывается со склада и уменьшает бронь заказа.
-- * Записать больше, чем есть на складе для заказа (остаток минус брони
--   других заказов), нельзя: действие не проходит, пока склад не пополнят.
-- * При закрытии этапа остаток брони возвращается на склад, а «Длина L»
--   каждой бумаги в заказе становится равной списанному итогу.
-- * Старые сборки окна расхода не показывают. Если к закрытию этапа расхода
--   не записано вовсе, списывается бронь — как раньше, ничего не теряется.
--
-- Досписание
-- ----------
-- Заказы, у которых первый рулонный этап уже закрыт, а бумага не списана:
-- реальная бумага — по брони (введённое на этапе количество с ней совпадает,
-- у двух заказов с несколькими бумагами — по брони каждой бумаги); заказы на
-- «Тестовой бумаге» — только снимается бронь, со склада ничего не уходит.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Трассировка списания до задачи этапа и защита от повторной отправки
-- ----------------------------------------------------------------------------
alter table public.papers_writeoffs
  add column if not exists task_id text,
  add column if not exists request_id uuid;

comment on column public.papers_writeoffs.task_id is
  'Задача этапа, на котором сотрудник записал расход (record_order_paper_usage). '
  'Непустой task_id = расход записан по факту, а не списан по брони.';
comment on column public.papers_writeoffs.request_id is
  'Ключ отправки окна расхода: повтор того же запроса ничего не списывает.';

create unique index if not exists papers_writeoffs_request_paper_uidx
  on public.papers_writeoffs(request_id, paper_id)
  where request_id is not null;

create index if not exists papers_writeoffs_order_idx
  on public.papers_writeoffs(order_id)
  where order_id is not null;

-- ----------------------------------------------------------------------------
-- 2. Этап бумаги — первый рулонный
-- ----------------------------------------------------------------------------
create or replace function public.order_paper_writeoff_stage_key(p_order_id text)
returns text
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  -- Рабочие места берутся по id, а не по имени: имя менеджер может
  -- переименовать в справочнике, id — нет. Те же значения объявлены в
  -- lib/modules/orders/production_ids.dart.
  c_bobbin constant text := 'b92a89d1-8e95-4c6d-b990-e308486e4bf1'; -- Бабинорезка
  c_flexo  constant text := '0571c01c-f086-47e4-81b2-5d8b2ab91218'; -- Флексопечать
  v_key text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    return null;
  end if;

  -- Порядок маршрута несёт step_no; seq — уникальный ключ строки и держит
  -- стабильный порядок внутри шага.
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
     and s.stage_id in (c_bobbin, c_flexo)
   order by s.step_no nulls last, s.seq nulls last, s.created_at
   limit 1;

  if v_key is not null then
    return v_key;
  end if;

  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
   order by s.step_no nulls last, s.seq nulls last, s.created_at
   limit 1;

  return v_key;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 3. Бумага заказа по слотам: план, списано, бронь, свободно
-- ----------------------------------------------------------------------------
create or replace function public.order_paper_slots(p_order_id text)
returns table (
  slot_index int,
  paper_id uuid,
  plan_qty numeric
)
language sql
stable security definer
set search_path to 'public'
as $function$
  -- Слот 0 — «Бумага №1»: её длина живёт в product.length. Остальные — в
  -- extra.lengthL, запасной вариант — quantity. Так же читает карточка
  -- деталей заказа (order_details_card.dart, _paperLengthValue).
  with o as (
    select o.*
      from public.orders o
     where o.id::text = p_order_id
  ),
  slots as (
    select case
             when jsonb_typeof(o.material_list) = 'array' and jsonb_array_length(o.material_list) > 0
               then o.material_list
             when jsonb_typeof(o.material) = 'object'
               then jsonb_build_array(o.material)
             else '[]'::jsonb
           end as items,
           o.product
      from o
  )
  select (e.ord - 1)::int as slot_index,
         case when e.value->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then (e.value->>'id')::uuid end as paper_id,
         greatest(coalesce(
           case when e.ord = 1 then nullif(public.task_quantity_value(s.product->>'length'), 0) end,
           nullif(public.task_quantity_value(e.value->'extra'->>'lengthL'), 0),
           nullif(public.task_quantity_value(e.value->>'quantity'), 0),
           0
         ), 0)::numeric as plan_qty
    from slots s
    cross join lateral jsonb_array_elements(s.items) with ordinality as e(value, ord);
$function$;

create or replace function public.order_paper_usage_state(p_order_id text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_papers jsonb;
begin
  select * into v_order from public.orders where id::text = p_order_id;
  if not found then
    return null;
  end if;

  with slots as (
    select * from public.order_paper_slots(p_order_id)
  ),
  written as (
    select w.paper_id, sum(w.qty) as qty,
           sum(w.qty) filter (where w.task_id is not null) as by_fact
      from public.papers_writeoffs w
     where w.order_id = v_order.id
       and w.canceled_at is null
     group by w.paper_id
  ),
  first_slot as (
    -- Одна и та же бумага в двух слотах: списанное относим к первому.
    select paper_id, min(slot_index) as slot_index from slots where paper_id is not null group by paper_id
  ),
  rows as (
    select s.slot_index, s.paper_id, s.plan_qty,
           case when fs.slot_index = s.slot_index then coalesce(w.qty, 0) else 0 end as written,
           true as in_order
      from slots s
      left join first_slot fs on fs.paper_id = s.paper_id
      left join written w on w.paper_id = s.paper_id
    union all
    -- Бумага, которую уже списали, но в заказе её больше нет.
    select 1000 + row_number() over (order by w.paper_id)::int, w.paper_id, 0, w.qty, false
      from written w
     where not exists (select 1 from slots s where s.paper_id = w.paper_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'slot_index', r.slot_index,
           'paper_id', r.paper_id,
           'name', p.description,
           'format', p.format,
           'grammage', p.grammage,
           'unit', coalesce(nullif(p.unit, ''), 'м'),
           'in_order', r.in_order,
           'plan', round(r.plan_qty, 3),
           'written', round(r.written, 3),
           'remaining', round(greatest(r.plan_qty - r.written, 0), 3),
           'reserved', round(coalesce((select sum(x.qty) from public.order_paper_reservations x
                                        where x.order_id = v_order.id and x.paper_id = r.paper_id), 0)::numeric, 3),
           'stock', round(coalesce(p.quantity, 0), 3),
           'available_for_order', round(greatest(coalesce(p.quantity, 0) - coalesce((
                select sum(x.qty) from public.order_paper_reservations x
                 where x.paper_id = r.paper_id and x.order_id <> v_order.id), 0)::numeric, 0), 3)
         ) order by r.slot_index), '[]'::jsonb)
    into v_papers
    from rows r
    left join public.papers p on p.id = r.paper_id;

  return jsonb_build_object(
    'order_id', v_order.id,
    'stage_key', public.order_paper_writeoff_stage_key(p_order_id),
    'closed', v_order.paper_written_off_at is not null,
    'has_fact_usage', exists (select 1 from public.papers_writeoffs w
                               where w.order_id = v_order.id and w.canceled_at is null and w.task_id is not null),
    'papers', v_papers
  );
end;
$function$;

-- ----------------------------------------------------------------------------
-- 4. Запись фактического расхода сотрудником
-- ----------------------------------------------------------------------------
create or replace function public.record_order_paper_usage(
  p_order_id text,
  p_task_id text,
  p_rows jsonb,
  p_kind text default 'finish',
  p_request_id uuid default null,
  p_actor text default null,
  p_employee_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_task record;
  v_stage_key text;
  v_label text;
  v_employee text;
  v_paper record;
  v_reserved_other numeric;
  v_available numeric;
  rec record;
begin
  if coalesce(p_kind, '') not in ('shift', 'participant', 'finish') then
    raise exception 'Неизвестный вид записи расхода бумаги: %', p_kind;
  end if;

  -- Блокировка заказа: две смены, отправившие расход одновременно, иначе обе
  -- прошли бы проверку остатка по одним и тем же метрам.
  select * into v_order from public.orders where id::text = p_order_id for update;
  if not found then
    raise exception 'Заказ % не найден.', p_order_id;
  end if;

  if p_request_id is not null
     and exists (select 1 from public.papers_writeoffs w where w.request_id = p_request_id) then
    return jsonb_build_object('duplicate', true, 'state', public.order_paper_usage_state(p_order_id));
  end if;

  select t.id, t.order_id, t.stage_id, t.stage_group_key into v_task
    from public.tasks t
   where t.id::text = p_task_id;
  if not found or v_task.order_id::text <> v_order.id::text then
    raise exception 'Задача этапа не найдена в заказе.';
  end if;

  v_stage_key := public.order_paper_writeoff_stage_key(p_order_id);
  if v_stage_key is null
     or (v_stage_key <> coalesce(nullif(v_task.stage_group_key, ''), v_task.stage_id)
         and v_stage_key <> v_task.stage_id) then
    raise exception using
      errcode = 'check_violation',
      message = 'Расход бумаги записывается только на первом рулонном этапе заказа.';
  end if;

  v_label := coalesce(nullif(btrim(v_order.customer), ''), v_order.assignment_id, p_order_id);
  select e.id into v_employee from public.employees e where e.id = nullif(trim(p_employee_id), '');

  for rec in
    select nullif(trim(value->>'paper_id'), '') as paper_id,
           sum(coalesce(public.task_quantity_value(value->>'qty'), 0))::numeric as qty
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
     group by 1
     order by 1
  loop
    if rec.paper_id is null then
      continue;
    end if;
    if rec.qty < 0 then
      raise exception using errcode = 'check_violation', message = 'Расход бумаги не может быть отрицательным.';
    end if;
    if rec.qty = 0 then
      continue;
    end if;

    select p.id, p.description, p.format, p.grammage, p.quantity
      into v_paper
      from public.papers p
     where p.id::text = rec.paper_id
     for update;
    if not found then
      raise exception 'Бумага % не найдена на складе.', rec.paper_id;
    end if;

    select coalesce(sum(r.qty), 0) into v_reserved_other
      from public.order_paper_reservations r
     where r.paper_id = v_paper.id
       and r.order_id <> v_order.id;

    v_available := coalesce(v_paper.quantity, 0) - v_reserved_other;
    if rec.qty > v_available then
      raise exception using
        errcode = 'check_violation',
        message = format(
          'Не хватает бумаги «%s»: для заказа на складе %s м, а записан расход %s м. '
          'Сохранить нельзя, пока склад не пополнят (приход или инвентаризация).',
          concat_ws(' ', v_paper.description, nullif(concat_ws('/', v_paper.format, v_paper.grammage), '')),
          round(greatest(v_available, 0), 2),
          round(rec.qty, 2));
    end if;

    insert into public.papers_writeoffs(
      paper_id, qty, reason, by_name, order_id, source, employee_id, task_id, request_id
    ) values (
      v_paper.id,
      rec.qty,
      format('Расход бумаги на этапе по заказу %s', v_label),
      coalesce(nullif(trim(p_actor), ''), 'system'),
      v_order.id,
      'paper_stage',
      v_employee,
      p_task_id,
      p_request_id
    );

    update public.order_paper_reservations
       set qty = qty - rec.qty, updated_at = now()
     where order_id = v_order.id and paper_id = v_paper.id;
    delete from public.order_paper_reservations
     where order_id = v_order.id and paper_id = v_paper.id and qty <= 0.0001;
  end loop;

  return jsonb_build_object('duplicate', false, 'state', public.order_paper_usage_state(p_order_id));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Длина L в заказе = списанный по факту итог
-- ----------------------------------------------------------------------------
create or replace function public.order_paper_apply_fact_lengths(p_order_id text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_totals jsonb;
  v_list jsonb;
  v_first jsonb;
  v_first_total numeric;
begin
  select * into v_order from public.orders where id::text = p_order_id for update;
  if not found then
    return;
  end if;

  select coalesce(jsonb_object_agg(w.paper_id::text, w.qty), '{}'::jsonb)
    into v_totals
    from (
      select paper_id, sum(qty) as qty
        from public.papers_writeoffs
       where order_id = v_order.id and canceled_at is null
       group by paper_id
    ) w;

  -- Бумага в двух слотах сразу: итог не разделить — такой слот не трогаем.
  if jsonb_typeof(v_order.material_list) = 'array' and jsonb_array_length(v_order.material_list) > 0 then
    select jsonb_agg(
             case
               when (select count(*) from jsonb_array_elements(v_order.material_list) d
                      where d->>'id' = e.value->>'id') = 1
                 then e.value
                      || jsonb_build_object('quantity', coalesce((v_totals->>(e.value->>'id'))::numeric, 0))
                      || case when e.ord = 1 then '{}'::jsonb
                              else jsonb_build_object('extra',
                                     coalesce(case when jsonb_typeof(e.value->'extra') = 'object' then e.value->'extra' end, '{}'::jsonb)
                                     || jsonb_build_object('lengthL', coalesce((v_totals->>(e.value->>'id'))::numeric, 0)))
                         end
               else e.value
             end
             order by e.ord)
      into v_list
      from jsonb_array_elements(v_order.material_list) with ordinality as e(value, ord);
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
         material = case
                      when v_first is not null and jsonb_typeof(material) = 'object'
                           and material->>'id' = v_first->>'id'
                        then material || jsonb_build_object('quantity', coalesce(v_first_total, 0))
                      else material
                    end,
         product = case
                     when v_first is not null and jsonb_typeof(product) = 'object'
                       then product || jsonb_build_object('length', coalesce(v_first_total, 0))
                     else product
                   end
   where id = v_order.id;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 6. Закрытие этапа бумаги
-- ----------------------------------------------------------------------------
create or replace function public.finalize_order_paper_reservations(p_order_id text, p_actor text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec record;
  v_order_id order_paper_reservations.order_id%type;
  v_already timestamptz;
  v_label text;
  v_reason text;
  v_shipped timestamptz;
  v_source text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := p_order_id;

  select o.paper_written_off_at, nullif(btrim(o.customer), ''), o.shipped_at
    into v_already, v_label, v_shipped
    from public.orders o
   where o.id::text = p_order_id;

  -- Расход записан сотрудниками по факту (record_order_paper_usage): со склада
  -- уже ушло ровно записанное. Остаток брони возвращается, длина в заказе
  -- становится итогом. Повторное закрытие (после «Возобновить» этапа)
  -- пересчитывает итог заново.
  if exists (select 1 from public.papers_writeoffs w
              where w.order_id = v_order_id and w.canceled_at is null and w.task_id is not null) then
    delete from public.order_paper_reservations where order_id = v_order_id;
    perform public.order_paper_apply_fact_lengths(p_order_id);
    update public.orders
       set paper_written_off_at = coalesce(paper_written_off_at, now())
     where id::text = p_order_id;
    return;
  end if;

  -- Уже списывали. Бронь, которую мог заново создать клиент при правке заказа,
  -- просто снимаем: метры давно ушли со склада, держать их незачем.
  if v_already is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;

  -- Расхода по факту нет (старая сборка без окна расхода, заказ без
  -- маршрута): списываем бронь, как раньше.
  v_reason := format('Списание бумаги по заказу %s', coalesce(v_label, p_order_id));

  v_source := case
    when exists (select 1 from public.tasks t
                  where t.order_id::text = p_order_id and t.status <> 'completed')
      then 'paper_stage'
    when v_shipped is not null then 'paper_shipment'
    else 'paper_order_completed'
  end;

  for rec in
    select r.paper_id, r.qty
    from public.order_paper_reservations r
    where r.order_id = v_order_id
    for update
  loop
    if rec.qty <= 0 then
      continue;
    end if;

    insert into public.papers_writeoffs(paper_id, qty, reason, by_name, order_id, source)
    values (
      rec.paper_id,
      rec.qty,
      v_reason,
      coalesce(nullif(trim(p_actor), ''), 'system'),
      v_order_id,
      v_source
    );
  end loop;

  update public.orders
     set paper_written_off_at = now()
   where id::text = p_order_id;

  delete from public.order_paper_reservations where order_id = v_order_id;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 7. Бронь бумаги не держит уже списанные метры
-- ----------------------------------------------------------------------------
create or replace function public.sync_order_paper_reservations(p_order_id text, p_reservations jsonb default '[]'::jsonb, p_actor text default null)
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
  v_written_off   timestamptz;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  if p_reservations is null then
    p_reservations := '[]'::jsonb;
  end if;

  v_order_id := p_order_id;

  -- Бумага заказа уже списана на своём этапе. Любая правка заказа после этого
  -- не должна снова занимать метры.
  select o.paper_written_off_at into v_written_off
    from public.orders o
   where o.id::text = p_order_id;

  if v_written_off is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;

  -- Бронь = план минус уже списанное по заказу (расход смен на этапе бумаги).
  create temporary table if not exists _paper_reservation_request(
    paper_id uuid primary key,
    qty double precision not null
  ) on commit drop;
  truncate _paper_reservation_request;

  insert into _paper_reservation_request(paper_id, qty)
  select q.paper_id,
         greatest(q.qty - coalesce((select sum(w.qty) from public.papers_writeoffs w
                                     where w.order_id = v_order_id and w.paper_id = q.paper_id
                                       and w.canceled_at is null), 0), 0)
    from (
      select nullif(trim(value->>'paper_id'), '')::uuid as paper_id,
             sum(coalesce(nullif(value->>'qty', '')::double precision, 0)) as qty
        from jsonb_array_elements(p_reservations)
       where nullif(trim(value->>'paper_id'), '') is not null
       group by 1
    ) q;

  for rec in select paper_id, qty from _paper_reservation_request order by paper_id loop
    v_paper_id := rec.paper_id;

    select p.quantity, p.description
      into v_total_qty, v_paper_name
      from public.papers p
     where p.id = v_paper_id
     for update;

    if rec.qty < 0 then
      raise exception 'Нельзя зарезервировать отрицательное количество бумаги (%).', rec.paper_id;
    end if;

    if v_total_qty is null then
      raise exception 'Бумага % не найдена на складе.', rec.paper_id;
    end if;

    select coalesce(sum(r.qty), 0)
      into v_reserved_self
      from public.order_paper_reservations r
     where r.paper_id = v_paper_id
       and r.order_id = v_order_id;

    v_delta := rec.qty - v_reserved_self;
    if v_delta <= 0 then
      continue;
    end if;

    select coalesce(sum(r.qty), 0)
      into v_reserved_other
      from public.order_paper_reservations r
     where r.paper_id = v_paper_id
       and r.order_id <> v_order_id;

    v_available := v_total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paper_name := coalesce(v_paper_name, rec.paper_id::text);
      raise exception
        'Не хватает бумаги "%": нужно добавить % м к уже забронированным % м, а свободно всего % м.',
        v_paper_name,
        round(v_delta::numeric, 2),
        round(v_reserved_self::numeric, 2),
        round(greatest(v_available - v_reserved_self, 0)::numeric, 2);
    end if;
  end loop;

  for rec in select paper_id, qty from _paper_reservation_request loop
    if rec.qty <= 0 then
      delete from public.order_paper_reservations
       where order_id = v_order_id and paper_id = rec.paper_id;
    else
      insert into public.order_paper_reservations(order_id, paper_id, qty)
      values (v_order_id, rec.paper_id, rec.qty)
      on conflict (order_id, paper_id)
      do update set qty = excluded.qty, updated_at = now();
    end if;
  end loop;

  delete from public.order_paper_reservations r
   where r.order_id = v_order_id
     and not exists (select 1 from _paper_reservation_request q
                      where q.paper_id = r.paper_id and q.qty > 0);
end;
$function$;

-- ----------------------------------------------------------------------------
-- 8. Права
-- ----------------------------------------------------------------------------
revoke execute on function public.order_paper_slots(text) from public, anon, authenticated;
revoke execute on function public.order_paper_apply_fact_lengths(text) from public, anon, authenticated;
revoke execute on function public.record_order_paper_usage(text, text, jsonb, text, uuid, text, text) from public, anon;
revoke execute on function public.order_paper_usage_state(text) from public, anon;
grant execute on function public.record_order_paper_usage(text, text, jsonb, text, uuid, text, text) to authenticated, service_role;
grant execute on function public.order_paper_usage_state(text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 9. Досписание заказов, прошедших первый рулонный этап
-- ----------------------------------------------------------------------------
do $backfill$
declare
  o record;
  r record;
  v_task record;
  v_actor text;
  v_employee text;
begin
  for o in
    select ord.id, ord.id::text as id_text,
           coalesce(nullif(btrim(ord.customer), ''), ord.assignment_id) as label,
           bool_and(p.description ilike 'Тестовая бумага%') as only_test
      from public.orders ord
      join public.order_paper_reservations res on res.order_id = ord.id
      join public.papers p on p.id = res.paper_id
     where ord.paper_written_off_at is null
       and public.order_paper_writeoff_stage_key(ord.id::text) is not null
       and not exists (
             select 1 from public.tasks t
              where t.order_id = ord.id
                and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = public.order_paper_writeoff_stage_key(ord.id::text)
                and t.status <> 'completed')
       and exists (
             select 1 from public.tasks t
              where t.order_id = ord.id
                and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = public.order_paper_writeoff_stage_key(ord.id::text))
     group by ord.id
  loop
    if o.only_test then
      delete from public.order_paper_reservations where order_id = o.id;
      update public.orders set paper_written_off_at = now() where id = o.id;
      continue;
    end if;

    -- Автор — тот, кто закрыл этап (последний user_done).
    select t.id::text as id,
           (select c->>'userId' from jsonb_array_elements(public.task_comments_to_array(t.comments)) c
             where c->>'type' = 'user_done'
             order by public.task_comment_millis(c->>'timestamp') desc limit 1) as user_id
      into v_task
      from public.tasks t
     where t.order_id = o.id
       and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = public.order_paper_writeoff_stage_key(o.id_text)
     order by t.completed_at desc nulls last
     limit 1;

    select e.id, nullif(trim(concat_ws(' ', e.last_name, e.first_name)), '')
      into v_employee, v_actor
      from public.employees e
     where e.id = v_task.user_id;

    for r in
      select res.paper_id, res.qty, p.quantity as stock
        from public.order_paper_reservations res
        join public.papers p on p.id = res.paper_id
       where res.order_id = o.id and res.qty > 0
    loop
      -- Остатка меньше, чем бронь: кладовщик уже вывел эту бумагу в ноль
      -- инвентаризацией (ВП 84/40, китс 10 36/50 на 15.09). Списание дало бы
      -- вторую недостачу на те же метры — бронь просто снимается ниже.
      if coalesce(r.stock, 0) < r.qty then
        raise notice 'Досписание пропущено: заказ %, бумага %, бронь % м, остаток % м',
          o.label, r.paper_id, r.qty, r.stock;
        continue;
      end if;
      insert into public.papers_writeoffs(paper_id, qty, reason, by_name, order_id, source, employee_id, task_id)
      values (r.paper_id, r.qty,
              format('Расход бумаги на этапе по заказу %s (досписание 15.09.2026)', o.label),
              coalesce(v_actor, 'system'), o.id, 'paper_stage', v_employee, v_task.id);
    end loop;

    if exists (select 1 from public.papers_writeoffs w where w.order_id = o.id and w.task_id is not null) then
      perform public.finalize_order_paper_reservations(o.id_text, coalesce(v_actor, 'system'));
    else
      delete from public.order_paper_reservations where order_id = o.id;
      update public.orders set paper_written_off_at = now() where id = o.id;
    end if;
  end loop;
end
$backfill$;

commit;
