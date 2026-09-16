-- Что за доли, не равные тиражу. Только чтение.
--
-- ЗАЧЕМ. Бэкофилл удаляет машинную копию доли по признаку «текст совпадает с
-- текстом тиража» — это подпись старой `complete_task_stage`. Предпросмотр по
-- августу нашёл записи, которые под критерий НЕ попадают: у владельца
-- 172c4080 стоит 9798 при тираже 11833 и 2085 при тираже 3572. Такая запись
-- переживает бэкофилл, а пересчёт дописывает человеку ещё и рассчитанную
-- долю — в сумме двойной счёт (11776 вместо ~1978).
--
-- Прежде чем менять критерий, надо понять, ЧТО это за записи: машинные
-- (тогда их надо сносить) или введённые человеком (тогда трогать нельзя).
--
-- НА ЧТО СМОТРЕТЬ:
--   * `generated` = true — наша расчётная доля, её пересчёт снесёт сам;
--   * `edited_by` не пусто — правка техлида, обязана уцелеть;
--   * оба пусты, а рядом по времени стоит `user_done` или тираж — почти
--     наверняка запись машинная (сегмент пересмены), и её надо удалять;
--   * payload вида {"actual":…,"expected":…} без пометок — так пишет и
--     клиент, и старый RPC, поэтому решает соседство по времени.

select
  t.order_id::text                                     as "заказ",
  to_timestamp(public.task_comment_millis(e->>'timestamp') / 1000.0)
                                                       as "когда",
  e->>'type'                                           as "тип",
  e->>'userId'                                         as "сотрудник",
  public.task_quantity_value(e->>'text')               as "число",
  coalesce(public.task_quantity_payload(e->>'text')->>'generated', '')
                                                       as "generated",
  coalesce(public.task_quantity_payload(e->>'text')->>'edited_by', '')
                                                       as "edited_by",
  left(e->>'text', 90)                                 as "текст"
from public.tasks t,
     jsonb_array_elements(public.task_comments_to_array(t.comments::jsonb)) e
where t.order_id::text in (
        'df004332-faf8-4e16-b0bd-504373fbe8bf',
        '86c29d68-d09f-4193-aabf-7bdbc39cfe9b'
      )
  and t.stage_id::text = 'c5c1eb2e-dac8-4068-9e4c-ced8fb975626'
  and e->>'type' in (
        'quantity_share',
        'quantity_stage_total',
        'quantity_team_total',
        'quantity_done',
        'user_done',
        'shift_resume',
        'joined'
      )
order by 1, public.task_comment_millis(e->>'timestamp');
