-- Срок жизни брони краски: строка живёт ровно пока держит граммы.
--
-- ПРОБЛЕМА. `order_paint_reservations` ссылается на `paints` внешним ключом
-- без каскада — и это правильно: иначе удаление краски молча стирало бы живые
-- брони, а заказ считал бы себя обеспеченным пустотой. Но ключ считает
-- СТРОКИ, а держит краску только непогашенный остаток
-- (`reserved_qty - used_qty - released_qty`). Строки с нулевым остатком
-- накапливались и запирали карточку краски навсегда:
--
--   * `release_order_paint_reservations` ЗАНУЛЯЕТ строки вместо удаления —
--     в отличие от парной `release_order_paper_reservations`, которая делает
--     `delete`. Снятая бронь оставляла строку;
--   * `sync_order_paint_reservations` подчищает лишнее только по ОДНОМУ
--     заказу и только когда его синхронизируют, а краску заказу
--     синхронизируют лишь при полной обеспеченности. Застрявший заказ не
--     чистился никогда, запущенный — тем более.
--
-- Расход при этом не теряется: израсходованные граммы записаны в
-- `paints_writeoffs`, а `used_qty` в броне — лишь счётчик для вычисления
-- остатка. Клиент и сервер считают одинаково
-- (`greatest(reserved - used - released, 0)`), поэтому удаление погашенной
-- строки не меняет ни одной суммы: она и так входила в них нулём.

begin;

-- 1. Снятие брони краски удаляет строки — как это делает бумага.
create or replace function public.release_order_paint_reservations(
  p_order_id text,
  p_reason text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_touched public.paints.id%type[];
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  select array_agg(distinct paint_id) into v_touched
    from order_paint_reservations
   where order_id::text = p_order_id and paint_id is not null;

  -- Раньше здесь стоял update released_qty = reserved_qty - used_qty:
  -- бронь становилась нулевой, но строка оставалась и запирала краску.
  delete from order_paint_reservations
   where order_id::text = p_order_id;

  perform recalculate_paint_reserved_qty(v_touched);
end;
$function$;

-- 2. Погашенная бронь удаляет себя сама, кем бы она ни была погашена:
--    правкой заказа, снятием или полным расходом в производстве.
create or replace function public.drop_settled_paint_reservation()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if greatest(
       coalesce(new.reserved_qty, 0)
         - coalesce(new.used_qty, 0)
         - coalesce(new.released_qty, 0),
       0) <= 0 then
    delete from order_paint_reservations where id = new.id;
  end if;
  return null;
end;
$function$;

drop trigger if exists trg_drop_settled_paint_reservation
  on public.order_paint_reservations;

create trigger trg_drop_settled_paint_reservation
after insert or update of reserved_qty, used_qty, released_qty
on public.order_paint_reservations
for each row
execute function public.drop_settled_paint_reservation();

-- 3. Разовая уборка уже накопленного: строки, которые не держат ничего.
--    Ни одна сумма от этого не меняется — они входили в них нулём.
delete from public.order_paint_reservations r
 where greatest(
         coalesce(r.reserved_qty, 0)
           - coalesce(r.used_qty, 0)
           - coalesce(r.released_qty, 0),
         0) <= 0;

select public.recalculate_paint_reserved_qty(null::text[]);

commit;
