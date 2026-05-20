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
language sql
stable
as $$
  with recursive chain as (
    select
      o.id,
      o.restarted_from_order_id,
      o.completed_at,
      o.archived_at,
      o.updated_at,
      0 as depth,
      array[o.id]::text[] as visited
    from public.orders o
    where o.id = p_order_id

    union all

    select
      parent.id,
      parent.restarted_from_order_id,
      parent.completed_at,
      parent.archived_at,
      parent.updated_at,
      chain.depth + 1,
      chain.visited || parent.id
    from chain
    join public.orders parent
      on parent.id = chain.restarted_from_order_id
    where chain.depth < greatest(coalesce(p_limit, 200), 1) - 1
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
  limit greatest(coalesce(p_limit, 200), 1);
$$;
