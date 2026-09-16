-- Сколько работы в бэкофилле долей, если отодвинуть границу назад.
--
-- Только чтение.
--
-- Помесячно: сколько совместных этапов подлежит пересчёту, сколько потерянных
-- интервалов придётся восстановить и сколько задач ПРОПУСТИТ бэкофилл из-за
-- полного отсутствия интервалов `time_event`.
--
-- Последняя колонка — главная. Такие задачи бэкофилл не берёт: делить время
-- не по чему, а равномерное деление было бы догадкой, а не фактом. Если в
-- каком-то месяце их много, значит `time_event` тогда ещё не писались, и
-- дальше этой границы отодвигать окно бессмысленно.
--
-- Выбранный месяц подставьте в `v_window_start` в предпросмотре и в миграции
-- `20260908_backfill_quantity_shares.sql` (в ОБОИХ файлах).

with tasks_с as (
  select t.id::text as task_id,
         public.task_comments_to_array(t.comments::jsonb) as c
    from public.tasks t
   where t.comments is not null
),
joint as (
  select s.task_id,
         s.c,
         (select min(public.task_comment_millis(e->>'timestamp'))
            from jsonb_array_elements(s.c) e
           where e->>'type' in ('quantity_team_total',
                                'quantity_stage_total')
             and coalesce(trim(e->>'text'), '') <> '') as total_ms
    from tasks_с s
   where exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'joined')
),
classified as (
  select
    date_trunc('month', to_timestamp(j.total_ms / 1000.0)) as month,
    j.task_id,
    exists (select 1 from jsonb_array_elements(j.c) e
             where e->>'type' = 'time_event'
               and public.task_quantity_payload(e->>'text')->>'type'
                   = 'production') as has_intervals,
    (select count(*)
       from (
         select trim(e->>'userId') as uid
           from jsonb_array_elements(j.c) e
          where e->>'type' = 'joined'
            and coalesce(trim(e->>'userId'), '') <> ''
          group by 1
       ) h
      where not exists (
        select 1 from jsonb_array_elements(j.c) e2
         where e2->>'type' = 'time_event'
           and public.task_quantity_payload(e2->>'text')->>'type'
               = 'production'
           and trim(coalesce(
                 public.task_quantity_payload(e2->>'text')->>'subjectUserId',
                 '')) = h.uid
      )) as lost_intervals
  from joint j
  where j.total_ms is not null
)
select
  to_char(month, 'YYYY-MM')                              as "месяц",
  count(*) filter (where has_intervals)                  as "пересчитается",
  sum(lost_intervals) filter (where has_intervals)       as "интервалов восстановить",
  count(*) filter (where not has_intervals)              as "пропустится (нет интервалов)"
from classified
group by month
order by month desc;
