-- LOCAL DISPOSABLE DATABASE ONLY. NEVER run on staging or production.
-- Start this session first with -v order_id=... . While it sleeps, start the
-- matching session_b script with the same fixture order_id.

\if :{?order_id}
\else
  \echo 'order_id psql variable is required'
  \quit 3
\endif

begin;
select set_config('easy_pack_test.order_id', :'order_id', true);

do $precondition$
begin
  if exists (
    select 1
    from public.warehouse_pens_writeoffs
    where order_id::text = current_setting('easy_pack_test.order_id')
  ) then
    raise exception 'fixture order already has a pens write-off';
  end if;
end
$precondition$;

select public.record_order_pens_completion_writeoff(
  current_setting('easy_pack_test.order_id'),
  'local-concurrency-a'
) as session_a_inserted;

-- Session B must block on the order/unique key until this transaction commits.
select pg_sleep(10);
commit;
