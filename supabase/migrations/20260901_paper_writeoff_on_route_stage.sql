-- Бумага списывается на своём этапе маршрута, а не в конце заказа (2026-09-01).
--
-- ЗАЧЕМ
-- До этой миграции бумага уходила со склада только когда закрывалась ПОСЛЕДНЯЯ
-- задача заказа: advance_order_after_task_completion ставил orders.status =
-- 'completed' и звал finalize_order_paper_reservations. Физически рулон
-- расходуется гораздо раньше — на бобинорезке или флексопечати, — и всё время
-- до конца заказа склад показывал метры, которых уже нет. Кладовщик закрывал
-- эту дыру ручными списаниями, и по одной и той же бумаге шли два независимых
-- канала расхода (за август: 112 авто-списаний и 180 ручных).
--
-- ПРАВИЛО (со слов заказчика)
--   * бобинорезка идёт ПОСЛЕ флексопечати — списываем после флексопечати;
--   * флексопечать идёт ПОСЛЕ бобинорезки — списываем после бобинорезки;
--   * ни того, ни другого в маршруте нет — списываем после первого этапа,
--     который считается в метрах (workplaces.unit = 'м').
-- Первые два пункта — это одно и то же правило: кто из двух рулонных этапов
-- идёт в маршруте раньше, тот и списывает. Так и реализовано.
--
-- ОДНОРАЗОВОСТЬ
-- Списание по заказу — событие, а не состояние, и повторяться оно не должно.
-- Отметка orders.paper_written_off_at закрывает три пути к двойному расходу:
--   * этап списал бумагу, затем менеджер правит заказ — updateOrder заново
--     синхронизирует бронь (orders_provider.dart), и в конце заказа она была бы
--     списана второй раз. Теперь sync_order_paper_reservations после списания
--     брони не создаёт;
--   * завершение заказа и отгрузка зовут finalize_order_paper_reservations как
--     страховку — второй вызов теперь только подчищает остатки брони;
--   * у заказа без рулонных и метровых этапов правило не находит этап, и
--     списание по-прежнему происходит в конце заказа. Старое поведение
--     сохранено намеренно: терять расход у таких заказов нельзя.
--
-- ПОБОЧНО
-- Резерв краски завершённого заказа теперь освобождается на сервере. Раньше
-- release_order_paint_reservations звался только при удалении заказа, и брони
-- закрытых заказов вечно занижали доступный остаток: по «300i Синий» при
-- складе 3800 г висело 17000 г брони, из них 18500 г уже израсходовано.

-- 1. Отметка «бумага по заказу списана» ---------------------------------------

alter table public.orders
  add column if not exists paper_written_off_at timestamptz;

comment on column public.orders.paper_written_off_at is
  'Момент списания бумаги заказа со склада. Ставится один раз — на этапе из '
  'order_paper_writeoff_stage_key либо, если такого этапа нет, при завершении '
  'заказа. Непустое значение запрещает и повторное списание, и повторную бронь.';

-- 2. На каком этапе маршрута списывается бумага -------------------------------

create or replace function public.order_paper_writeoff_stage_key(p_order_id text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  -- Рабочие места берутся по id, а не по имени: имя менеджер может
  -- переименовать в справочнике, id — нет. Те же значения объявлены в
  -- lib/modules/orders/production_ids.dart, где их стережёт
  -- production_ids_test по снимку справочника workplaces.
  c_bobbin constant text := 'b92a89d1-8e95-4c6d-b990-e308486e4bf1'; -- Бабинорезка
  c_flexo  constant text := '0571c01c-f086-47e4-81b2-5d8b2ab91218'; -- Флексопечать
  v_key text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    return null;
  end if;

  -- Кто из двух рулонных этапов идёт в маршруте раньше, тот и списывает.
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
     and s.stage_id in (c_bobbin, c_flexo)
   order by s.seq nulls last, s.step_no nulls last, s.created_at
   limit 1;

  if v_key is not null then
    return v_key;
  end if;

  -- Рулонных этапов нет — первый этап, который считается в метрах.
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
    join public.workplaces w on w.id = s.stage_id
   where p.order_id::text = p_order_id
     and lower(btrim(coalesce(w.unit, ''))) = 'м'
   order by s.seq nulls last, s.step_no nulls last, s.created_at
   limit 1;

  return v_key;
end;
$function$;

comment on function public.order_paper_writeoff_stage_key(text) is
  'Ключ этапа (stage_group_key, иначе stage_id), после которого списывается '
  'бумага заказа: первый по маршруту из бобинорезки/флексопечати, иначе первый '
  'этап с единицей измерения «м». NULL — в маршруте нет ни того, ни другого.';

-- 3. Списание брони: одноразовое и с человекочитаемой причиной ----------------

create or replace function public.finalize_order_paper_reservations(
  p_order_id text,
  p_actor text default null::text
)
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
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := p_order_id;

  select o.paper_written_off_at, nullif(btrim(o.customer), '')
    into v_already, v_label
    from public.orders o
   where o.id::text = p_order_id;

  -- Уже списывали. Бронь, которую мог заново создать клиент при правке заказа,
  -- просто снимаем: метры давно ушли со склада, держать их незачем.
  if v_already is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;

  -- Причину собираем здесь, а не на клиенте: списание чаще всего происходит на
  -- сервере, и раньше кладовщик видел в журнале склада голый uuid заказа.
  v_reason := format('Списание бумаги по заказу %s', coalesce(v_label, p_order_id));

  -- Блокируем строки резерва заказа, чтобы избежать двойного списания.
  for rec in
    select r.paper_id, r.qty
    from public.order_paper_reservations r
    where r.order_id = v_order_id
    for update
  loop
    if rec.qty <= 0 then
      continue;
    end if;

    insert into public.papers_writeoffs(paper_id, qty, reason, by_name)
    values (
      rec.paper_id,
      rec.qty,
      v_reason,
      coalesce(nullif(trim(p_actor), ''), 'system')
    );
  end loop;

  update public.orders
     set paper_written_off_at = now()
   where id::text = p_order_id;

  delete from public.order_paper_reservations where order_id = v_order_id;
end;
$function$;

comment on function public.finalize_order_paper_reservations(text, text) is
  'Списывает бронь бумаги заказа на склад и снимает её. Одноразовая: повторный '
  'вызов только подчищает бронь, отметка — orders.paper_written_off_at.';

-- 4. Бронь не воскресает после списания ---------------------------------------

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
  -- не должна снова занимать метры: физически рулон израсходован, и повторная
  -- бронь и заморозила бы чужой остаток, и дала бы второе списание в конце
  -- заказа. Молча выходим — сохранение заказа из-за этого падать не должно.
  select o.paper_written_off_at into v_written_off
    from public.orders o
   where o.id::text = p_order_id;

  if v_written_off is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;

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
      from public.papers p
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
      from public.order_paper_reservations r
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
      from public.order_paper_reservations r
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
      delete from public.order_paper_reservations
       where order_id = v_order_id
         and paper_id = v_paper_id;
    else
      insert into public.order_paper_reservations(order_id, paper_id, qty)
      values (v_order_id, v_paper_id, rec.qty)
      on conflict (order_id, paper_id)
      do update
      set qty = excluded.qty,
          updated_at = now();
    end if;
  end loop;

  -- Удаляем резервы, которых больше нет в составе заказа.
  delete from public.order_paper_reservations r
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
  'проверяется только на прирост брони. После списания бумаги (orders.'
  'paper_written_off_at) брони больше не создаёт. Списаний не делает.';

-- 5. Завершение этапа: списание бумаги и освобождение краски -------------------

create or replace function public.advance_order_after_task_completion(
  p_order_id text,
  p_stage_id text,
  p_stage_group_key text default null::text,
  p_actor text default null::text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  -- Списание бумаги на своём этапе маршрута.
  --
  -- Готовность считаем по ГРУППОВОМУ ключу, а не по stage_id: у переключаемых
  -- этапов в группе несколько рабочих мест, и «этап закрыт» — это когда закрыты
  -- все задачи группы. Именно групповой ключ возвращает
  -- order_paper_writeoff_stage_key, поэтому сравниваются сравнимые величины.
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

    -- Страховка для маршрутов без рулонных и метровых этапов: там свой этап не
    -- находится, и списать бумагу больше негде. Для остальных заказов вызов
    -- уже одноразовый и просто ничего не делает.
    if to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
    end if;

    -- Резерв краски завершённого заказа возвращаем на склад. Без этого брони
    -- закрытых заказов навсегда занижали доступный остаток, и следующий заказ
    -- на ту же краску вставал в «Ожидание материалов» при полном складе.
    if to_regprocedure('public.release_order_paint_reservations(text,text,text)') is not null then
      perform public.release_order_paint_reservations(p_order_id, 'order_completed', p_actor);
    end if;
  end if;
end;
$function$;

comment on function public.advance_order_after_task_completion(text, text, text, text) is
  'Закрывает этап заказа: задачи, план, факт по количеству. Списывает бумагу на '
  'этапе из order_paper_writeoff_stage_key, а при завершении заказа закрывает '
  'заказ, страхует списание бумаги и освобождает резерв краски.';
