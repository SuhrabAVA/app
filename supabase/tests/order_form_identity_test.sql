-- Fixtures live in a subtransaction and are always rolled back.
do $test$
declare
  a uuid;
  b uuid;
  oid uuid;
  label text := '__form_identity_' || gen_random_uuid()::text || ' 1,5';
  payload jsonb;
  actual public.orders%rowtype;
  n integer;
begin
  begin
    insert into public.forms(series,number,size) values (label,1671,'29*8*3,5') returning id into a;
    insert into public.forms(series,number) values (label || ' adika',1) returning id into b;
    if public.resolve_order_form(null,label || ' 1671','Rommi',1) is distinct from a then
      raise exception 'Full label with digits did not resolve';
    end if;
    if public.resolve_order_form(null,null,null,1) is not null then
      raise exception 'Bare number must not resolve';
    end if;
    select product into payload from public.orders where product_type_id is not null limit 1;
    insert into public.orders(customer,order_date,product,has_form,is_old_form,new_form_no,form_series,form_code,status)
    values (label,now(),payload,true,true,1,'Rommi',label || ' 1671','draft')
    returning id into oid;
    select * into actual from public.orders where id=oid;
    if actual.form_id is distinct from a or actual.new_form_no <> 1671 then
      raise exception 'Legacy damaged INSERT was not canonicalized';
    end if;
    update public.forms set series=label || ' renamed',number=1672 where id=a;
    select * into actual from public.orders where id=oid;
    if actual.form_id is distinct from a or actual.new_form_no <> 1672
      or actual.form_series <> label || ' renamed' then
      raise exception 'Rename/renumber lost the link';
    end if;
    begin
      update public.orders set new_form_no=99999999,form_series='__missing__',form_code='__missing__' where id=oid;
      raise exception 'Invalid reference was accepted';
    exception when foreign_key_violation then null;
    end;
    -- Explicit UUID wins when switching from a previously assigned form.
    update public.orders set form_id=b where id=oid;
    select * into actual from public.orders where id=oid;
    if actual.form_id is distinct from b or actual.new_form_no <> 1 then
      raise exception 'UUID switch failed';
    end if;
    insert into public.documents(collection,data) values ('order_files',jsonb_build_object(
      'orderId',oid::text,'objectPath','__test__/' || oid::text || '.pdf','filename','test.pdf'));
    perform public.sync_order_form_files(oid);
    select count(*) into n from public.documents where collection='form_files'
      and data->>'formId'=b::text and data->>'objectPath'='__test__/' || oid::text || '.pdf';
    if n <> 1 then raise exception 'PDF missing or duplicated: %', n; end if;
    update public.orders set has_form=false where id=oid;
    select * into actual from public.orders where id=oid;
    if actual.form_id is not null or actual.new_form_no is not null or actual.form_series is not null
      or actual.form_code is not null then raise exception 'Detach left stale references'; end if;
    -- Conflicting code and series/number fail closed; explicit ID remains usable.
    update public.forms set code=label || ' unique-code' where id=b;
    if public.resolve_order_form(null,label || ' unique-code',label || ' renamed',1672) is not null then
      raise exception 'Ambiguous reference accepted';
    end if;
    if public.resolve_order_form(b,null,null,null) is distinct from b then
      raise exception 'ID lookup failed with duplicate numbers';
    end if;
    raise sqlstate 'ZX001' using message='Rollback successful test fixtures';
  exception when sqlstate 'ZX001' then null;
  end;
end;
$test$;
