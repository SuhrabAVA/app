-- Check that repairing form references does not alter any other order fields.
create temporary table form_repair_baseline on commit drop as
select id, md5((to_jsonb(o) - array['form_id','new_form_no','form_series','form_code','updated_at'])::text) fingerprint
from public.orders o;

-- Stable form identity, compatibility for legacy clients, and exact-only repair.
create or replace function public.resolve_order_form(
  p_form_id uuid default null,
  p_form_code text default null,
  p_form_series text default null,
  p_form_no integer default null
) returns uuid
language sql stable security invoker set search_path = public
as $$
  select case when count(*) = 1 then (array_agg(f.id))[1] end
  from public.forms f
  where (p_form_id is not null and f.id = p_form_id)
     or (p_form_id is null and (
       (nullif(btrim(p_form_code), '') is not null
         and (f.code = btrim(p_form_code)
           or concat(f.series, ' ', f.number) = btrim(p_form_code)))
       or (nullif(btrim(p_form_series), '') is not null
         and f.series = btrim(p_form_series) and f.number = p_form_no)
     ));
$$;
revoke all on function public.resolve_order_form(uuid,text,text,integer) from public, anon;
grant execute on function public.resolve_order_form(uuid,text,text,integer) to authenticated, service_role;

-- Only a single exact code / full label / series+number match is repaired.
-- No matching by customer, first digit, approximate name or bare number.
with matches as (
  select o.id, public.resolve_order_form(null, o.form_code, o.form_series, o.new_form_no) form_id
  from public.orders o where o.has_form and o.form_id is null
)
update public.orders o set form_id = m.form_id
from matches m where o.id = m.id and m.form_id is not null;

drop trigger if exists trg_orders_sync_form_fields on public.orders;
drop trigger if exists trg_orders_sync_form_no on public.orders;

create or replace function public.trg_orders_sync_form_fields()
returns trigger language plpgsql security invoker set search_path = public
as $$
declare
  v_id uuid;
  v_form public.forms%rowtype;
  v_refs_changed boolean := true;
begin
  if tg_op = 'UPDATE' then
    v_refs_changed := row(new.new_form_no, new.form_series, new.form_code)
      is distinct from row(old.new_form_no, old.form_series, old.form_code);
    -- Explicit detach, including the existing FK ON DELETE SET NULL.
    if old.form_id is not null and new.form_id is null and not v_refs_changed then
      new.has_form := false;
    end if;
  end if;

  if new.has_form is false then
    new.form_id := null;
    new.new_form_no := null;
    new.form_series := null;
    new.form_code := null;
    new.is_old_form := false;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.form_id is not distinct from old.form_id and v_refs_changed then
      -- An older client changes only text. Resolve the WHOLE reference.
      v_id := public.resolve_order_form(null, new.form_code, new.form_series, new.new_form_no);
    else
      v_id := public.resolve_order_form(new.form_id, new.form_code, new.form_series, new.new_form_no);
    end if;
  else
    v_id := public.resolve_order_form(new.form_id, new.form_code, new.form_series, new.new_form_no);
  end if;

  if v_id is null then
    -- Leave unrelated edits to pre-existing unresolved records possible.
    if tg_op = 'UPDATE' then
      if not v_refs_changed and new.form_id is not distinct from old.form_id
        and new.has_form is not distinct from old.has_form
        and new.is_old_form is not distinct from old.is_old_form then
        return new;
      end if;
    end if;
    -- New-form drafts can exist before a warehouse record is created.
    if new.form_id is null and new.new_form_no is null
      and nullif(btrim(new.form_series), '') is null
      and nullif(btrim(new.form_code), '') is null
      and not coalesce(new.is_old_form, false) then
      return new;
    end if;
    raise exception using errcode = '23503',
      message = 'Выберите существующую форму из списка склада: ссылка не найдена или неоднозначна';
  end if;

  select * into strict v_form from public.forms where id = v_id;
  new.has_form := true;
  new.form_id := v_id;
  new.new_form_no := v_form.number;
  new.form_series := v_form.series;
  new.form_code := v_form.code;
  return new;
end;
$$;

create trigger trg_orders_sync_form_fields
before insert or update of form_id, has_form, is_old_form, new_form_no, form_series, form_code
on public.orders for each row execute function public.trg_orders_sync_form_fields();

create or replace function public.sync_linked_order_form_fields()
returns trigger language plpgsql security invoker set search_path = public
as $$
begin
  update public.orders set form_id = new.id,
    new_form_no = new.number, form_series = new.series, form_code = new.code
  where form_id = new.id
    and row(new_form_no, form_series, form_code)
      is distinct from row(new.number, new.series, new.code);
  return new;
end;
$$;
create trigger trg_forms_sync_linked_orders
after update of series, number, code on public.forms
for each row execute function public.sync_linked_order_form_fields();

-- PDF metadata only; original Storage objects are neither copied nor deleted.
create or replace function public.sync_order_form_files(p_order_id uuid)
returns void language plpgsql security invoker set search_path = public
as $$
declare v_form_id uuid;
begin
  select form_id into v_form_id from public.orders where id = p_order_id;
  if v_form_id is null then return; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_form_id::text, 0));
  insert into public.documents(collection, data, created_by)
  select 'form_files',
    (d.data - 'orderId') || jsonb_build_object(
      'formId', v_form_id::text, 'source', 'order', 'orderId', p_order_id::text),
    d.created_by
  from public.documents d
  where d.collection = 'order_files' and d.data->>'orderId' = p_order_id::text
    and nullif(d.data->>'objectPath', '') is not null
    and not exists (
      select 1 from public.documents linked
      where linked.collection = 'form_files'
        and linked.data->>'formId' = v_form_id::text
        and linked.data->>'objectPath' = d.data->>'objectPath'
    );
end;
$$;
revoke all on function public.sync_order_form_files(uuid) from public, anon;
grant execute on function public.sync_order_form_files(uuid) to authenticated, service_role;

create or replace function public.trg_sync_order_form_files()
returns trigger language plpgsql security invoker set search_path = public
as $$
declare v_order_id uuid;
begin
  if tg_table_name = 'orders' then
    perform public.sync_order_form_files(new.id);
  elsif new.collection = 'order_files' then
    select id into v_order_id from public.orders where id::text = new.data->>'orderId';
    if v_order_id is not null then perform public.sync_order_form_files(v_order_id); end if;
  end if;
  return new;
end;
$$;
create trigger trg_orders_link_form_files
after insert or update of form_id on public.orders
for each row when (new.form_id is not null)
execute function public.trg_sync_order_form_files();
create trigger trg_documents_link_order_form_files
after insert or update of data, collection on public.documents
for each row when (new.collection = 'order_files')
execute function public.trg_sync_order_form_files();

do $$
declare r record;
begin
  for r in select id from public.orders where form_id is not null loop
    perform public.sync_order_form_files(r.id);
  end loop;
end;
$$;

revoke all on function public.trg_orders_sync_form_fields() from public, anon;
revoke all on function public.sync_linked_order_form_fields() from public, anon;
revoke all on function public.trg_sync_order_form_files() from public, anon;
grant execute on function public.trg_orders_sync_form_fields() to authenticated, service_role;
grant execute on function public.sync_linked_order_form_fields() to authenticated, service_role;
grant execute on function public.trg_sync_order_form_files() to authenticated, service_role;

do $$
begin
  if exists (
    select 1 from form_repair_baseline b
    left join public.orders o on o.id = b.id
    where o.id is null or b.fingerprint is distinct from
      md5((to_jsonb(o) - array['form_id','new_form_no','form_series','form_code','updated_at'])::text)
  ) then
    raise exception 'Form repair changed unrelated order data; transaction aborted';
  end if;
end;
$$;

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

