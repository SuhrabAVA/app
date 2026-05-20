alter table if exists public.orders
  add column if not exists restarted_from_order_id text null,
  add column if not exists restart_root_order_id text null,
  add column if not exists restart_generation integer not null default 0,
  add column if not exists completed_at timestamptz null;

create index if not exists idx_orders_restarted_from_order_id on public.orders(restarted_from_order_id);
create index if not exists idx_orders_restart_root_order_id on public.orders(restart_root_order_id);

-- soft-FK to keep compatibility with legacy rows/imports
alter table if exists public.orders
  drop constraint if exists orders_restarted_from_order_id_fkey;
alter table if exists public.orders
  add constraint orders_restarted_from_order_id_fkey
  foreign key (restarted_from_order_id) references public.orders(id)
  on update cascade on delete set null;

alter table if exists public.orders
  drop constraint if exists orders_restart_root_order_id_fkey;
alter table if exists public.orders
  add constraint orders_restart_root_order_id_fkey
  foreign key (restart_root_order_id) references public.orders(id)
  on update cascade on delete set null;

create or replace function public.get_order_restart_history(p_order_id text, p_limit integer default 200)
returns table (
  order_id text,
  order_name text,
  completed_at timestamptz,
  restart_generation integer,
  restarted_from_order_id text
)
language sql
stable
as $$
with recursive chain as (
  select o.id, o.customer, o.completed_at, o.restart_generation, o.restarted_from_order_id,
         array[o.id]::text[] as path, 0 as depth
  from public.orders o
  where o.id = p_order_id

  union all

  select parent.id, parent.customer, parent.completed_at, parent.restart_generation, parent.restarted_from_order_id,
         c.path || parent.id, c.depth + 1
  from chain c
  join public.orders parent on parent.id = c.restarted_from_order_id
  where c.depth < greatest(1, least(coalesce(p_limit, 200), 200))
    and not (parent.id = any(c.path))
)
select c.id as order_id,
       c.customer as order_name,
       c.completed_at,
       c.restart_generation,
       c.restarted_from_order_id
from chain c
where c.id <> p_order_id
order by c.restart_generation asc, c.completed_at asc nulls last;
$$;
