-- Списание бумаги после ПОСЛЕДНЕГО рулонного этапа + починка регресса 08.09.
--
-- ПРАВИЛО (новое, 14.09.2026)
--   * В маршруте есть Бабинорезка и Флексопечать — бумага списывается после
--     той, что идёт ПОЗЖЕ: «Флексопечать → Бабинорезка» списывает после
--     Бабинорезки, «Бабинорезка → Флексопечать» — после Флексопечати.
--   * Есть только одна из них — после неё.
--   * Нет ни одной — после ПЕРВОГО этапа маршрута.
--   * Маршрута нет вовсе — страховка при завершении заказа (как раньше).
-- Прежнее правило (20260901) брало ПЕРВЫЙ рулонный этап, а без рулонных —
-- первый этап в метрах.
--
-- РЕГРЕСС, КОТОРЫЙ ЗДЕСЬ ЧИНИТСЯ
-- `20260821_quantity_share_wiring.sql`, накаченная 08.09 около 16:00, пересоздала
-- `advance_order_after_task_completion` из снимка 05.08 и молча выбросила два
-- блока из 20260901:
--   1. списание бумаги на своём этапе — с 08.09 бумага списывалась только при
--      завершении всего заказа, и в журнале склада стояло имя упаковщика;
--   2. возврат брони краски при завершении заказа.
-- Тело функции ниже = ДЕЙСТВУЮЩЕЕ тело из базы (с подсчётом тиража по
-- `quantity_stage_total` из обвязки) + эти два блока. Просто перекатить
-- 20260901 нельзя: она откатила бы подсчёт тиража обратно на
-- `quantity_team_total`.
--
-- ДОСПИСАНИЕ
-- Заказы, у которых этап списания по НОВОМУ правилу закрыт С 01.09.2026 (с
-- появления списания на этапе), а бумага всё ещё в брони, досписываются здесь
-- же. Этапы, закрытые РАНЬШЕ, не трогаются: на 14.09 это 16 заказов, зависших
-- в производстве с августа (11 из них на «Тестовой бумаге»), ~150 тыс. м —
-- тогда бумага списывалась при завершении заказа, и израсходована ли она
-- физически, из базы не видно. Они спишутся по-старому, при завершении
-- заказа, либо отдельным решением.
--   * `by_name` — тот, кто закрыл этап (последний `user_done`), как было бы
--     при штатном списании;
--   * в причине — пометка «досписано» и время закрытия этапа, чтобы
--     кладовщик не гадал, откуда сегодня взялось списание;
--   * если по бумаге ПОСЛЕ закрытия этапа была инвентаризация, строка НЕ
--     списывается: пересчёт уже зафиксировал фактический остаток без этих
--     метров, и списание сняло бы их второй раз. Бронь по ней просто
--     снимается, событие пишется в историю заказа.
-- Краска: у завершённых заказов снимается бронь через
-- `release_order_paint_reservations` — она сама оставляет краски с
-- непогашенным отложенным списанием (20260911).
--
-- ОТКАТА НЕТ: списания уменьшают остаток склада триггером.

begin;

-- 0. Действующее тело не должно было измениться с момента диагностики -------
--
-- Функция ниже написана поверх конкретного живого определения. Если его
-- успели поменять, накатывать нельзя — молча откатим чужую правку.
do $guard$
declare
  v_def text := pg_get_functiondef(
    'public.advance_order_after_task_completion(text,text,text,text)'::regprocedure);
begin
  if md5(v_def) <> 'f76a1d915230592a27cebbabec760382'
     and v_def not ilike '%order_paper_writeoff_stage_key%' then
    raise exception
      'advance_order_after_task_completion изменилась после 14.09.2026 — '
      'миграция написана под другое тело. Ничего не изменено.';
  end if;
end
$guard$;

-- 1. Этап списания бумаги ------------------------------------------------------

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
  -- lib/modules/orders/production_ids.dart.
  c_bobbin constant text := 'b92a89d1-8e95-4c6d-b990-e308486e4bf1'; -- Бабинорезка
  c_flexo  constant text := '0571c01c-f086-47e4-81b2-5d8b2ab91218'; -- Флексопечать
  v_key text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    return null;
  end if;

  -- Рулонные этапы есть — списываем после того, что идёт в маршруте ПОЗЖЕ.
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
     and s.stage_id in (c_bobbin, c_flexo)
   order by s.seq desc nulls last, s.step_no desc nulls last, s.created_at desc
   limit 1;

  if v_key is not null then
    return v_key;
  end if;

  -- Рулонных этапов нет — первый этап маршрута.
  select coalesce(nullif(s.stage_group_key, ''), s.stage_id)
    into v_key
    from public.prod_plans p
    join public.prod_plan_stages s on s.plan_id = p.id
   where p.order_id::text = p_order_id
   order by s.seq nulls last, s.step_no nulls last, s.created_at
   limit 1;

  return v_key;
end;
$function$;

comment on function public.order_paper_writeoff_stage_key(text) is
  'Групповой ключ этапа, после которого списывается бумага заказа: последний '
  'по маршруту из Бабинорезки/Флексопечати, без них — первый этап маршрута. '
  'NULL — маршрута нет, списание при завершении заказа.';

-- 2. Завершение этапа ----------------------------------------------------------

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

  -- Списание бумаги на своём этапе маршрута (order_paper_writeoff_stage_key).
  --
  -- Готовность считаем по ГРУППОВОМУ ключу, а не по stage_id: у переключаемых
  -- этапов в группе несколько рабочих мест, и «этап закрыт» — это когда закрыты
  -- все задачи группы. Именно групповой ключ возвращает
  -- order_paper_writeoff_stage_key, поэтому сравниваются сравнимые величины.
  -- Повторный вызов безвреден: finalize_order_paper_reservations одноразова
  -- (orders.paper_written_off_at).
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

    -- Страховка для заказов без маршрута: этап списания не находится, и
    -- списать бумагу больше негде. Для остальных вызов уже ничего не делает.
    if to_regprocedure('public.finalize_order_paper_reservations(text,text)') is not null then
      perform public.finalize_order_paper_reservations(p_order_id, p_actor);
    end if;

    -- Бронь краски завершённого заказа возвращается на склад. Краски с
    -- непогашенным отложенным списанием функция оставляет сама (20260911).
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

-- 3. Досписание бумаги по заказам, пропущенным с 08.09 -------------------------

do $backfill$
declare
  -- Раньше этой даты списания на этапе не существовало (см. шапку).
  c_since     constant timestamptz := '2026-09-01 00:00+05';
  v_order     record;
  v_row       record;
  v_actor     text;
  v_done_at   timestamptz;
  v_reason    text;
  v_written   jsonb;
  v_absorbed  jsonb;
  v_orders    int := 0;
  v_rows      int := 0;
  v_skipped   int := 0;
begin
  for v_order in
    select o.id::text as order_id,
           coalesce(nullif(btrim(o.customer), ''), o.id::text) as label,
           public.order_paper_writeoff_stage_key(o.id::text) as stage_key
      from public.orders o
     where o.paper_written_off_at is null
       and exists (
         select 1 from public.order_paper_reservations r
          where r.order_id::text = o.id::text and r.qty > 0
       )
  loop
    continue when v_order.stage_key is null;

    -- Этап списания закрыт целиком?
    continue when not coalesce((
      select bool_and(t.status = 'completed')
        from public.tasks t
       where t.order_id::text = v_order.order_id
         and coalesce(nullif(t.stage_group_key, ''), t.stage_id::text) = v_order.stage_key
    ), false);

    -- Кто и когда закрыл этап: последний user_done группы.
    v_actor := null;
    v_done_at := null;
    select nullif(trim(c->>'userId'), ''),
           to_timestamp(public.task_comment_millis(c->>'timestamp') / 1000.0)
      into v_actor, v_done_at
      from public.tasks t
     cross join lateral jsonb_array_elements(
             public.task_comments_to_array(t.comments::jsonb)) c
     where t.order_id::text = v_order.order_id
       and coalesce(nullif(t.stage_group_key, ''), t.stage_id::text) = v_order.stage_key
       and c->>'type' = 'user_done'
       and coalesce(trim(c->>'userId'), '') <> ''
     order by public.task_comment_millis(c->>'timestamp') desc
     limit 1;

    -- Задачи, закрытые без отметок (правка статуса): время — по самой задаче,
    -- исполнитель — первый назначенный.
    if v_done_at is null then
      select coalesce(to_timestamp(max(t.completed_at) / 1000.0), max(t.updated_at)),
             (array_agg(t.assignees[1] order by t.updated_at desc)
                filter (where coalesce(t.assignees[1], '') <> ''))[1]
        into v_done_at, v_actor
        from public.tasks t
       where t.order_id::text = v_order.order_id
         and coalesce(nullif(t.stage_group_key, ''), t.stage_id::text) = v_order.stage_key;
    end if;

    continue when v_done_at is null or v_done_at < c_since;

    v_reason := format(
      'Списание бумаги по заказу %s (досписано: этап закрыт %s)',
      v_order.label,
      coalesce(to_char(v_done_at at time zone 'Asia/Qostanay', 'DD.MM HH24:MI'), '—')
    );
    v_written := '[]'::jsonb;
    v_absorbed := '[]'::jsonb;

    for v_row in
      select r.id, r.paper_id, r.qty
        from public.order_paper_reservations r
       where r.order_id::text = v_order.order_id
         for update
    loop
      continue when v_row.qty <= 0;

      if v_done_at is not null and exists (
        select 1 from public.papers_inventories i
         where i.paper_id = v_row.paper_id
           and i.created_at > v_done_at
      ) then
        -- Пересчёт после этапа уже учёл израсходованные метры.
        v_absorbed := v_absorbed || jsonb_build_array(jsonb_build_object(
          'paper_id', v_row.paper_id, 'qty', v_row.qty));
        v_skipped := v_skipped + 1;
      else
        insert into public.papers_writeoffs(paper_id, qty, reason, by_name)
        values (v_row.paper_id, v_row.qty, v_reason, coalesce(v_actor, 'system'));
        v_written := v_written || jsonb_build_array(jsonb_build_object(
          'paper_id', v_row.paper_id, 'qty', v_row.qty));
        v_rows := v_rows + 1;
      end if;
    end loop;

    update public.orders
       set paper_written_off_at = now()
     where id::text = v_order.order_id;

    delete from public.order_paper_reservations
     where order_id::text = v_order.order_id;

    insert into public.order_events(order_id, event_type, description, message, payload)
    values (
      v_order.order_id,
      'paper_writeoff_backfill',
      'Резерв бумаги',
      case when jsonb_array_length(v_absorbed) = 0
        then 'Бумага досписана после сбоя 08.09: этап списания был закрыт, а резерв оставался на складе.'
        else 'Бумага досписана после сбоя 08.09. Часть рулонов не списана: после закрытия этапа по ним была инвентаризация, остаток уже фактический.'
      end,
      jsonb_build_object(
        'stage_key', v_order.stage_key,
        'stage_closed_at', v_done_at,
        'actor', v_actor,
        'written_off', v_written,
        'absorbed_by_inventory', v_absorbed
      )
    );

    v_orders := v_orders + 1;
  end loop;

  raise notice 'Заказов досписано: %, строк списания: %, пропущено из-за инвентаризации: %',
    v_orders, v_rows, v_skipped;
end
$backfill$;

-- 4. Бронь краски у завершённых заказов -----------------------------------------

do $paint$
declare
  v_order_id text;
  v_orders int := 0;
begin
  for v_order_id in
    select distinct r.order_id::text
      from public.order_paint_reservations r
      join public.orders o on o.id::text = r.order_id::text
     where o.status = 'completed'
  loop
    perform public.release_order_paint_reservations(v_order_id, 'order_completed', null);
    v_orders := v_orders + 1;
  end loop;

  raise notice 'Завершённых заказов с бронью краски обработано: %', v_orders;
end
$paint$;

commit;

-- Проверка после применения (редактор покажет таблицей). Ожидаемо:
--   «функция знает этап списания» = true, «возвращает краску» = true;
--   «этап закрыт, бумага в брони» = 16 — августовские зависшие заказы,
--   их досписание не делается (см. шапку); больше 16 — что-то не списалось;
--   «завершённые с бронью краски» — только заказы с отложенным списанием.
select
  (pg_get_functiondef('public.advance_order_after_task_completion(text,text,text,text)'::regprocedure)
     ilike '%order_paper_writeoff_stage_key%') as "функция знает этап списания",
  (pg_get_functiondef('public.advance_order_after_task_completion(text,text,text,text)'::regprocedure)
     ilike '%release_order_paint_reservations%') as "возвращает краску",
  (select count(*)
     from public.orders o
    where o.paper_written_off_at is null
      and exists (select 1 from public.order_paper_reservations r
                   where r.order_id::text = o.id::text and r.qty > 0)
      and public.order_paper_writeoff_stage_key(o.id::text) is not null
      and coalesce((
        select bool_and(t.status = 'completed') from public.tasks t
         where t.order_id::text = o.id::text
           and coalesce(nullif(t.stage_group_key, ''), t.stage_id::text)
               = public.order_paper_writeoff_stage_key(o.id::text)
      ), false)) as "этап закрыт, бумага в брони",
  (select count(distinct r.order_id)
     from public.order_paint_reservations r
     join public.orders o on o.id::text = r.order_id::text
    where o.status = 'completed') as "завершённые с бронью краски",
  (select count(*) from public.order_events
    where event_type = 'paper_writeoff_backfill') as "досписано заказов",
  -- Триггер списания не уводит остаток ниже нуля, а обрезает до 0. Если здесь
  -- не пусто — метров на складе было меньше, чем досписано: сверить рулон.
  (select string_agg(distinct p.description || ' ' || p.format || '/' || p.grammage, '; ')
     from public.order_events ev
     cross join lateral jsonb_array_elements(ev.payload->'written_off') w
     join public.papers p on p.id::text = w->>'paper_id'
    where ev.event_type = 'paper_writeoff_backfill'
      and p.quantity = 0) as "бумага ушла в ноль";
