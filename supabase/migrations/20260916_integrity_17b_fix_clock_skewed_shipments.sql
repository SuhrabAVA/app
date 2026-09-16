-- ============================================================================
-- Целостность данных, шаг 17б: отгрузки, записанные по отставшим часам
-- складского ПК (2026-09-16) — ПРИМЕНЕНО 16.09.2026
--
-- С 11.09 по 15.09 часы складского ПК отставали от сервера на 58 минут, а
-- момент отгрузки писало устройство. В архиве отгрузка выглядела сделанной на
-- час раньше: ЗК-2026.09.03-8 значился как 15.09 16:11 вместо 17:09.
--
-- Настоящий момент известен: строку журнала партий (`order_shipments`)
-- создаёт сервер, и её `created_at` — это время отгрузки с точностью до
-- нескольких секунд. По нему и выравниваем `shipped_at` в журнале и в заказе.
--
-- Границы 50–70 минут выбраны намеренно: так под правку попадает только
-- «часовой» сдвиг часов. У более старых отгрузок строка журнала создавалась
-- задним числом (разница до 25 суток) — настоящего момента там нет, и их
-- трогать нельзя.
--
-- Результат: 58 партий, 57 заказов; у ЗК-2026.08.13-6 отметки в заказе нет
-- (частичная отгрузка) — поправлена только строка журнала. После правки
-- отгрузок в будущем нет, отгрузок раньше завершения производства нет,
-- все 130 отгруженных заказов сходятся с журналом партий.
--
-- Флаг ниже отключает триггер `stamp_server_shipped_at` (шаг 17) — иначе он
-- подменил бы переносимое время на now().
-- ============================================================================

begin;

set local app.trust_client_shipped_at = 'on';

create temporary table _fix_shipment_clock on commit drop as
select s.id as shipment_id, s.order_id, s.shipped_at as old_at, s.created_at as new_at
  from public.order_shipments s
 where extract(epoch from (s.created_at - s.shipped_at))/60 between 50 and 70;

update public.order_shipments s
   set shipped_at = f.new_at
  from _fix_shipment_clock f
 where s.id = f.shipment_id;

-- Заказу время ставим по той партии, которой он был закрыт: сравниваем с тем
-- значением, что стояло до правки.
with matched as (
  select o.id, max(f.new_at) as new_at
    from public.orders o
    join _fix_shipment_clock f on f.order_id = o.id
   where o.shipped_at is not null
     and abs(extract(epoch from (o.shipped_at - f.old_at))) < 120
   group by o.id
)
update public.orders o
   set shipped_at = m.new_at
  from matched m
 where o.id = m.id;

commit;
