-- Determine orders.id type from the current schema: existing migrations define
-- foreign keys as `order_id text references public.orders(id)`, therefore orders.id
-- in this project schema is text-compatible.
alter table if exists public.orders
  add column if not exists restarted_from_order_id text null,
  add column if not exists restart_root_order_id text null,
  add column if not exists restart_generation integer not null default 0;

create index if not exists orders_restarted_from_order_id_idx
  on public.orders(restarted_from_order_id);

create index if not exists orders_restart_root_order_id_idx
  on public.orders(restart_root_order_id);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'orders_restarted_from_order_id_fkey'
      and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders
      add constraint orders_restarted_from_order_id_fkey
      foreign key (restarted_from_order_id)
      references public.orders(id)
      on delete set null;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'orders_restart_root_order_id_fkey'
      and conrelid = 'public.orders'::regclass
  ) then
    alter table public.orders
      add constraint orders_restart_root_order_id_fkey
      foreign key (restart_root_order_id)
      references public.orders(id)
      on delete set null;
  end if;
end $$;
