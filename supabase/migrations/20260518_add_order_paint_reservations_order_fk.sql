-- Ensure PostgREST can resolve order_paint_reservations -> orders embeds
-- even when the reservations table was created before the FK existed.

do $$
begin
  if to_regclass('public.order_paint_reservations') is not null
     and to_regclass('public.orders') is not null
     and not exists (
       select 1
         from pg_constraint c
        where c.conrelid = 'public.order_paint_reservations'::regclass
          and c.confrelid = 'public.orders'::regclass
          and c.contype = 'f'
     ) then
    alter table public.order_paint_reservations
      add constraint order_paint_reservations_order_id_fkey
      foreign key (order_id)
      references public.orders(id)
      on delete cascade
      not valid;
  end if;
end $$;

notify pgrst, 'reload schema';
