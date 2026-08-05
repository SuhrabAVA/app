-- Acceptance-only проверки additive M0.
-- Запускать вручную на ветке/стенде после M0 и до M1. Всегда ROLLBACK.

begin;

do $m0_schema$
declare
  v_nullable text;
  v_count integer;
  v_enabled boolean;
begin
  select c.is_nullable
    into v_nullable
    from information_schema.columns c
   where c.table_schema = 'public'
     and c.table_name = 'warehouse_categories'
     and c.column_name = 'archived_at';

  if v_nullable is distinct from 'YES' then
    raise exception 'M0: warehouse_categories.archived_at отсутствует или не nullable.';
  end if;

  if to_regclass('public.app_capabilities') is null then
    raise exception 'M0: public.app_capabilities отсутствует.';
  end if;

  select count(*), bool_or(c.enabled)
    into v_count, v_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1';

  if v_count <> 1 or v_enabled is distinct from false then
    raise exception 'M0: capability count=%, enabled=%.', v_count, v_enabled;
  end if;
end;
$m0_schema$;

do $m0_privileges$
declare
  v_public_acl integer;
begin
  if not has_table_privilege(
    'authenticated', 'public.app_capabilities', 'SELECT'
  ) then
    raise exception 'M0: authenticated не может читать capability.';
  end if;

  if has_table_privilege(
       'authenticated', 'public.app_capabilities', 'INSERT'
     ) or has_table_privilege(
       'authenticated', 'public.app_capabilities', 'UPDATE'
     ) or has_table_privilege(
       'authenticated', 'public.app_capabilities', 'DELETE'
     ) then
    raise exception 'M0: authenticated имеет write-доступ к capability.';
  end if;

  if has_table_privilege('anon', 'public.app_capabilities', 'SELECT')
     or has_table_privilege('anon', 'public.app_capabilities', 'INSERT')
     or has_table_privilege('anon', 'public.app_capabilities', 'UPDATE')
     or has_table_privilege('anon', 'public.app_capabilities', 'DELETE') then
    raise exception 'M0: anon имеет доступ к capability.';
  end if;

  select count(*)
    into v_public_acl
    from pg_catalog.pg_class c
    cross join lateral pg_catalog.aclexplode(
      coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) a
   where c.oid = 'public.app_capabilities'::regclass
     and a.grantee = 0;

  if v_public_acl <> 0 then
    raise exception 'M0: PUBLIC имеет grants на app_capabilities.';
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_policy p
      join pg_catalog.pg_class c on c.oid = p.polrelid
     where c.oid = 'public.app_capabilities'::regclass
       and p.polname = 'app_capabilities_authenticated_select'
       and p.polcmd = 'r'
       and 'authenticated'::regrole = any (p.polroles)
  ) then
    raise exception 'M0: authenticated SELECT policy отсутствует.';
  end if;
end;
$m0_privileges$;

-- M0 не должна содержать ни одного объекта основной схемы.
do $m0_is_additive_only$
begin
  if exists (
    select 1
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name = 'orders'
       and c.column_name in ('product_type_id', 'stage_config_id')
  ) then
    raise exception 'M0: orders уже содержит колонку M1.';
  end if;

  if to_regclass('public.product_type_configs') is not null
     or to_regclass('public.order_form_blocks') is not null
     or to_regclass('public.product_type_form_blocks') is not null
     or to_regclass('public.product_type_config_write_guards') is not null then
    raise exception 'M0: обнаружены таблицы M1.';
  end if;

  if to_regclass('public.warehouse_categories_title_normalized_uq') is not null
     or exists (
       select 1
         from pg_catalog.pg_constraint c
        where c.conrelid = 'public.warehouse_categories'::regclass
          and c.conname = 'warehouse_categories_title_not_blank_check'
     ) then
    raise exception 'M0: title constraints M1 появились преждевременно.';
  end if;

  if exists (
    select 1
      from pg_catalog.pg_trigger t
     where t.tgrelid = 'public.orders'::regclass
       and t.tgname in (
         'trg_orders_00_mark_explicit_product_type_id',
         'trg_orders_10_sync_product_type',
         'trg_orders_99_clear_product_type_marker'
       )
       and not t.tgisinternal
  ) then
    raise exception 'M0: marker triggers M1 появились преждевременно.';
  end if;
end;
$m0_is_additive_only$;

rollback;
