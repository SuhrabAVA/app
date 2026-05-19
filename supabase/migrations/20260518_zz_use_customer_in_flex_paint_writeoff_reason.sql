-- Show the customer name instead of the order id in flex-printing paint write-off reasons.

create or replace function public.apply_customer_to_flex_paint_writeoff_reason()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix constant text := 'Списание флексопечати по заказу ';
  v_queue_suffix constant text := ' из очереди';
  v_source_order_id text;
  v_reason_suffix text := '';
  v_customer text;
begin
  if new.reason is null or new.reason not like v_prefix || '%' then
    return new;
  end if;

  v_source_order_id := trim(substr(new.reason, char_length(v_prefix) + 1));
  if v_source_order_id = '' then
    return new;
  end if;

  if right(v_source_order_id, char_length(v_queue_suffix)) = v_queue_suffix then
    v_source_order_id := trim(left(v_source_order_id, char_length(v_source_order_id) - char_length(v_queue_suffix)));
    v_reason_suffix := v_queue_suffix;
  end if;

  if v_source_order_id = '' then
    return new;
  end if;

  select nullif(trim(o.customer), '')
    into v_customer
    from public.orders o
   where o.id::text = v_source_order_id
   limit 1;

  if v_customer is not null then
    new.reason := format('%s%s%s', v_prefix, v_customer, v_reason_suffix);
  end if;

  return new;
end;
$$;

drop trigger if exists apply_customer_to_flex_paint_writeoff_reason_before_insert
  on public.paints_writeoffs;

create trigger apply_customer_to_flex_paint_writeoff_reason_before_insert
before insert on public.paints_writeoffs
for each row
execute function public.apply_customer_to_flex_paint_writeoff_reason();
