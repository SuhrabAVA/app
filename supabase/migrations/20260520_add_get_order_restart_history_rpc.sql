create or replace function public.get_order_restart_history(
  p_order_id text,
  p_limit integer default 200
)
returns table (
  id text,
  restarted_from_order_id text,
  completed_at timestamptz,
  archived_at timestamptz,
  updated_at timestamptz,
  depth integer
)

language plpgsql
stable
as $$
declare
  v_limit integer := greatest(coalesce(p_limit, 200), 1);
  has_completed boolean;
  has_archived boolean;
  has_updated boolean;
  completed_expr text;
  archived_expr text;
  updated_expr text;
  sql text;
begin
  select exists (
           select 1
           from information_schema.columns
           where table_schema = 'public'
             and table_name = 'orders'
             and column_name = 'completed_at'
         ),
         exists (
           select 1
           from information_schema.columns
           where table_schema = 'public'
             and table_name = 'orders'
             and column_name = 'archived_at'
         ),
         exists (
           select 1
           from information_schema.columns
           where table_schema = 'public'
             and table_name = 'orders'
             and column_name = 'updated_at'
         )
    into has_completed, has_archived, has_updated;

  completed_expr := case when has_completed then 'o.completed_at' else 'null::timestamptz' end;
  archived_expr := case when has_archived then 'o.archived_at' else 'null::timestamptz' end;
  updated_expr := case when has_updated then 'o.updated_at' else 'null::timestamptz' end;

  sql := format($fmt$
    with recursive chain as (
      select
        o.id,
        o.restarted_from_order_id,
        %1$s as completed_at,
        %2$s as archived_at,
        %3$s as updated_at,
        0 as depth,
        array[o.id]::text[] as visited
      from public.orders o
      where o.id = $1

      union all

      select
        parent.id,
        parent.restarted_from_order_id,
        %4$s as completed_at,
        %5$s as archived_at,
        %6$s as updated_at,
        chain.depth + 1,
        chain.visited || parent.id
      from chain
      join public.orders parent
        on parent.id = chain.restarted_from_order_id
      where chain.depth < $2 - 1
        and not parent.id = any(chain.visited)
    )
    select
      c.id,
      c.restarted_from_order_id,
      c.completed_at,
      c.archived_at,
      c.updated_at,
      c.depth
    from chain c
    where c.depth > 0
    order by coalesce(c.completed_at, c.archived_at, c.updated_at) asc nulls first,
             c.depth desc
    limit $2
  $fmt$,
  completed_expr,
  archived_expr,
  updated_expr,
  replace(completed_expr, 'o.', 'parent.'),
  replace(archived_expr, 'o.', 'parent.'),
  replace(updated_expr, 'o.', 'parent.'));

  return query execute sql using p_order_id, v_limit;
end;

$$;
