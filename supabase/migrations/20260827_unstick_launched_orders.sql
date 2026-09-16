-- Запущенные заказы, застрявшие в дозапускном статусе.
--
-- materialAvailabilityStatus возвращала null для любого заказа с
-- assignment_created = true — «запущенный не трогаем». Из-за этого заказ,
-- однажды выпавший в «Ожидание материалов», оставался там навсегда: нехватка
-- исчезала, has_material_shortage сбрасывался в false, текст ошибки стирался,
-- этапы шли — а статус не поднимал никто.
--
-- Правило исправлено в order_launch_rules.dart (запущенный заказ в дозапускном
-- статусе → in_production, с тестами). Эта миграция чинит строки, которые
-- накопились до правки.
--
-- Безопасность выборки: заказ, снятый с производства намеренно
-- (resetLaunchedOrderForRelaunch), сюда не попадает — там вместе со статусом
-- сбрасывается и assignment_created. Отгруженные и завершённые исключены.
-- Миграция идемпотентна: повторный запуск не найдёт ни одной строки.

with fixed as (
  update orders o
     set status = 'in_production',
         has_material_shortage = false,
         material_shortage_message = ''
   where o.assignment_created
     and o.status in ('draft', 'waiting_materials', 'ready_to_start')
     and o.shipped_at is null
  returning o.id
)
insert into order_events (order_id, event_type, description, message)
select f.id::text,
       'status',
       'Заказ возвращён в производство: он был запущен, но статус остался дозапускным',
       'Заказ возвращён в производство: он был запущен, но статус остался дозапускным'
  from fixed f;
