-- Чистка таблицы позиций очереди и функция для регулярной чистки.
--
-- Таблица не чистилась никогда: из 1533 строк 780 относились к заказам,
-- которых больше нет либо которые завершены/отгружены, и к задачам, которых
-- нет в базе. Появиться в очереди такая строка уже не может.
--
-- Мусор был не косметическим: запрос всех позиций на цеховой сети регулярно
-- не укладывался в таймаут 25 с («Failed to load workplace queue positions» —
-- 590 пакетов в app_error_logs с 7 устройств за месяц). После отказа клиент
-- показывал очередь из своего локального снимка, и у соседних планшетов она
-- расходилась.
--
-- Строки завершённых задач в ЖИВЫХ заказах намеренно оставлены: этап можно
-- возобновить, и тогда он должен вернуться на своё место в очереди, а не
-- в хвост.

create or replace function public.prune_workplace_queue_positions()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_deleted integer;
begin
  delete from workplace_queue_positions p
   where
     -- заказа больше нет
     not exists (select 1 from orders o where o.id::text = p.order_id)
     -- заказ закрыт: в очередь он не вернётся
     or exists (
       select 1 from orders o
        where o.id::text = p.order_id
          and (o.status = 'completed' or o.shipped_at is not null)
     )
     -- строка ссылается на задачу, которой больше нет
     or (
       p.task_id is not null
       and not exists (select 1 from tasks t where t.id::text = p.task_id)
     );

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;

comment on function public.prune_workplace_queue_positions() is
  'Удаляет строки очереди, которые уже не могут появиться ни на одном рабочем месте: закрытые и удалённые заказы, исчезнувшие задачи. Возвращает число удалённых строк.';

-- Разовый прогон вместе с миграцией.
do $prune$
declare
  v_before integer;
  v_deleted integer;
begin
  select count(*) into v_before from workplace_queue_positions;
  v_deleted := public.prune_workplace_queue_positions();
  raise notice 'workplace_queue_positions: было %, удалено %, осталось %',
    v_before, v_deleted, v_before - v_deleted;
end
$prune$;
