-- Контрольная проверка после бэкофилла. Только чтение.
--
-- ДВА ВОПРОСА:
--
-- 1. Применена ли ОБВЯЗКА. Бэкофилл её наличия не требует — он проверяет
--    только существование `recompute_task_quantity_shares`. То есть историю
--    можно было починить, не включив расчёт для БУДУЩИХ завершений, и тогда
--    через неделю всё разъедется заново. Проверяем прямо в теле функций.
--
-- 2. Что за задачи с тиражом, но без долей. В сводке после миграции таких
--    оказалось 3 (20 совместных с тиражом против 17 с долями). Ожидаемое
--    объяснение: этап ещё не закрыт — тираж записан на пересмене клиентом,
--    а доли считаются при завершении. Тогда беспокоиться не о чем.

-- === 1. Обвязка в боевых функциях ===
select
  p.proname                                            as "функция",
  pg_get_functiondef(p.oid) like '%recompute_task_quantity_shares%'
                                                       as "зовёт пересчёт",
  pg_get_functiondef(p.oid) like '%quantity_stage_total%'
                                                       as "пишет тираж этапа"
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'complete_task_stage',
    'complete_flex_printing_stage_with_paint_queue',
    'advance_order_after_task_completion'
  )
order by 1;

-- Ожидается: у complete_task_stage и
-- complete_flex_printing_stage_with_paint_queue «зовёт пересчёт» = true.
-- Если false — обвязка НЕ применена, новые этапы снова пишут полное Q каждому.

-- === 2. Совместные этапы с тиражом, но без долей ===
select
  t.order_id::text  as "заказ",
  t.stage_id::text  as "этап",
  t.status          as "статус задачи",
  (select to_timestamp(max(public.task_comment_millis(e->>'timestamp')) / 1000.0)
     from jsonb_array_elements(
            public.task_comments_to_array(t.comments::jsonb)) e
    where e->>'type' = 'quantity_stage_total') as "последний тираж"
from public.tasks t
where t.comments is not null
  and exists (
    select 1 from jsonb_array_elements(
                    public.task_comments_to_array(t.comments::jsonb)) e
     where e->>'type' = 'joined'
  )
  and exists (
    select 1 from jsonb_array_elements(
                    public.task_comments_to_array(t.comments::jsonb)) e
     where e->>'type' = 'quantity_stage_total'
       and to_timestamp(
             public.task_comment_millis(e->>'timestamp') / 1000.0
           ) >= date_trunc('month', now())
  )
  and not exists (
    select 1 from jsonb_array_elements(
                    public.task_comments_to_array(t.comments::jsonb)) e
     where e->>'type' = 'quantity_share'
       and public.task_quantity_payload(e->>'text')->>'generated' = 'true'
  )
order by 1;

-- Ожидается: статус НЕ completed (этап в работе, доли будут при закрытии).
-- Если попадётся completed — этот этап пересчёт обошёл, разбираемся отдельно.
