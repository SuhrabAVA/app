-- Тираж этапа во ВСЕЙ истории: `quantity_team_total` → `quantity_stage_total`.
--
-- ЗАЧЕМ. КПД рабочего места = скорость текущего месяца / средняя скорость
-- предыдущих. Скорость текущего месяца считается по ТИРАЖУ
-- (`buildWorkplaceStageTotals`), а база предыдущих месяцев — по сумме ЛИЧНЫХ
-- количеств, где у старых совместных этапов каждому участнику записано полное
-- Q. То есть КПД сравнивал тираж с тиражом, умноженным на число человек в
-- бригаде, и после включения долей по времени рухнул бы на ровном месте.
--
-- Клиент теперь берёт тираж и для базы (`buildPreviousSpeeds`), но взять его
-- неоткуда, пока в старых месяцах лежит `quantity_team_total`. Эта миграция
-- их переименовывает — и обе стороны сравнения становятся одной величиной.
--
-- ЧЕМ ОТЛИЧАЕТСЯ ОТ `20260908_backfill_quantity_shares.sql`. Тот пересчитывает
-- ДОЛИ и потому требует интервалов `time_event`, удаляет машинные копии и
-- ограничен окном. Здесь не так: ничего не удаляется, интервалы не нужны,
-- окна нет. Переименование типа безопасно само по себе:
--
--   * `quantity_team_total` и `quantity_stage_total` одинаково идут в факт
--     заказа (`countsTowardOrderQuantity`) — `orders.actual_qty` не меняется;
--   * личные доли не трогаются, зарплатная история остаётся как была;
--   * лента задачи знает оба типа (`task_comment_presentation`).
--
-- ПОСЛЕДСТВИЕ, которое надо понимать. Там, где доли НЕ пересчитывались
-- (месяцы вне окна бэкофилла), у помощников остаётся по полному Q. На
-- зарплату прошлых месяцев это не влияет — она уже начислена, — но плитка
-- этапа в старых заказах будет показывать эти полные Q. Чтобы починить и их,
-- прогоните бэкофилл долей с более ранней границей `v_window_start`.

begin;

do $convert$
declare
  v_task record;
  v_new jsonb;
  v_tasks int := 0;
  v_records int := 0;
  v_hits int;
begin
  for v_task in
    select t.id::text as id, t.comments
      from public.tasks t
     where t.comments is not null
       and exists (
         select 1
           from jsonb_array_elements(
                  public.task_comments_to_array(t.comments::jsonb)) c
          where c->>'type' = 'quantity_team_total'
       )
     order by t.id
  loop
    select count(*)
      into v_hits
      from jsonb_array_elements(
             public.task_comments_to_array(v_task.comments::jsonb)) c
     where c->>'type' = 'quantity_team_total';

    select coalesce(jsonb_agg(
             case
               when c->>'type' = 'quantity_team_total'
                 then jsonb_set(c, '{type}', '"quantity_stage_total"'::jsonb)
               else c
             end
             order by ord), '[]'::jsonb)
      into v_new
      from jsonb_array_elements(
             public.task_comments_to_array(v_task.comments::jsonb))
           with ordinality as a(c, ord);

    update public.tasks set comments = v_new where id::text = v_task.id;

    v_tasks := v_tasks + 1;
    v_records := v_records + v_hits;
  end loop;

  raise notice 'Задач: %, записей переименовано: %', v_tasks, v_records;
end
$convert$;

commit;

-- Проверка: `quantity_team_total` не должно остаться нигде.
select
  count(*) filter (where has_team_total)  as "осталось со старым типом",
  count(*) filter (where has_stage_total) as "с тиражом этапа"
from (
  select
    exists (select 1 from jsonb_array_elements(
                          public.task_comments_to_array(t.comments::jsonb)) e
             where e->>'type' = 'quantity_team_total') as has_team_total,
    exists (select 1 from jsonb_array_elements(
                          public.task_comments_to_array(t.comments::jsonb)) e
             where e->>'type' = 'quantity_stage_total') as has_stage_total
  from public.tasks t
  where t.comments is not null
) f;
