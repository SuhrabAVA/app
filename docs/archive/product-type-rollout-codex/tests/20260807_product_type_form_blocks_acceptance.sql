-- Acceptance-only проверки для 20260807_product_type_form_blocks.sql.
--
-- НЕ МИГРАЦИЯ. Запускать только вручную на ветке/стенде ПОСЛЕ миграции.
-- Весь сценарий выполняется в одной транзакции и всегда заканчивается ROLLBACK.

begin;

-- Acceptance запускается после M1, поэтому внутри rollback-only транзакции
-- сначала возвращаем capability в исходное для M1 состояние и доказываем, что
-- строка ровно одна. ROLLBACK восстановит реальное значение после теста.
update public.app_capabilities
   set enabled = false,
       updated_at = now()
 where code = 'product_type_form_blocks_v1';

do $capability_starts_disabled$
declare
  v_count integer;
  v_enabled boolean;
begin
  select count(*), bool_or(c.enabled)
    into v_count, v_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1';

  if v_count <> 1 or v_enabled is distinct from false then
    raise exception 'CAPABILITY 01 failed: count=%, enabled=%.', v_count, v_enabled;
  end if;

  -- Искусственная ошибка до финального UPDATE не должна сама включить flag.
  begin
    raise exception 'acceptance: artificial partial-M1 failure'
      using errcode = '55000';
  exception when sqlstate '55000' then
    null;
  end;

  if exists (
    select 1 from public.app_capabilities c
     where c.code = 'product_type_form_blocks_v1' and c.enabled
  ) then
    raise exception 'CAPABILITY 01 failed: partial schema стала enabled.';
  end if;
end;
$capability_starts_disabled$;

-- SCHEMA 01. Три временных триггера существуют с точными timing/event/level
-- и UPDATE OF-колонками. Для BEFORE ROW PostgreSQL исполняет триггеры в
-- алфавитном порядке, поэтому 00 обязан предшествовать 10.
do $schema_triggers$
declare
  v_bad   text;
  v_order text[];
begin
  with expected(name, tgtype, update_columns, function_signature) as (
    values
      ('trg_orders_00_mark_explicit_product_type_id', 19::smallint,
       array['product_type_id']::text[],
       'public.tg_orders_00_mark_explicit_product_type_id()'),
      ('trg_orders_10_sync_product_type', 23::smallint,
       array['product', 'product_type_id']::text[],
       'public.tg_orders_10_sync_product_type()'),
      ('trg_orders_99_clear_product_type_marker', 16::smallint,
       array['product_type_id']::text[],
       'public.tg_orders_99_clear_product_type_marker()')
  ), actual as (
    select t.tgname,
           t.tgtype,
           t.tgfoid,
           array(
             select a.attname
               from unnest(t.tgattr::smallint[]) with ordinality u(attnum, ord)
               join pg_catalog.pg_attribute a
                 on a.attrelid = t.tgrelid and a.attnum = u.attnum
              order by u.ord
           ) as update_columns
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class r on r.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = r.relnamespace
     where n.nspname = 'public'
       and r.relname = 'orders'
       and not t.tgisinternal
  )
  select string_agg(e.name, ', ' order by e.name)
    into v_bad
    from expected e
    left join actual a on a.tgname = e.name
   where a.tgname is null
      or a.tgtype <> e.tgtype
      or a.tgfoid is distinct from
           pg_catalog.to_regprocedure(e.function_signature)
      or a.update_columns is distinct from e.update_columns;

  if v_bad is not null then
    raise exception 'SCHEMA 01 failed: неверные события/колонки триггеров [%].',
      v_bad;
  end if;

  select array_agg(t.tgname order by t.tgname)
    into v_order
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class r on r.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
   where n.nspname = 'public'
     and r.relname = 'orders'
     and t.tgname in (
       'trg_orders_00_mark_explicit_product_type_id',
       'trg_orders_10_sync_product_type'
     )
     and not t.tgisinternal;

  if v_order is distinct from array[
       'trg_orders_00_mark_explicit_product_type_id',
       'trg_orders_10_sync_product_type'
     ]::text[] then
    raise exception 'SCHEMA 01 failed: порядок BEFORE-триггеров = %.', v_order;
  end if;
end;
$schema_triggers$;

-- SCHEMA 02. Нормализованный title и две частичные версии защищены unique
-- indexes; пара (product_type_id, version) тоже уникальна.
do $schema_unique_indexes$
declare
  v_bad text;
begin
  with expected(index_name, required_fragment) as (
    values
      ('warehouse_categories_title_normalized_uq', 'lower(btrim(title))'),
      ('product_type_configs_product_type_id_version_key',
       '(product_type_id, version)'),
      ('product_type_configs_published_uq',
       'where (status = ''published''::text)'),
      ('product_type_configs_draft_uq',
       'where (status = ''draft''::text)')
  ), actual as (
    select i.relname as index_name,
           x.indisunique,
           lower(pg_catalog.pg_get_indexdef(x.indexrelid)) as index_def
      from pg_catalog.pg_index x
      join pg_catalog.pg_class i on i.oid = x.indexrelid
      join pg_catalog.pg_namespace n on n.oid = i.relnamespace
     where n.nspname = 'public'
  )
  select string_agg(e.index_name, ', ' order by e.index_name)
    into v_bad
    from expected e
    left join actual a on a.index_name = e.index_name
   where a.index_name is null
      or not a.indisunique
      or position(e.required_fragment in a.index_def) = 0;

  if v_bad is not null then
    raise exception 'SCHEMA 02 failed: unique indexes [%].', v_bad;
  end if;
end;
$schema_unique_indexes$;

-- SCHEMA 03. Все три новые исторические ссылки используют именно RESTRICT.
do $schema_restrict_fks$
declare
  v_bad text;
begin
  with expected(name) as (
    values
      ('orders_product_type_id_fkey'),
      ('product_type_configs_product_type_id_fkey'),
      ('orders_stage_config_id_fkey')
  )
  select string_agg(e.name, ', ' order by e.name)
    into v_bad
    from expected e
    left join pg_catalog.pg_constraint c
      on c.conname = e.name
     and c.connamespace = 'public'::regnamespace
     and c.contype = 'f'
   where c.oid is null or c.confdeltype <> 'r';

  if v_bad is not null then
    raise exception 'SCHEMA 03 failed: FK не RESTRICT [%].', v_bad;
  end if;
end;
$schema_restrict_fks$;

-- SCHEMA 04. title не может быть NULL, пустым или состоять из пробелов.
do $schema_title_check$
declare
  v_def text;
begin
  select lower(pg_catalog.pg_get_constraintdef(c.oid, true))
    into v_def
    from pg_catalog.pg_constraint c
   where c.conrelid = 'public.warehouse_categories'::regclass
     and c.conname = 'warehouse_categories_title_not_blank_check'
     and c.contype = 'c'
     and c.convalidated;

  if v_def is null
     or position('nullif(btrim(title)' in v_def) = 0
     or position('is not null' in v_def) = 0 then
    raise exception 'SCHEMA 04 failed: title CHECK отсутствует/неверен: %.', v_def;
  end if;
end;
$schema_title_check$;

-- SCHEMA 05. SECURITY DEFINER оставлен только workflow/guard-функциям;
-- search_path фиксирован у всех функций. PUBLIC и anon не имеют EXECUTE,
-- authenticated получает EXECUTE только на три RPC.
do $schema_function_security$
declare
  v_bad text;
  v_anon oid;
  v_authenticated oid;
begin
  select oid into v_anon from pg_catalog.pg_roles where rolname = 'anon';
  select oid into v_authenticated
    from pg_catalog.pg_roles where rolname = 'authenticated';

  if v_anon is null or v_authenticated is null then
    raise exception 'SCHEMA 05 failed: роли anon/authenticated не найдены.';
  end if;

  with expected(signature, is_definer, authenticated_execute) as (
    values
      ('public.tg_orders_00_mark_explicit_product_type_id()', false, false),
      ('public.tg_orders_10_sync_product_type()', false, false),
      ('public.tg_orders_99_clear_product_type_marker()', false, false),
      ('public.tg_protect_product_type_config()', true, false),
      ('public.tg_protect_product_type_form_block()', true, false),
      ('public.tg_protect_warehouse_category_archive()', true, false),
      ('public.create_product_type_config_draft(uuid)', true, true),
      ('public.discard_product_type_config_draft(uuid)', true, true),
      ('public.publish_product_type_config(uuid)', true, true),
      ('public.archive_warehouse_category(uuid,text,text)', true, true)
  )
  select string_agg(e.signature, ', ' order by e.signature)
    into v_bad
    from expected e
    left join pg_catalog.pg_proc p
      on p.oid = pg_catalog.to_regprocedure(e.signature)
   where p.oid is null
      or p.prosecdef is distinct from e.is_definer
      or not (
        coalesce(p.proconfig, array[]::text[])
          @> array['search_path=public, pg_temp']::text[]
      )
      or exists (
        select 1
          from pg_catalog.aclexplode(
                 coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
               ) a
         where a.grantee = 0
           and a.privilege_type = 'EXECUTE'
      )
      or exists (
        select 1
          from pg_catalog.aclexplode(
                 coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
               ) a
         where a.grantee = v_anon
           and a.privilege_type = 'EXECUTE'
      )
      or (
        exists (
          select 1
            from pg_catalog.aclexplode(
                   coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
                 ) a
           where a.grantee = v_authenticated
             and a.privilege_type = 'EXECUTE'
        ) is distinct from e.authenticated_execute
      );

  if v_bad is not null then
    raise exception 'SCHEMA 05 failed: безопасность функций [%].', v_bad;
  end if;
end;
$schema_function_security$;

-- SCHEMA 06. Guard-таблица недоступна PUBLIC/anon/authenticated.
do $schema_guard_privileges$
declare
  v_bad text;
begin
  select string_agg(c.relname || ':' || coalesce(r.rolname, 'PUBLIC') || ':' || a.privilege_type,
                    ', ' order by a.grantee, a.privilege_type)
    into v_bad
    from pg_catalog.pg_class c
    cross join lateral pg_catalog.aclexplode(
      coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) a
    left join pg_catalog.pg_roles r on r.oid = a.grantee
   where c.oid in (
       'public.product_type_config_write_guards'::regclass,
       'public.warehouse_category_archive_guards'::regclass
     )
     and (
       a.grantee = 0
       or r.rolname in ('anon', 'authenticated')
     );

  if v_bad is not null then
    raise exception 'SCHEMA 06 failed: guard grants [%].', v_bad;
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_trigger t
     where t.tgrelid = 'public.warehouse_categories'::regclass
       and t.tgname = 'trg_warehouse_categories_archive_guard'
       and not t.tgisinternal
  ) then
    raise exception 'SCHEMA 06 failed: archive guard trigger отсутствует.';
  end if;
end;
$schema_guard_privileges$;

create temp table acceptance_context (
  cat_a       uuid not null,
  title_a     text not null,
  cat_b       uuid not null,
  title_b     text not null,
  old_pub_id  uuid,
  new_pub_id  uuid,
  failed_id   uuid
) on commit drop;

insert into acceptance_context (cat_a, title_a, cat_b, title_b)
select a.id, a.title, b.id, b.title
  from (
    select c.id, c.title, row_number() over (order by c.id) as rn
      from public.warehouse_categories c
     where c.archived_at is null
  ) a
  cross join (
    select c.id, c.title, row_number() over (order by c.id) as rn
      from public.warehouse_categories c
     where c.archived_at is null
  ) b
 where a.rn = 1 and b.rn = 2;

do $assert_two_categories$
begin
  if not exists (
    select 1 from acceptance_context
     where cat_a is not null and cat_b is not null and cat_a <> cat_b
  ) then
    raise exception 'Acceptance требует минимум две активные категории.';
  end if;
end;
$assert_two_categories$;

-- Триггерные функции проверяются на временной таблице с теми же тремя
-- событиями. Это не затрагивает настоящие orders и производственные планы.
create temp table orders_transition_test (
  id              uuid primary key,
  product         jsonb,
  product_type_id uuid
) on commit drop;

create trigger trg_orders_00_mark_explicit_product_type_id
  before update of product_type_id on orders_transition_test
  for each row
  execute function public.tg_orders_00_mark_explicit_product_type_id();

create trigger trg_orders_10_sync_product_type
  before insert or update of product, product_type_id on orders_transition_test
  for each row
  execute function public.tg_orders_10_sync_product_type();

create trigger trg_orders_99_clear_product_type_marker
  after update of product_type_id on orders_transition_test
  for each statement
  execute function public.tg_orders_99_clear_product_type_marker();

-- CASE 01. INSERT старого клиента: только product.type.
do $case_01$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_a
       and v.product->>'type' = c.title_a
  ) then
    raise exception 'CASE 01 failed: legacy INSERT не заполнил канонический ID/title.';
  end if;
end;
$case_01$;

-- CASE 02. UPDATE старого клиента: изменён только product.type.
do $case_02$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test o
     set product = jsonb_set(o.product, '{type}', to_jsonb(c.title_b), true)
    from acceptance_context c
   where o.id = v_id;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_b
       and v.product->>'type' = c.title_b
  ) then
    raise exception 'CASE 02 failed: legacy UPDATE не переоткрыл тип.';
  end if;
end;
$case_02$;

-- CASE 03. Новый клиент меняет product и ID одним UPDATE.
do $case_03$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test o
     set product = jsonb_build_object('type', c.title_b),
         product_type_id = c.cat_b
    from acceptance_context c
   where o.id = v_id;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_b
       and v.product->>'type' = c.title_b
  ) then
    raise exception 'CASE 03 failed: согласованная явная пара не сохранена.';
  end if;
end;
$case_03$;

-- CASE 04. Новый клиент меняет только ID; title канонизируется.
do $case_04$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test o
     set product_type_id = c.cat_b
    from acceptance_context c
   where o.id = v_id;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_b
       and v.product->>'type' = c.title_b
  ) then
    raise exception 'CASE 04 failed: ID-only UPDATE не синхронизировал title.';
  end if;
end;
$case_04$;

-- CASE 05. Неизвестный legacy-title — пользовательская 23514, не 23503.
do $case_05$
begin
  begin
    insert into orders_transition_test (id, product)
    values (gen_random_uuid(), jsonb_build_object('type', '__unknown_acceptance__'));
    raise exception 'CASE 05 failed: ожидалась 23514.';
  exception when sqlstate '23514' then
    null;
  end;
end;
$case_05$;

-- CASE 06. Явные ID и title разных категорий — 23514.
do $case_06$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  begin
    update orders_transition_test o
       set product = jsonb_build_object('type', c.title_a),
           product_type_id = c.cat_b
      from acceptance_context c
     where o.id = v_id;
    raise exception 'CASE 06 failed: ожидалась 23514.';
  exception when sqlstate '23514' then
    null;
  end;
end;
$case_06$;

-- CASE 07. Главный регресс: ID=A явно присутствует, но остался прежним;
-- product.type=B. Запрос не считается legacy и получает 23514.
do $case_07$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  begin
    update orders_transition_test o
       set product = jsonb_build_object('type', c.title_b),
           product_type_id = c.cat_a
      from acceptance_context c
     where o.id = v_id;
    raise exception 'CASE 07 failed: явно повторённый ID был принят за legacy.';
  exception when sqlstate '23514' then
    null;
  end;
end;
$case_07$;

-- CASE 08. Новый клиент явно очищает ID; старый title удаляется триггером.
do $case_08$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test set product_type_id = null where id = v_id;
  select o.* into v from orders_transition_test o where o.id = v_id;

  if v.product_type_id is not null or v.product ? 'type' then
    raise exception 'CASE 08 failed: явная очистка ID не очистила оба представления.';
  end if;
end;
$case_08$;

-- CASE 09. Старый клиент очищает только product.type; ID становится NULL.
do $case_09$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test
     set product = product - 'type'
   where id = v_id;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if v.product_type_id is not null or v.product ? 'type' then
    raise exception 'CASE 09 failed: legacy-очистка title не очистила ID.';
  end if;
end;
$case_09$;

-- CASE 10. INSERT с ID без product.type заполняет канонический title.
do $case_10$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product, product_type_id)
  select v_id, '{}'::jsonb, cat_a from acceptance_context;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_a
       and v.product->>'type' = c.title_a
  ) then
    raise exception 'CASE 10 failed: INSERT с ID не заполнил title.';
  end if;
end;
$case_10$;

-- CASE 11. Регистр/пробелы нормализуются и title канонизируется.
do $case_11$
declare
  v_id uuid := gen_random_uuid();
  v record;
begin
  insert into orders_transition_test (id, product)
  select v_id, jsonb_build_object('type', '  ' || upper(title_a) || '  ')
    from acceptance_context;

  select o.* into v from orders_transition_test o where o.id = v_id;
  if not exists (
    select 1 from acceptance_context c
     where v.product_type_id = c.cat_a
       and v.product->>'type' = c.title_a
  ) then
    raise exception 'CASE 11 failed: нормализованный title не распознан.';
  end if;
end;
$case_11$;

-- CASE 12. Будущий нормализованный дубль категории отклоняет unique index 23505.
do $case_12$
begin
  begin
    insert into public.warehouse_categories (code, title, has_subtables)
    select 'acceptance_' || replace(gen_random_uuid()::text, '-', ''),
           '  ' || upper(title_a) || '  ',
           false
      from acceptance_context;
    raise exception 'CASE 12 failed: ожидалась 23505.';
  exception when sqlstate '23505' then
    null;
  end;
end;
$case_12$;

-- CASE 13. Один multi-row UPDATE: одинаковый явный ID у первой строки и новый
-- у второй. Маркер привязан к OLD.id и не перетекает между строками.
do $case_13$
declare
  v_id_1 uuid := gen_random_uuid();
  v_id_2 uuid := gen_random_uuid();
  v_bad integer;
begin
  insert into orders_transition_test (id, product)
  select v_id_1, jsonb_build_object('type', title_a) from acceptance_context
  union all
  select v_id_2, jsonb_build_object('type', title_a) from acceptance_context;

  update orders_transition_test o
     set product_type_id = case when o.id = v_id_1 then c.cat_a else c.cat_b end,
         product = jsonb_build_object(
           'type', case when o.id = v_id_1 then c.title_a else c.title_b end
         )
    from acceptance_context c
   where o.id in (v_id_1, v_id_2);

  select count(*) into v_bad
    from orders_transition_test o
    cross join acceptance_context c
   where (o.id = v_id_1 and
          (o.product_type_id <> c.cat_a or o.product->>'type' <> c.title_a))
      or (o.id = v_id_2 and
          (o.product_type_id <> c.cat_b or o.product->>'type' <> c.title_b));

  if v_bad <> 0 then
    raise exception 'CASE 13 failed: multi-row marker перепутал строки.';
  end if;
end;
$case_13$;

-- CASE 14. Несуществующий явный FK получает настоящий 23503.
do $case_14$
begin
  begin
    insert into orders_transition_test (id, product, product_type_id)
    values (gen_random_uuid(), '{}'::jsonb, gen_random_uuid());
    raise exception 'CASE 14 failed: ожидалась 23503.';
  exception when sqlstate '23503' then
    null;
  end;
end;
$case_14$;

-- CASE 15. После statement GUC очищен.
do $case_15$
begin
  if coalesce(
       current_setting('easy_pack.orders_explicit_product_type_id', true),
       ''
     ) <> '' then
    raise exception 'CASE 15 failed: transaction-local marker утёк между statements.';
  end if;
end;
$case_15$;

-- CASE 15b. Архивную категорию нельзя выбрать для нового заказа, но уже
-- существующий заказ с тем же ID можно пересохранить без смены типа.
do $case_15b$
declare
  v_id             uuid := gen_random_uuid();
  v_archived_draft uuid;
begin
  insert into orders_transition_test (id, product, product_type_id)
  select v_id, jsonb_build_object('type', title_b), cat_b
    from acceptance_context;

  select public.create_product_type_config_draft(a.cat_b)
    into v_archived_draft
    from acceptance_context a;

  insert into public.warehouse_category_archive_guards
         (backend_pid, transaction_id, category_id)
  select pg_backend_pid(), txid_current(), a.cat_b
    from acceptance_context a;

  update public.warehouse_categories c
     set archived_at = clock_timestamp()
    from acceptance_context a
   where c.id = a.cat_b;

  delete from public.warehouse_category_archive_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current();

  begin
    insert into orders_transition_test (id, product, product_type_id)
    select gen_random_uuid(), jsonb_build_object('type', title_b), cat_b
      from acceptance_context;
    raise exception 'CASE 15b failed: архивная категория принята для нового заказа.';
  exception when sqlstate '23514' then
    null;
  end;

  begin
    perform public.create_product_type_config_draft(a.cat_b)
      from acceptance_context a;
    raise exception 'CASE 15b failed: для архивной категории создан draft.';
  exception when sqlstate '23514' then
    null;
  end;

  begin
    perform public.publish_product_type_config(v_archived_draft);
    raise exception 'CASE 15b failed: draft архивной категории опубликован.';
  exception when sqlstate '23514' then
    null;
  end;

  if not exists (
    select 1
      from orders_transition_test o
      join public.warehouse_categories c on c.id = o.product_type_id
     where o.id = v_id
       and c.archived_at is not null
  ) then
    raise exception 'CASE 15b failed: старый заказ с архивным ID не читается.';
  end if;

  update orders_transition_test o
     set product_type_id = a.cat_b
    from acceptance_context a
   where o.id = v_id;

  insert into public.warehouse_category_archive_guards
         (backend_pid, transaction_id, category_id)
  select pg_backend_pid(), txid_current(), a.cat_b
    from acceptance_context a;

  update public.warehouse_categories c
     set archived_at = null
    from acceptance_context a
   where c.id = a.cat_b;

  delete from public.warehouse_category_archive_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current();

  perform public.discard_product_type_config_draft(v_archived_draft);
end;
$case_15b$;

-- CASE 16. Published parent нельзя UPDATE или DELETE напрямую (55000).
do $case_16$
declare
  v_pub uuid;
begin
  select c.id into v_pub
    from public.product_type_configs c
    join acceptance_context a on a.cat_a = c.product_type_id
   where c.status = 'published';

  begin
    update public.product_type_configs set note = note where id = v_pub;
    raise exception 'CASE 16a failed: ожидалась 55000.';
  exception when sqlstate '55000' then
    null;
  end;

  begin
    delete from public.product_type_configs where id = v_pub;
    raise exception 'CASE 16b failed: ожидалась 55000.';
  exception when sqlstate '55000' then
    null;
  end;
end;
$case_16$;

-- CASE 17. Child published нельзя INSERT/UPDATE/DELETE напрямую (55000).
do $case_17$
declare
  v_pub uuid;
  v_draft uuid;
  v_existing_draft uuid;
  v_block text;
begin
  -- Гарантируем published с дочерней строкой без зависимости от seed-снимка.
  select c.id into v_existing_draft
    from public.product_type_configs c
    join acceptance_context a on a.cat_b = c.product_type_id
   where c.status = 'draft';

  if v_existing_draft is not null then
    perform public.discard_product_type_config_draft(v_existing_draft);
  end if;

  select public.create_product_type_config_draft(cat_b)
    into v_draft from acceptance_context;

  select f.code into v_block from public.order_form_blocks f order by f.code limit 1;

  if not exists (
    select 1 from public.product_type_form_blocks b
     where b.config_id = v_draft and b.block_code = v_block
  ) then
    insert into public.product_type_form_blocks
           (config_id, block_code, is_visible, is_required)
    values (v_draft, v_block, false, false);
  end if;

  perform public.publish_product_type_config(v_draft);
  v_pub := v_draft;

  begin
    insert into public.product_type_form_blocks
           (config_id, block_code, is_visible, is_required)
    values (v_pub, v_block, false, false);
    raise exception 'CASE 17a failed: ожидалась 55000.';
  exception when sqlstate '55000' then
    null;
  end;

  begin
    update public.product_type_form_blocks
       set is_visible = not is_visible
     where config_id = v_pub and block_code = v_block;
    raise exception 'CASE 17b failed: ожидалась 55000.';
  exception when sqlstate '55000' then
    null;
  end;

  begin
    delete from public.product_type_form_blocks
     where config_id = v_pub and block_code = v_block;
    raise exception 'CASE 17c failed: ожидалась 55000.';
  exception when sqlstate '55000' then
    null;
  end;
end;
$case_17$;

-- CASE 18. Первый edit создаёт один draft, повторный вызов возвращает его же;
-- sparse-overrides скопированы, правка child draft разрешена.
do $case_18$
declare
  v_existing uuid;
  v_draft_1 uuid;
  v_draft_2 uuid;
  v_pub uuid;
  v_pub_count integer;
  v_draft_count integer;
  v_block text;
begin
  select c.id into v_existing
    from public.product_type_configs c
    join acceptance_context a on a.cat_a = c.product_type_id
   where c.status = 'draft';

  if v_existing is not null then
    perform public.discard_product_type_config_draft(v_existing);
  end if;

  select c.id into v_pub
    from public.product_type_configs c
    join acceptance_context a on a.cat_a = c.product_type_id
   where c.status = 'published';

  select public.create_product_type_config_draft(cat_a)
    into v_draft_1 from acceptance_context;
  select public.create_product_type_config_draft(cat_a)
    into v_draft_2 from acceptance_context;

  if v_draft_1 <> v_draft_2 then
    raise exception 'CASE 18 failed: повторное открытие создало второй draft.';
  end if;

  select count(*) into v_draft_count
    from public.product_type_configs c
    join acceptance_context a on a.cat_a = c.product_type_id
   where c.status = 'draft';

  if v_draft_count <> 1 then
    raise exception 'CASE 18 failed: draft count=% вместо 1.', v_draft_count;
  end if;

  select count(*) into v_pub_count
    from public.product_type_form_blocks b where b.config_id = v_pub;
  select count(*) into v_draft_count
    from public.product_type_form_blocks b where b.config_id = v_draft_1;

  if v_pub_count <> v_draft_count then
    raise exception 'CASE 18 failed: sparse-overrides не скопированы.';
  end if;

  select f.code into v_block
    from public.order_form_blocks f
   where not exists (
     select 1 from public.product_type_form_blocks b
      where b.config_id = v_draft_1 and b.block_code = f.code
   )
   limit 1;

  if v_block is not null then
    insert into public.product_type_form_blocks
           (config_id, block_code, is_visible, is_required)
    values (v_draft_1, v_block, false, false);
  else
    update public.product_type_form_blocks
       set is_visible = not is_visible
     where config_id = v_draft_1
       and block_code = (
         select min(block_code) from public.product_type_form_blocks
          where config_id = v_draft_1
       );
  end if;

  update acceptance_context set old_pub_id = v_pub, new_pub_id = v_draft_1;
end;
$case_18$;

-- CASE 19. Publish атомарно архивирует old и публикует draft; published ровно 1.
do $case_19$
declare
  v_old uuid;
  v_new uuid;
  v_count integer;
begin
  select old_pub_id, new_pub_id into v_old, v_new from acceptance_context;
  perform public.publish_product_type_config(v_new);

  if not exists (
       select 1 from public.product_type_configs
        where id = v_old and status = 'archived'
     ) or not exists (
       select 1 from public.product_type_configs
        where id = v_new and status = 'published'
     ) then
    raise exception 'CASE 19 failed: статусы после publish неверны.';
  end if;

  select count(*) into v_count
    from public.product_type_configs c
    join acceptance_context a on a.cat_a = c.product_type_id
   where c.status = 'published';

  if v_count <> 1 then
    raise exception 'CASE 19 failed: published count=% вместо 1.', v_count;
  end if;
end;
$case_19$;

-- CASE 20. Искусственная ошибка между archive old и promotion draft полностью
-- откатывает вызов: прежний published остаётся видимым, draft остаётся draft,
-- guard-строка не утекает.
create or replace function public.acceptance_fail_config_promotion()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status = 'published'
     and new.id::text = current_setting('easy_pack.acceptance_fail_config', true) then
    raise exception 'Искусственная ошибка acceptance publish.'
      using errcode = '23514';
  end if;
  return new;
end;
$function$;

create trigger trg_zz_acceptance_fail_config_promotion
  before update on public.product_type_configs
  for each row execute function public.acceptance_fail_config_promotion();

do $case_20$
declare
  v_current_pub uuid;
  v_failed uuid;
  v_guard_count integer;
begin
  select new_pub_id into v_current_pub from acceptance_context;
  select public.create_product_type_config_draft(cat_a)
    into v_failed from acceptance_context;
  update acceptance_context set failed_id = v_failed;
  perform set_config('easy_pack.acceptance_fail_config', v_failed::text, true);

  begin
    perform public.publish_product_type_config(v_failed);
    raise exception 'CASE 20 failed: ожидалась искусственная 23514.';
  exception when sqlstate '23514' then
    null;
  end;

  if not exists (
       select 1 from public.product_type_configs
        where id = v_current_pub and status = 'published'
     ) or not exists (
       select 1 from public.product_type_configs
        where id = v_failed and status = 'draft'
     ) then
    raise exception 'CASE 20 failed: ошибка публикации оставила разрыв статусов.';
  end if;

  select count(*) into v_guard_count
    from public.product_type_config_write_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current();

  if v_guard_count <> 0 then
    raise exception 'CASE 20 failed: guard-marker утёк после ошибки.';
  end if;
end;
$case_20$;

drop trigger trg_zz_acceptance_fail_config_promotion
  on public.product_type_configs;
drop function public.acceptance_fail_config_promotion();

-- Все schema/functional assertions прошли. Только теперь имитируем последний
-- statement M1 и проверяем ровно одну включённую capability-row.
update public.app_capabilities
   set enabled = true,
       updated_at = now()
 where code = 'product_type_form_blocks_v1';

do $capability_ends_enabled$
declare
  v_count integer;
  v_enabled boolean;
begin
  select count(*), bool_or(c.enabled)
    into v_count, v_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1';

  if v_count <> 1 or v_enabled is distinct from true then
    raise exception 'CAPABILITY 02 failed: count=%, enabled=%.', v_count, v_enabled;
  end if;
end;
$capability_ends_enabled$;

-- CASE 21. Enabled archive RPC атомарно ставит archived_at и audit, повторный
-- вызов идемпотентен и не создаёт вторую запись.
do $case_21$
declare
  v_category_id uuid;
  v_first timestamptz;
  v_second timestamptz;
  v_audit_count integer;
begin
  select a.cat_b into v_category_id from acceptance_context a;

  select public.archive_warehouse_category(
    v_category_id,
    'acceptance archive',
    'acceptance'
  ) into v_first;

  select public.archive_warehouse_category(
    v_category_id,
    'acceptance archive repeated',
    'acceptance'
  ) into v_second;

  if v_first is null or v_second is distinct from v_first or not exists (
    select 1
      from public.warehouse_categories c
     where c.id = v_category_id
       and c.archived_at = v_first
  ) then
    raise exception 'CASE 21 failed: archived_at не установлен/не идемпотентен.';
  end if;

  select count(*)
    into v_audit_count
    from public.warehouse_deleted_records d
   where d.entity_type = 'category'
     and d.entity_id = v_category_id::text
     and d.reason = 'acceptance archive';

  if v_audit_count <> 1 then
    raise exception 'CASE 21 failed: audit count=% вместо 1.', v_audit_count;
  end if;
end;
$case_21$;

rollback;
