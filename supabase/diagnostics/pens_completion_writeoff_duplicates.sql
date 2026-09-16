-- READ ONLY. Run before 20260813_atomic_pens_completion_writeoff.sql.
-- Any returned row blocks the migration and requires manual investigation.
select
  order_id,
  count(*) as writeoff_count,
  array_agg(id order by created_at, id) as writeoff_ids,
  array_agg(item_id order by created_at, id) as item_ids,
  array_agg(qty order by created_at, id) as quantities
from public.warehouse_pens_writeoffs
where order_id is not null
group by order_id
having count(*) > 1
order by writeoff_count desc, order_id;

-- Summary for a deployment gate. duplicate_order_count must equal zero.
select count(*) as duplicate_order_count
from (
  select order_id
  from public.warehouse_pens_writeoffs
  where order_id is not null
  group by order_id
  having count(*) > 1
) duplicates;
