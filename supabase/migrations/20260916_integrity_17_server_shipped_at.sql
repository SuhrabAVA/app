-- ============================================================================
-- Целостность данных, шаг 17: момент отгрузки ставит сервер (2026-09-16)
--
-- Что чинит
-- ---------
-- `shipped_at` писало устройство: `DateTime.now().toUtc()` из клиента. Часы
-- складского ПК отстают от сервера на 58 минут, и каждая отгрузка попадала в
-- архив на час раньше, чем была: 15.09 отгрузка в 17:09 по Алматы значится
-- как 16:11. Показ при этом верный — в базе лежит неверный момент.
--
-- Правило
-- -------
-- Отметка времени отгрузки берётся с сервера: клиент присылает что угодно,
-- триггер подменяет на now(). Так же и в журнале партий `order_shipments`.
-- Снятие отметки (`shipped_at = null` при возобновлении заказа) не трогаем.
--
-- Аварийный обход для переноса данных:
--     set local app.trust_client_shipped_at = 'on';
-- ============================================================================

begin;

create or replace function public.stamp_server_shipped_at()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(current_setting('app.trust_client_shipped_at', true), '') = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.shipped_at is not null then
      new.shipped_at := now();
    end if;
    return new;
  end if;

  -- Отметку сняли (возобновление заказа) — так и оставляем.
  if new.shipped_at is not null and new.shipped_at is distinct from old.shipped_at then
    new.shipped_at := now();
  end if;
  return new;
end
$function$;

revoke execute on function public.stamp_server_shipped_at() from public, anon, authenticated;

drop trigger if exists orders_stamp_shipped_at on public.orders;
create trigger orders_stamp_shipped_at
  before insert or update of shipped_at on public.orders
  for each row
  execute function public.stamp_server_shipped_at();

drop trigger if exists order_shipments_stamp_shipped_at on public.order_shipments;
create trigger order_shipments_stamp_shipped_at
  before insert or update of shipped_at on public.order_shipments
  for each row
  execute function public.stamp_server_shipped_at();

commit;
