-- LOCAL/EPHEMERAL DATABASE ONLY. NEVER run this against staging or production.
-- Prerequisite: apply 20260813_atomic_pens_completion_writeoff.sql to a local
-- disposable database and provide a completed fixture order that has a valid
-- handle/actual_qty but no warehouse_pens_writeoffs row.
--
-- psql example:
--   psql "$LOCAL_DATABASE_URL" \
--     -v order_id='00000000-0000-0000-0000-000000000000' \
--     -f supabase/tests/20260813_pens_completion_writeoff_idempotency.sql
--
-- The transaction always rolls back, including the write-off row and the pens
-- quantity change made by the existing insert trigger.

\if :{?order_id}
\else
  \echo 'order_id psql variable is required'
  \quit 3
\endif

begin;

select set_config('easy_pack_test.order_id', :'order_id', true);

do $precondition$
begin
  if not exists (
    select 1
    from public.orders o
    where o.id::text = current_setting('easy_pack_test.order_id')
      and lower(coalesce(o.status, '')) = 'completed'
      and coalesce(o.actual_qty, o.shipped_qty, 0) > 0
      and nullif(trim(coalesce(o.handle, '')), '') is not null
  ) then
    raise exception 'fixture order is absent or not eligible';
  end if;

  if exists (
    select 1
    from public.warehouse_pens_writeoffs w
    where w.order_id::text = current_setting('easy_pack_test.order_id')
  ) then
    raise exception 'fixture order already has a pens write-off';
  end if;
end
$precondition$;

create temporary table pens_writeoff_test_results (
  call_no integer primary key,
  inserted boolean not null
) on commit drop;

insert into pens_writeoff_test_results
values (
  1,
  public.record_order_pens_completion_writeoff(
    current_setting('easy_pack_test.order_id'),
    'local-test'
  )
);

insert into pens_writeoff_test_results
values (
  2,
  public.record_order_pens_completion_writeoff(
    current_setting('easy_pack_test.order_id'),
    'local-test'
  )
);

do $assertions$
declare
  v_count integer;
  v_first boolean;
  v_second boolean;
begin
  select
    bool_or(inserted) filter (where call_no = 1),
    bool_or(inserted) filter (where call_no = 2)
    into v_first, v_second
    from pens_writeoff_test_results;

  if v_first is not true then
    raise exception 'first call did not insert';
  end if;
  if v_second is not false then
    raise exception 'second call was not an idempotent no-op';
  end if;

  select count(*)
    into v_count
    from public.warehouse_pens_writeoffs w
   where w.order_id::text = current_setting('easy_pack_test.order_id');

  if v_count <> 1 then
    raise exception 'expected one write-off, found %', v_count;
  end if;
end
$assertions$;

rollback;
