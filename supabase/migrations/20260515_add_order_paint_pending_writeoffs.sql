-- Persistent queue for pending paint write-offs created while completing order stages.

create table if not exists public.order_paint_pending_writeoffs (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.orders(id) on delete cascade,
  task_id text,
  stage_id text,
  stage_name text,
  paint_id text references public.paints(id),
  paint_name text,
  planned_amount double precision,
  actual_used_amount double precision,
  unit text not null default 'г',
  status text not null default 'pending' check (status in ('pending', 'written_off')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  written_off_at timestamptz,
  created_by text,
  written_off_by text,
  comment text,
  constraint order_paint_pending_writeoffs_amounts_nonnegative check (
    (planned_amount is null or planned_amount >= 0)
    and (actual_used_amount is null or actual_used_amount >= 0)
  ),
  constraint order_paint_pending_writeoffs_has_paint check (
    paint_id is not null or coalesce(trim(paint_name), '') <> ''
  ),
  constraint order_paint_pending_writeoffs_written_off_at check (
    status <> 'written_off' or written_off_at is not null
  )
);

create index if not exists order_paint_pending_writeoffs_status_paint_idx
  on public.order_paint_pending_writeoffs(status, paint_id);

create index if not exists order_paint_pending_writeoffs_order_status_idx
  on public.order_paint_pending_writeoffs(order_id, status);

-- If the source order_paints table is present, bind pending write-offs to its row id
-- using the real type of public.order_paints.id. This keeps the migration safe for
-- installations where order_paints is managed outside of this migrations folder.
do $$
declare
  v_order_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_order_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'order_paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_order_paint_id_type is not null then
    if not exists (
      select 1
        from information_schema.columns
       where table_schema = 'public'
         and table_name = 'order_paint_pending_writeoffs'
         and column_name = 'order_paint_id'
    ) then
      execute format(
        'alter table public.order_paint_pending_writeoffs add column order_paint_id %s',
        v_order_paint_id_type
      );
    end if;

    if not exists (
      select 1
        from pg_constraint
       where conname = 'order_paint_pending_writeoffs_order_paint_id_fkey'
         and conrelid = 'public.order_paint_pending_writeoffs'::regclass
    ) then
      alter table public.order_paint_pending_writeoffs
        add constraint order_paint_pending_writeoffs_order_paint_id_fkey
        foreign key (order_paint_id) references public.order_paints(id) on delete cascade;
    end if;

    create unique index if not exists order_paint_pending_writeoffs_order_paint_pending_uidx
      on public.order_paint_pending_writeoffs(order_paint_id)
      where status = 'pending' and order_paint_id is not null;
  end if;
end $$;

create unique index if not exists order_paint_pending_writeoffs_order_stage_paint_pending_uidx
  on public.order_paint_pending_writeoffs(
    order_id,
    coalesce(task_id, ''),
    coalesce(stage_id, ''),
    paint_id
  )
  where status = 'pending' and paint_id is not null;

create unique index if not exists order_paint_pending_writeoffs_order_stage_paint_name_pending_uidx
  on public.order_paint_pending_writeoffs(
    order_id,
    coalesce(task_id, ''),
    coalesce(stage_id, ''),
    lower(trim(paint_name))
  )
  where status = 'pending'
    and paint_id is null
    and coalesce(trim(paint_name), '') <> '';

alter table public.order_paint_pending_writeoffs enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paint_pending_writeoffs' and policyname='order_paint_pending_writeoffs_select'
  ) then
    create policy order_paint_pending_writeoffs_select on public.order_paint_pending_writeoffs
      for select to authenticated, anon using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='order_paint_pending_writeoffs' and policyname='order_paint_pending_writeoffs_write'
  ) then
    create policy order_paint_pending_writeoffs_write on public.order_paint_pending_writeoffs
      for all to authenticated using (true) with check (true);
  end if;
end $$;
