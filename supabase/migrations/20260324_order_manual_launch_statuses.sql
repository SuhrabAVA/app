-- Manual launch workflow for orders:
-- draft -> waiting_materials -> ready_to_start -> in_production -> completed

alter table if exists public.orders
  add column if not exists has_material_shortage boolean not null default false,
  add column if not exists material_shortage_message text not null default '';

-- Normalize legacy statuses to the new workflow vocabulary.
update public.orders
set status = case
  when status = 'newOrder' then 'draft'
  when status = 'inWork' then 'in_production'
  else status
end
where status in ('newOrder', 'inWork');

-- Guard allowed statuses (idempotent).
do $$
begin
  if exists (
    select 1
    from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'orders'
      and constraint_name = 'orders_status_check'
  ) then
    alter table public.orders drop constraint orders_status_check;
  end if;

  alter table public.orders
    add constraint orders_status_check
    check (status in (
      'draft',
      'waiting_materials',
      'ready_to_start',
      'in_production',
      'completed'
    ));
end $$;
