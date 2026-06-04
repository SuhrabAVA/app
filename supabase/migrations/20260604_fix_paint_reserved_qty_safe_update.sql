-- Avoid safe-update failures when paint reservation RPCs have no touched paints.
-- Supabase/PostgREST can run with pg_safeupdate enabled; in that mode the
-- old NULL branch updated the whole paints table without a WHERE clause.

do $$
declare
  v_paint_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_paint_id_type is null then
    raise exception 'public.paints.id column not found';
  end if;

  execute 'drop function if exists public.recalculate_paint_reserved_qty(' || v_paint_id_type || '[])';
  execute format($sql$
    create function public.recalculate_paint_reserved_qty(p_paint_ids %1$s[] default null)
    returns void
    language plpgsql
    security definer
    set search_path = public
    as $fn$
    declare
      v_paint_ids %1$s[];
    begin
      select array_agg(distinct paint_id)
        into v_paint_ids
        from unnest(p_paint_ids) as paint_id
       where paint_id is not null;

      if coalesce(array_length(v_paint_ids, 1), 0) = 0 then
        return;
      end if;

      update paints p
         set reserved_qty = coalesce((
               select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
                 from order_paint_reservations r
                where r.paint_id = p.id
             ), 0)
       where p.id = any(v_paint_ids);
    end;
    $fn$
  $sql$, v_paint_id_type);
  execute 'grant execute on function public.recalculate_paint_reserved_qty(' || v_paint_id_type || '[]) to authenticated, anon';
end $$;
