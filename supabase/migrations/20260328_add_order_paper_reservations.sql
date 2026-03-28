-- Поддержка нескольких бумаг в заказе и резерва бумаги.

alter table if exists public.orders
  add column if not exists material_list jsonb not null default '[]'::jsonb;

create table if not exists public.order_paper_reservations (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  paper_id text not null,
  qty double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists order_paper_reservations_order_paper_idx
  on public.order_paper_reservations(order_id, paper_id);

create index if not exists order_paper_reservations_paper_idx
  on public.order_paper_reservations(paper_id);

alter table public.order_paper_reservations enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paper_reservations' and policyname='order_paper_reservations_select'
  ) then
    create policy order_paper_reservations_select on public.order_paper_reservations
      for select to authenticated, anon using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paper_reservations' and policyname='order_paper_reservations_write'
  ) then
    create policy order_paper_reservations_write on public.order_paper_reservations
      for all to authenticated using (true) with check (true);
  end if;
end $$;
