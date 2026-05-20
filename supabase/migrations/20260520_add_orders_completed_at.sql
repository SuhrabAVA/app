alter table if exists public.orders
  add column if not exists completed_at timestamptz null;

create index if not exists orders_completed_at_idx
  on public.orders(completed_at);

update public.orders
set completed_at = coalesce(completed_at, shipped_at, archived_at, updated_at)
where status = 'completed'
  and completed_at is null;
