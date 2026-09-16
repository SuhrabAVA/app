-- LOCAL DISPOSABLE DATABASE ONLY. NEVER run on staging or production.
-- Start during session_a's pg_sleep with the same -v order_id=... value.

\if :{?order_id}
\else
  \echo 'order_id psql variable is required'
  \quit 3
\endif

begin;
select set_config('easy_pack_test.order_id', :'order_id', true);

create temporary table pens_concurrency_result (
  inserted boolean not null
) on commit drop;

insert into pens_concurrency_result
select public.record_order_pens_completion_writeoff(
  current_setting('easy_pack_test.order_id'),
  'local-concurrency-b'
);

do $assertions$
declare
  v_inserted boolean;
  v_count integer;
begin
  select inserted into v_inserted from pens_concurrency_result;
  if v_inserted is not false then
    raise exception 'session B inserted a duplicate write-off';
  end if;

  select count(*) into v_count
  from public.warehouse_pens_writeoffs
  where order_id::text = current_setting('easy_pack_test.order_id');
  if v_count <> 1 then
    raise exception 'expected one concurrent write-off, found %', v_count;
  end if;
end
$assertions$;

rollback;
