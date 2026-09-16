-- ============================================================================
--  Производственный интервал, проехавший сквозь паузу бригады
-- ============================================================================
--
--  Что ищем
--  --------
--  Совместный этап останавливается целиком: основной исполнитель нажимает
--  «Пауза», и интервал должен закрыться у КАЖДОГО. Если у кого-то он остался
--  открытым, человек «работал» весь обед — время удваивается, а вместе с ним
--  и доля, которую сервер начисляет по времени (recompute_task_quantity_shares).
--  Дальше это уходит в сдельную часть зарплаты.
--
--  Признак: производственный интервал одного участника ЦЕЛИКОМ содержит в себе
--  паузу или пересмену другого участника той же задачи.
--
--  Почему только joint
--  -------------------
--  В режиме отдельных исполнителей каждый работает сам по себе, и «Петров на
--  паузе, пока Иванов работает» — норма, а не поломка. Без этого фильтра
--  запрос выдаёт 18 ложных срабатываний на 9 этапах.
--
--  Откуда взялось
--  --------------
--  Рассылка паузы шла по списку бригады, снятому при отрисовке экрана. Кто
--  присоединился к этапу позже отрисовки, в рассылку не попадал. Исправлено в
--  приложении: список берётся из свежей задачи в момент нажатия — см.
--  jointHelperIds в lib/modules/tasks/helper_interval_rules.dart.
--  Этот запрос остаётся как проверка: если число вырастет, регресс вернулся.
--
--  Как чинить найденное
--  --------------------
--  1. Разрезать интервал по границам чужой паузы (закрыть на её начале,
--     открыть на её конце).
--  2. Пересчитать доли этапа:
--       select public.recompute_task_quantity_shares('<task_id>');
-- ============================================================================

with ev as (
  select t.id                                              as task_id,
         c->>'id'                                          as event_id,
         ((c->>'text')::jsonb->>'subjectUserId')            as uid,
         ((c->>'text')::jsonb->>'type')                    as ev_type,
         (((c->>'text')::jsonb->>'startTime')::timestamptz) as st,
         (((c->>'text')::jsonb->>'endTime')::timestamptz)   as en
    from public.tasks t
    cross join lateral jsonb_array_elements(t.comments) c
   where c->>'type' = 'time_event'
     and left(c->>'text', 1) = '{'
),
-- Режим этапа — по последней отметке exec_mode_stage.
stage_mode as (
  select t.id as task_id,
         (array_agg(c->>'text' order by ((c->>'timestamp')::bigint) desc))[1] as mode
    from public.tasks t
    cross join lateral jsonb_array_elements(t.comments) c
   where c->>'type' = 'exec_mode_stage'
   group by t.id
),
production as (
  select * from ev where ev_type = 'production' and en is not null
),
breaks as (
  select * from ev where ev_type in ('pause', 'shift_change') and en is not null
)
-- Чужие паузы внутри интервала СХЛОПЫВАЕМ в объединение, а не складываем.
-- Бригада уходит на один и тот же обед, и у каждого участника своя запись
-- паузы на этот же час: простая сумма умножала бы «лишнее время» на число
-- участников — на разборе 09.09 выходило 239 минут вместо 60.
overrun as (
  select p.task_id,
         p.uid,
         p.st,
         p.en,
         range_agg(tstzrange(b.st, b.en)) as covered
    from production p
    join breaks b
      on b.task_id = p.task_id
     and b.uid <> p.uid
     and b.st >= p.st
     and b.en <= p.en
    join stage_mode m on m.task_id = p.task_id and m.mode = 'joint'
   group by p.task_id, p.uid, p.st, p.en
)
select o.assignment_id,
       o.customer,
       w.name                                                as stage,
       coalesce(e.first_name || ' ' || e.last_name, x.uid)   as employee,
       x.st at time zone 'Asia/Almaty'                       as interval_start,
       x.en at time zone 'Asia/Almaty'                       as interval_end,
       (select round(sum(extract(epoch from (upper(r) - lower(r)))) / 60)
          from unnest(x.covered) as r)                       as extra_minutes,
       x.task_id
  from overrun x
  join public.tasks t on t.id = x.task_id
  join public.orders o on o.id = t.order_id
  left join public.workplaces w on w.id = t.stage_id
  left join public.employees e on e.id = x.uid
 order by x.st desc;

