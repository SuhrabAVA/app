-- Persist order_paints through an RPC so text parameters from Flutter are cast to
-- the database-native order_paints.order_id type before insert. This avoids
-- Postgres 42804 on installations where order_id is uuid.

create or replace function public.save_order_paints(
  p_order_id text,
  p_paints jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id public.orders.id%type;
  v_order_id_uuid uuid;
  v_order_paints_order_id_type text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := trim(p_order_id);

  if p_paints is null then
    p_paints := '[]'::jsonb;
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_order_paints_order_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'order_paints'
     and a.attname = 'order_id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_order_paints_order_id_type is null then
    raise exception 'public.order_paints.order_id column was not found';
  end if;

  if v_order_paints_order_id_type = 'uuid' then
    v_order_id_uuid := trim(p_order_id)::uuid;

    execute 'delete from public.order_paints where order_id = $1'
      using v_order_id_uuid;

    execute $sql$
      insert into public.order_paints(order_id, name, info, qty_kg)
      select
        $1,
        nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') as name,
        nullif(trim(coalesce(item->>'info', item->>'memo')), '') as info,
        case
          when nullif(trim(item->>'qty_kg'), '') is not null then
            replace(trim(item->>'qty_kg'), ',', '.')::double precision
          when nullif(trim(item->>'qtyGrams'), '') is not null then
            replace(trim(item->>'qtyGrams'), ',', '.')::double precision / 1000
          when nullif(trim(item->>'qty_grams'), '') is not null then
            replace(trim(item->>'qty_grams'), ',', '.')::double precision / 1000
          else null
        end as qty_kg
      from jsonb_array_elements($2) as item
      where nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') is not null
    $sql$ using v_order_id_uuid, p_paints;
  else
    execute 'delete from public.order_paints where order_id = $1'
      using trim(p_order_id);

    execute $sql$
      insert into public.order_paints(order_id, name, info, qty_kg)
      select
        $1,
        nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') as name,
        nullif(trim(coalesce(item->>'info', item->>'memo')), '') as info,
        case
          when nullif(trim(item->>'qty_kg'), '') is not null then
            replace(trim(item->>'qty_kg'), ',', '.')::double precision
          when nullif(trim(item->>'qtyGrams'), '') is not null then
            replace(trim(item->>'qtyGrams'), ',', '.')::double precision / 1000
          when nullif(trim(item->>'qty_grams'), '') is not null then
            replace(trim(item->>'qty_grams'), ',', '.')::double precision / 1000
          else null
        end as qty_kg
      from jsonb_array_elements($2) as item
      where nullif(trim(coalesce(item->>'name', item->>'paint_name')), '') is not null
    $sql$ using trim(p_order_id), p_paints;
  end if;
end;
$$;

grant execute on function public.save_order_paints(text, jsonb)
to authenticated, anon;
