-- Условия обязательности блоков формы заказа.
--
-- ЗАЧЕМ
-- Безусловное «обязателен» огрубляет правило там, где оно и так есть в коде.
-- Живой пример: краска нужна не всякому заказу, а тому, у которого есть
-- печатная форма — печатать нечем, пока краска не выбрана. Это правило зашито
-- в `paintSelectionMissing`, и техлид его не видит и не меняет. Отметив
-- «Краски» галочкой, он запер бы и непечатные заказы.
--
-- Механизм повторяет условия этапов (миграция 20260807): закрытый справочник
-- предикатов, условия одного блока соединяются через AND, отсутствие строк
-- означает «всегда». OR не заводится по той же причине, что и там: он сразу
-- потребовал бы дерева выражений и скобок в редакторе.
--
-- ЧИТАЕТСЯ ТАК: блок обязателен, если стоит is_required И выполнены ВСЕ его
-- условия. Условия без is_required не значат ничего.
--
-- СКРИПТ ИДЕМПОТЕНТЕН: повторный запуск ничего не ломает и не дублирует.
-- Это не роскошь — миграцию применяют руками в SQL-редакторе, и оборвавшийся
-- на середине прогон иначе оставляет базу в состоянии, из которого нельзя ни
-- пойти вперёд, ни откатиться.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Область применения предиката
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Справочник `order_predicates` до сих пор обслуживал только этапы, и каждый
-- его код реализован функцией в Dart. Неизвестный код там трактуется как
-- «false» — этап молча не добавляется. Значит, предикат, который умеет
-- считать проверка блоков, но не умеет сборщик очереди, нельзя показывать в
-- редакторе этапов: техлид выбрал бы условие, которое молча выключает этап.
--
-- Отсюда scope. Он же документирует, почему списки в двух редакторах разные.

alter table public.order_predicates
  add column if not exists scope text not null default 'stage';

do $$
begin
  alter table public.order_predicates
    add constraint order_predicates_scope_check
    check (scope in ('stage', 'block', 'both'));
exception when duplicate_object then null;
end $$;

comment on column public.order_predicates.scope is
  'Где предикат можно выбрать: stage — только условия этапов, block — только '
  'обязательность блоков формы, both — обе стороны. Разделение не косметика: '
  'каждый код реализован функцией в Dart ОТДЕЛЬНО для каждой стороны, а '
  'неизвестный код читается как false и молча отключает правило.';

update public.order_predicates set scope = 'both'
 where code in ('has_paint', 'has_cardboard', 'has_trimming', 'handle_type_is');

-- Ширина заказа против формата бумаги считается по всему списку бумаг с
-- допуском — у проверки блоков таких данных нет, и подменять их нечем.
update public.order_predicates set scope = 'stage'
 where code = 'needs_bobbin_cutting';

insert into public.order_predicates (code, title, param_kind, sort_order, scope)
values ('has_form', 'В заказе есть печатная форма', null, 50, 'block')
on conflict (code) do update
  set title = excluded.title,
      sort_order = excluded.sort_order,
      scope = excluded.scope;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Условия блока
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Ключ — версия настроек плюс код блока, ровно как у product_type_form_blocks.
-- Каскад от версии: удалили черновик — ушли и его условия.

create table if not exists public.product_type_form_block_conditions (
  id         uuid primary key default gen_random_uuid(),
  config_id  uuid not null
               references public.product_type_configs(id) on delete cascade,
  block_code text not null references public.order_form_blocks(code),
  predicate  text not null references public.order_predicates(code),
  negate     boolean not null default false,
  param_text text,
  unique (config_id, block_code, predicate, param_text)
);

comment on table public.product_type_form_block_conditions is
  'Условия, при которых блок формы обязателен. Соединяются через AND; '
  'отсутствие строк означает «обязателен всегда». Действуют только вместе с '
  'product_type_form_blocks.is_required — условия без флага ничего не значат.';

comment on column public.product_type_form_block_conditions.negate is
  'Отрицание предиката: «если НЕТ картона». В отличие от условий этапов, где '
  'отрицание оказалось не нужно, здесь оно осмысленно сразу — «PDF обязателен, '
  'если нет печатной формы».';

create index if not exists product_type_form_block_conditions_by_config
  on public.product_type_form_block_conditions (config_id, block_code);

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Права и RLS
-- ═══════════════════════════════════════════════════════════════════════════

grant select, insert, update, delete
  on public.product_type_form_block_conditions
  to anon, authenticated, service_role;

alter table public.product_type_form_block_conditions
  enable row level security;

drop policy if exists product_type_form_block_conditions_select
  on public.product_type_form_block_conditions;
create policy product_type_form_block_conditions_select
  on public.product_type_form_block_conditions
  for select to authenticated using (true);

drop policy if exists product_type_form_block_conditions_write
  on public.product_type_form_block_conditions;
create policy product_type_form_block_conditions_write
  on public.product_type_form_block_conditions
  for all to authenticated using (true) with check (true);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Черновик обязан копировать условия
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Функция переопределяется целиком: create or replace иначе не умеет. Тело —
-- копия ПОСЛЕДНЕЙ её версии (20260813_product_type_execution_defaults.sql) с
-- одной добавленной вставкой: условия блоков.
--
-- ВНИМАНИЕ СЛЕДУЮЩЕМУ. Функцию уже переопределяли дважды — в 20260807 и в
-- 20260813. Копия, взятая не из последней миграции, откатывает чужие правки
-- молча: SQL применится без единой ошибки, а из черновика пропадёт то, что
-- добавила пропущенная версия. Перед правкой этой функции найдите её
-- последнее определение: grep -rln create_product_type_config_draft
-- supabase/migrations.

create or replace function public.create_product_type_config_draft(
  p_product_type_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_draft      uuid;
  v_published  uuid;
  v_version    integer;
  v_stage      record;
  v_wp         record;
  v_new_stage  uuid;
  v_new_wp     uuid;
  v_new_parent uuid;
begin
  if p_product_type_id is null then
    raise exception
      'Не удалось создать черновик: не указан тип продукта.'
      using errcode = '22023';
  end if;

  -- Снимок версий этого типа фиксируется до COMMIT: параллельное открытие
  -- редактора подождёт и увидит уже созданный черновик.
  perform 1 from product_type_configs
   where product_type_id = p_product_type_id
   for update;

  select id into v_draft
    from product_type_configs
   where product_type_id = p_product_type_id
     and status = 'draft'
   order by version desc
   limit 1;

  if v_draft is not null then
    return v_draft;
  end if;

  select id into v_published
    from product_type_configs
   where product_type_id = p_product_type_id
     and status = 'published';

  select coalesce(max(version), 0) + 1 into v_version
    from product_type_configs
   where product_type_id = p_product_type_id;

  -- Формула переносится из публикуемой версии, а не берётся по умолчанию:
  -- черновик обязан быть её точной копией, иначе публикация правки подписи
  -- заодно меняла бы способ расчёта факта.
  insert into product_type_configs(
    product_type_id, version, status, note, actual_qty_formula)
  values (
    p_product_type_id, v_version, 'draft',
    'Черновик правки настроек типа продукта.',
    (select actual_qty_formula from product_type_configs
      where id = v_published))
  returning id into v_draft;

  -- У типа продукта может не быть опубликованной версии (свежая категория) —
  -- тогда копировать нечего и черновик стартует пустым.
  if v_published is null then
    return v_draft;
  end if;

  insert into product_type_form_blocks(config_id, block_code, is_visible, is_required)
  select v_draft, block_code, is_visible, is_required
    from product_type_form_blocks
   where config_id = v_published;

  -- Условия обязательности блоков едут вместе с блоками: без этой копии
  -- нажатие «Начать правку» молча стирало бы все условия — черновик
  -- становится опубликованной версией при первой же публикации.
  insert into product_type_form_block_conditions(
    config_id, block_code, predicate, negate, param_text)
  select v_draft, block_code, predicate, negate, param_text
    from product_type_form_block_conditions
   where config_id = v_published;

  -- Карты «старый id → новый»: рабочих мест — для parent_variant_id,
  -- этапов — для parallel_with_stage_id.
  --
  -- Имена схемы обязательны. При search_path = 'public', 'pg_temp' временная
  -- схема идёт ПОСЛЕ public, поэтому неквалифицированное имя досталось бы
  -- одноимённой постоянной таблице, появись такая, — и функция бесшумно
  -- писала бы карту не туда. Сегодня таких таблиц нет; квалификация снимает
  -- зависимость от этого обстоятельства.
  --
  -- drop if exists — на случай двух вызовов в одной транзакции: ON COMMIT
  -- DROP срабатывает лишь на коммите.
  drop table if exists pg_temp._draft_wp_map;
  create temporary table pg_temp._draft_wp_map(
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  drop table if exists pg_temp._draft_stage_map;
  create temporary table pg_temp._draft_stage_map(
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  -- Сначала верхний уровень: его рабочие места станут родителями под-этапов.
  --
  -- parallel_with_stage_id намеренно не заполняется здесь: партнёр — это id
  -- этапа той же версии, и на момент вставки его копия может ещё не
  -- существовать. Проставляется одним UPDATE после обоих проходов.
  for v_stage in
    select * from product_type_stages
     where config_id = v_published and level = 0
     order by position, stage_group_key
  loop
    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last, execution_mode)
    values (
      v_draft, null, 0, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last, v_stage.execution_mode)
    returning id into v_new_stage;

    insert into pg_temp._draft_stage_map(old_id, new_id)
    values (v_stage.id, v_new_stage);

    for v_wp in
      select * from product_type_stage_workplaces
       where stage_id = v_stage.id
       order by sort_order
    loop
      insert into product_type_stage_workplaces(
        stage_id, workplace_id, variant_title, is_default, sort_order)
      values (v_new_stage, v_wp.workplace_id, v_wp.variant_title,
              v_wp.is_default, v_wp.sort_order)
      returning id into v_new_wp;

      insert into pg_temp._draft_wp_map(old_id, new_id) values (v_wp.id, v_new_wp);
    end loop;

    insert into product_type_stage_conditions(
      stage_id, predicate, negate, param_text)
    select v_new_stage, predicate, negate, param_text
      from product_type_stage_conditions
     where stage_id = v_stage.id;
  end loop;

  -- Теперь под-этапы: родитель уже скопирован, его новый id есть в карте.
  for v_stage in
    select * from product_type_stages
     where config_id = v_published and level = 1
     order by position, stage_group_key
  loop
    select new_id into v_new_parent
      from pg_temp._draft_wp_map
     where old_id = v_stage.parent_variant_id;

    if v_new_parent is null then
      raise exception
        'Не удалось создать черновик: под-этап «%» ссылается на вариант, '
        'которого нет в опубликованной версии.', v_stage.title
        using errcode = '23503';
    end if;

    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last, execution_mode)
    values (
      v_draft, v_new_parent, 1, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last, v_stage.execution_mode)
    returning id into v_new_stage;

    insert into pg_temp._draft_stage_map(old_id, new_id)
    values (v_stage.id, v_new_stage);

    insert into product_type_stage_workplaces(
      stage_id, workplace_id, variant_title, is_default, sort_order)
    select v_new_stage, workplace_id, variant_title, is_default, sort_order
      from product_type_stage_workplaces
     where stage_id = v_stage.id;

    insert into product_type_stage_conditions(
      stage_id, predicate, negate, param_text)
    select v_new_stage, predicate, negate, param_text
      from product_type_stage_conditions
     where stage_id = v_stage.id;
  end loop;

  -- Партнёры: ссылка переводится на копию партнёра внутри черновика. Если бы
  -- id переносился как есть, черновик указывал бы на этап ОПУБЛИКОВАННОЙ
  -- версии — validate_product_type_config поймал бы это как
  -- parallel_partner_foreign_config, но лишь при публикации.
  update product_type_stages d
     set parallel_with_stage_id = pm.new_id
    from pg_temp._draft_stage_map sm
    join product_type_stages src on src.id = sm.old_id
    join pg_temp._draft_stage_map pm on pm.old_id = src.parallel_with_stage_id
   where d.id = sm.new_id;

  return v_draft;
end;
$function$;

comment on function public.create_product_type_config_draft(uuid) is
  'Создаёт черновик настроек типа продукта глубокой копией опубликованной '
  'версии: блоки формы с их условиями обязательности, этапы, их рабочие места '
  'и условия, с перекладкой parent_variant_id на новые id вариантов. '
  'Идемпотентна — если черновик уже есть, возвращает его.';
