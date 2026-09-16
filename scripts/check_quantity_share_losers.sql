-- КТО ПОТЕРЯЕТ ДОЛЮ ЦЕЛИКОМ при пересчёте.
--
-- Только чтение, ничего не меняет.
--
-- ЗАЧЕМ. Пересчёт делит тираж пропорционально интервалам `time_event` типа
-- production. Участник, у которого таких интервалов НЕТ, получает ноль —
-- и это правильно, если он действительно не работал. Но есть второй случай:
-- помощника добавляли посреди уже начатого этапа, и старый клиент не заводил
-- ему интервал вовсе (эту дыру закрыли позже, см. `decideHelperInterval`).
-- Такой человек работал, а по данным — нет, и пересчёт отберёт у него всё.
--
-- Поэтому перед применением бэкофилла надо посмотреть список ниже и решить
-- по каждому: не работал (ноль справедлив) или потерялись интервалы (тогда
-- задачу из окна надо исключить или доли проставить руками).
--
-- Равномерное деление тут не спасает: оно включается, только когда НИКТО
-- в сегменте не отработал ни секунды.

with scope as (
  select t.id::text as task_id,
         t.order_id::text as order_id,
         t.stage_id::text as stage_id,
         public.task_comments_to_array(t.comments::jsonb) as c
    from public.tasks t
   where t.comments is not null
     -- Та же выборка, что в предпросмотре и миграции.
     and exists (
       select 1 from jsonb_array_elements(
                       public.task_comments_to_array(t.comments::jsonb)) e
        where e->>'type' = 'quantity_team_total'
          and coalesce(trim(e->>'text'), '') <> ''
          and to_timestamp(
                public.task_comment_millis(e->>'timestamp') / 1000.0
              ) >= date_trunc('month', now())
     )
     and exists (
       select 1 from jsonb_array_elements(
                       public.task_comments_to_array(t.comments::jsonb)) e
        where e->>'type' = 'joined'
     )
     and exists (
       select 1 from jsonb_array_elements(
                       public.task_comments_to_array(t.comments::jsonb)) e
        where e->>'type' = 'time_event'
          and public.task_quantity_payload(e->>'text')->>'type' = 'production'
     )
),
-- Кому сейчас записана доля.
had as (
  select s.task_id, s.order_id, s.stage_id,
         trim(e->>'userId') as uid,
         sum(public.task_quantity_value(e->>'text')) as qty_now
    from scope s, jsonb_array_elements(s.c) e
   where e->>'type' = 'quantity_share'
     and coalesce(trim(e->>'userId'), '') <> ''
   group by 1, 2, 3, 4
),
-- У кого есть отработанное время.
worked as (
  select s.task_id,
         trim(public.task_quantity_payload(e->>'text')->>'subjectUserId') as uid,
         sum(
           extract(epoch from (
             coalesce(
               nullif(public.task_quantity_payload(e->>'text')->>'endTime', '')
                 ::timestamptz,
               now()
             )
             - (public.task_quantity_payload(e->>'text')->>'startTime')
                 ::timestamptz
           ))
         ) as secs
    from scope s, jsonb_array_elements(s.c) e
   where e->>'type' = 'time_event'
     and public.task_quantity_payload(e->>'text')->>'type' = 'production'
     and coalesce(trim(public.task_quantity_payload(e->>'text')->>'startTime'),
                  '') <> ''
   group by 1, 2
)
select
  h.order_id     as "заказ",
  h.stage_id     as "этап",
  h.uid          as "сотрудник",
  h.qty_now      as "записано сейчас",
  coalesce(w.secs, 0) as "секунд работы"
from had h
left join worked w on w.task_id = h.task_id and w.uid = h.uid
where coalesce(w.secs, 0) <= 0
order by 1, 3;
