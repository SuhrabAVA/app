begin;

-- Historical application code has treated order_id as the natural key since
-- October 2025. Do not guess which historical row is correct: fail closed if
-- that invariant is already violated.
do $preflight$
begin
  if to_regclass('public.orders') is null
     or to_regclass('public.warehouse_pens') is null
     or to_regclass('public.warehouse_pens_writeoffs') is null then
    raise exception using
      message = 'pens completion write-off prerequisites are missing',
      hint = 'Verify orders, warehouse_pens, and warehouse_pens_writeoffs before retrying.';
  end if;

  if exists (
    select 1
    from (values
      ('orders', 'id'),
      ('orders', 'status'),
      ('orders', 'handle'),
      ('orders', 'actual_qty'),
      ('orders', 'shipped_qty'),
      ('orders', 'customer'),
      ('warehouse_pens', 'id'),
      ('warehouse_pens', 'name'),
      ('warehouse_pens', 'color'),
      ('warehouse_pens', 'created_at'),
      ('warehouse_pens_writeoffs', 'id'),
      ('warehouse_pens_writeoffs', 'item_id'),
      ('warehouse_pens_writeoffs', 'qty'),
      ('warehouse_pens_writeoffs', 'order_id'),
      ('warehouse_pens_writeoffs', 'reason'),
      ('warehouse_pens_writeoffs', 'by_name')
    ) required(table_name, column_name)
    left join information_schema.columns existing
      on existing.table_schema = 'public'
     and existing.table_name = required.table_name
     and existing.column_name = required.column_name
    where existing.column_name is null
  ) then
    raise exception using
      message = 'pens completion write-off prerequisite columns are missing',
      hint = 'Compare the local schema with the required columns in migration 20260813 before retrying.';
  end if;

  if exists (
    select 1
    from public.warehouse_pens_writeoffs
    where order_id is not null
    group by order_id
    having count(*) > 1
  ) then
    raise exception using
      message = 'duplicate warehouse_pens_writeoffs.order_id values block the migration',
      hint = 'Run supabase/diagnostics/pens_completion_writeoff_duplicates.sql and remediate manually; this migration never deletes data.';
  end if;
end
$preflight$;

create unique index if not exists warehouse_pens_writeoffs_one_per_order_uidx
  on public.warehouse_pens_writeoffs (order_id)
  where order_id is not null;

create or replace function public.record_order_pens_completion_writeoff(
  p_order_id text,
  p_actor text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_order public.orders%rowtype;
  v_item_id public.warehouse_pens.id%type;
  v_writeoff_id public.warehouse_pens_writeoffs.id%type;
  v_handle text;
  v_qty numeric;
  v_reason text;
  v_actor text;
begin
  if nullif(trim(p_order_id), '') is null then
    raise exception 'order_id is required';
  end if;

  select o.*
    into v_order
    from public.orders o
   where o.id::text = trim(p_order_id)
   for update;

  if not found then
    raise exception 'order % was not found', p_order_id;
  end if;

  if lower(coalesce(v_order.status, '')) <> 'completed' then
    return false;
  end if;

  v_handle := trim(coalesce(v_order.handle, ''));
  v_qty := coalesce(v_order.actual_qty, v_order.shipped_qty, 0);
  v_reason := nullif(trim(coalesce(v_order.customer, '')), '');
  v_actor := nullif(trim(coalesce(
    p_actor,
    auth.jwt() ->> 'user_name',
    auth.jwt() ->> 'name',
    auth.jwt() ->> 'email'
  )), '');

  if v_handle = '' or v_handle = '-' or v_qty <= 0 then
    return false;
  end if;

  select p.id
    into v_item_id
    from public.warehouse_pens p
   where lower(trim(concat_ws(
           ' ' || chr(8226) || ' ',
           nullif(trim(p.name), ''),
           nullif(trim(p.color), '')
         ))) = lower(v_handle)
   order by p.created_at, p.id
   limit 1;

  if v_item_id is null then
    select p.id
      into v_item_id
      from public.warehouse_pens p
     where lower(trim(p.name)) = lower(v_handle)
     order by p.created_at, p.id
     limit 1;
  end if;

  if v_item_id is null then
    return false;
  end if;

  insert into public.warehouse_pens_writeoffs (
    item_id,
    qty,
    order_id,
    reason,
    by_name
  ) values (
    v_item_id,
    v_qty,
    v_order.id,
    v_reason,
    v_actor
  )
  on conflict (order_id) where order_id is not null do nothing
  returning id into v_writeoff_id;

  return v_writeoff_id is not null;
end
$function$;

revoke all on function public.record_order_pens_completion_writeoff(text, text)
  from public, anon;
grant execute on function public.record_order_pens_completion_writeoff(text, text)
  to authenticated, service_role;

create or replace function public.record_pens_writeoff_on_order_completion()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $trigger_function$
begin
  if lower(coalesce(new.status, '')) <> 'completed' then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if lower(coalesce(old.status, '')) = 'completed' then
      return new;
    end if;
  end if;

  perform public.record_order_pens_completion_writeoff(new.id::text, null);
  return new;
end
$trigger_function$;

revoke all on function public.record_pens_writeoff_on_order_completion()
  from public, anon, authenticated;

do $create_trigger$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.orders'::regclass
      and tgname = 'orders_record_pens_writeoff_on_completion'
      and not tgisinternal
  ) then
    execute $ddl$
      create trigger orders_record_pens_writeoff_on_completion
      after insert or update on public.orders
      for each row
      execute function public.record_pens_writeoff_on_order_completion()
    $ddl$;
  end if;
end
$create_trigger$;

commit;
