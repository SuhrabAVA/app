-- След одного участника на одном этапе: все его записи, по порядку.
--
-- Только чтение.
--
-- ЗАЧЕМ. Пересчёт отдаст сотруднику ноль, если у него нет интервалов
-- `production`. Надо отличить два случая:
--
--   * человек и правда не работал — ноль справедлив;
--   * человек работал, но интервал ему не завели (старый клиент не открывал
--     интервал помощнику, добавленному посреди уже начатого этапа) — тогда
--     ноль отберёт заработанное.
--
-- ЧТО СМОТРЕТЬ. `user_done` доказательством работы НЕ является: старая
-- `complete_task_stage` писала его КАЖДОМУ помощнику автоматически при
-- закрытии этапа. Показательны интервалы: если есть pause/problem/setup, но
-- нет production — человек на этапе присутствовал, и ноль почти наверняка
-- следствие потерянного интервала. Если кроме `joined` и `user_done` нет
-- ничего — он к работе не приступал.

select
  to_timestamp(public.task_comment_millis(e->>'timestamp') / 1000.0)
                                              as "когда",
  e->>'type'                                  as "тип записи",
  coalesce(
    public.task_quantity_payload(e->>'text')->>'type',
    ''
  )                                           as "тип интервала",
  coalesce(
    public.task_quantity_payload(e->>'text')->>'startTime',
    ''
  )                                           as "начало",
  coalesce(
    public.task_quantity_payload(e->>'text')->>'endTime',
    ''
  )                                           as "конец",
  left(e->>'text', 120)                       as "текст"
from public.tasks t,
     jsonb_array_elements(public.task_comments_to_array(t.comments::jsonb)) e
where t.order_id::text = '59394536-6826-4836-a2a5-8a3453ee7448'
  and t.stage_id::text = 'c5c1eb2e-dac8-4068-9e4c-ced8fb975626'
  and (
    trim(coalesce(e->>'userId', '')) = '3eff68eb-fcb2-4a82-96a5-63a280323720'
    or trim(coalesce(
         public.task_quantity_payload(e->>'text')->>'subjectUserId', ''
       )) = '3eff68eb-fcb2-4a82-96a5-63a280323720'
  )
order by public.task_comment_millis(e->>'timestamp');
