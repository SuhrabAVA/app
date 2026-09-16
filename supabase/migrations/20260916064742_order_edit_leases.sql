-- Exclusive editor capabilities; shared Supabase login is NOT an editor identity.
create schema if not exists order_edit_private;
revoke all on schema order_edit_private from public, anon;
grant usage on schema order_edit_private to authenticated;

create table order_edit_private.leases (
  order_id uuid primary key references public.orders(id) on delete cascade,
  token uuid not null,
  user_id uuid not null,
  editor_name text not null,
  expires_at timestamptz not null
);
alter table order_edit_private.leases enable row level security;
revoke all on order_edit_private.leases from public, anon, authenticated;

create function order_edit_private.acquire(p_order_id uuid, p_token uuid, p_editor_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v order_edit_private.leases; acquired boolean := false;
begin
  if auth.uid() is null or p_token is null then
    raise exception 'Требуется вход в приложение' using errcode = '42501';
  end if;
  if not exists (select 1 from public.orders where id = p_order_id) then
    raise exception 'Заказ не найден' using errcode = 'P0002';
  end if;
  insert into order_edit_private.leases as l
    (order_id, token, user_id, editor_name, expires_at)
    values (p_order_id, p_token, auth.uid(), left(coalesce(nullif(trim(p_editor_name), ''), 'Сотрудник'), 200),
      clock_timestamp() + interval '90 seconds')
  on conflict (order_id) do update set
    token = excluded.token, user_id = excluded.user_id,
    editor_name = excluded.editor_name, expires_at = excluded.expires_at
  where l.expires_at <= clock_timestamp()
    or (l.token = p_token and l.user_id = auth.uid())
  returning * into v;
  acquired := found;
  if not acquired then
    select * into v from order_edit_private.leases where order_id = p_order_id;
  end if;
  return jsonb_build_object('acquired', acquired, 'editor_name', v.editor_name);
end $$;

create function public.acquire_order_edit(p_order_id uuid, p_token uuid, p_editor_name text)
returns jsonb language sql security invoker set search_path = '' as $$
  select order_edit_private.acquire(p_order_id, p_token, p_editor_name);
$$;

create function order_edit_private.renew(p_order_id uuid, p_token uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Требуется вход' using errcode = '42501'; end if;
  update order_edit_private.leases set expires_at = clock_timestamp() + interval '90 seconds'
    where order_id = p_order_id and token = p_token and user_id = auth.uid()
      and expires_at > clock_timestamp();
  return found;
end $$;
create function public.renew_order_edit(p_order_id uuid, p_token uuid)
returns boolean language sql security invoker set search_path = '' as $$
  select order_edit_private.renew(p_order_id, p_token);
$$;

create function order_edit_private.release(p_order_id uuid, p_token uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Требуется вход' using errcode = '42501'; end if;
  -- Keep a tombstone: a late save from an old editor must never become valid.
  update order_edit_private.leases set expires_at = '-infinity'
    where order_id = p_order_id and token = p_token and user_id = auth.uid();
end $$;
create function public.release_order_edit(p_order_id uuid, p_token uuid)
returns void language sql security invoker set search_path = '' as $$
  select order_edit_private.release(p_order_id, p_token);
$$;

create function order_edit_private.active_locks()
returns table(order_id uuid, editor_name text)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Требуется вход' using errcode = '42501'; end if;
  return query select l.order_id, l.editor_name from order_edit_private.leases l
    where l.expires_at > clock_timestamp();
end $$;
create function public.active_order_edits()
returns table(order_id uuid, editor_name text)
language sql security invoker set search_path = '' as $$
  select * from order_edit_private.active_locks();
$$;

-- Serialize every protected write with acquisition/renewal/release. The lease
-- cannot be handed to another editor in the middle of a SQL transaction.
--
-- Блокировка кусается только пока заказ действительно держат открытым. После
-- release (или после истечения 90 секунд) заказ снова пишется кем угодно —
-- в том числе устройством со старой сборкой, которая про блокировку не знает.
-- Иначе один открытый заказ навсегда отрезал бы от него все необновлённые
-- планшеты, а обновлять их приходится вручную и не одновременно.
create function order_edit_private.check_write(p_order_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v order_edit_private.leases; supplied text;
begin
  -- Internal maintenance, SQL migrations and service-role jobs have no auth uid.
  if auth.uid() is null then return; end if;
  supplied := (coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb
    ->> 'x-order-edit-tokens')::jsonb ->> p_order_id::text;
  select * into v from order_edit_private.leases where order_id = p_order_id for update;
  if not found then
    if supplied is not null then raise exception 'Блокировка заказа потеряна' using errcode = '55P03'; end if;
    return;
  end if;
  -- `supplied is not null` ловит запоздавшего редактора: его ключ уже
  -- освобождён или просрочен, и запись должна быть отклонена, а не пропущена.
  if supplied is not null or v.expires_at > clock_timestamp() then
    if supplied is distinct from v.token::text or v.user_id <> auth.uid()
       or v.expires_at <= clock_timestamp() then
      raise exception 'Заказ редактируется другим сотрудником или блокировка истекла. Откройте заказ заново.'
        using errcode = '55P03';
    end if;
  end if;
end $$;

create function order_edit_private.guard_order()
returns trigger language plpgsql security definer set search_path = '' as $$
declare operational text[] := array['updated_at','actual_qty','shipped_at','shipped_by','shipped_qty',
  'completed_at','paper_written_off_at','status','has_material_shortage','material_shortage_message','promised_at'];
begin
  if tg_op = 'DELETE' then
    perform order_edit_private.check_write(old.id);
    return old;
  end if;
  -- Производственные показатели и отгрузка идут мимо блокировки: цех работает
  -- по заказу и тогда, когда менеджер держит форму открытой.
  if (to_jsonb(new) - operational) is distinct from (to_jsonb(old) - operational) then
    perform order_edit_private.check_write(new.id);
  end if;
  return new;
end $$;
create trigger orders_edit_guard before update or delete on public.orders
for each row execute function order_edit_private.guard_order();

create function order_edit_private.guard_child()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' then perform order_edit_private.check_write(old.order_id); end if;
  if tg_op <> 'DELETE' then
    perform order_edit_private.check_write(new.order_id);
    return new;
  end if;
  return old;
end $$;
create trigger order_paints_edit_guard before insert or update or delete on public.order_paints
for each row execute function order_edit_private.guard_child();
create trigger order_files_edit_guard before insert or update or delete on public.order_files
for each row execute function order_edit_private.guard_child();
create trigger production_plans_edit_guard before insert or update or delete on public.production_plans
for each row execute function order_edit_private.guard_child();
create trigger prod_plans_edit_guard before insert or update or delete on public.prod_plans
for each row execute function order_edit_private.guard_child();

create function order_edit_private.guard_plan_stage()
returns trigger language plpgsql security definer set search_path = '' as $$
declare oid uuid;
begin
  if tg_op <> 'INSERT' then
    select order_id into oid from public.prod_plans where id = old.plan_id;
    if oid is not null then perform order_edit_private.check_write(oid); end if;
  end if;
  if tg_op <> 'DELETE' then
    select order_id into oid from public.prod_plans where id = new.plan_id;
    if oid is not null then perform order_edit_private.check_write(oid); end if;
    return new;
  end if;
  return old;
end $$;
-- Stage execution can continue. Only editing the route requires the editor.
create trigger prod_plan_stages_edit_guard before insert or delete or
update of plan_id,template_stage_id,seq,name,note,position_id,workplace_id,stage_id,stage_group_key,step_no
on public.prod_plan_stages for each row execute function order_edit_private.guard_plan_stage();

revoke all on all functions in schema order_edit_private from public, anon, authenticated;
-- check_write вызывается только из триггеров (security definer) — клиенту он
-- не нужен и намеренно остаётся без grant.
grant execute on function order_edit_private.acquire(uuid,uuid,text),
  order_edit_private.renew(uuid,uuid), order_edit_private.release(uuid,uuid),
  order_edit_private.active_locks() to authenticated;
revoke all on function public.acquire_order_edit(uuid,uuid,text), public.renew_order_edit(uuid,uuid),
  public.release_order_edit(uuid,uuid), public.active_order_edits() from public, anon;
grant execute on function public.acquire_order_edit(uuid,uuid,text), public.renew_order_edit(uuid,uuid),
  public.release_order_edit(uuid,uuid), public.active_order_edits() to authenticated;
