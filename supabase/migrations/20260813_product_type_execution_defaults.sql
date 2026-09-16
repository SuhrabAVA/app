-- T3: перевод девяти типов продукта на явные настройки, введённые в T1–T2.
--
-- ЧТО ЗДЕСЬ
--   1. Формула фактического количества — всем версиям, где она не задана.
--   2. Упаковка получает режим parallel_with_previous, то есть своё же
--      сегодняшнее поведение, записанное явно.
--   3. Долг T1: копирование черновика теряло новые колонки. Разбор ниже.
--
-- ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ
-- Перенумерация упаковки с ранга 999 в max + 1 отложена в T4. Она безопасна
-- не сама по себе, а только вместе со снятием is_pinned_last, потому что
-- добавление этапа берёт ранг max(незакреплённых) + 1 — ровно тот, который
-- перенумерация отдала бы упаковке. Совпадение рангов не ломает план (сборщик
-- отделяет закреплённый хвост), но в редакторе два этапа одного ранга — это
-- одна группа: новый этап нарисовался бы В СТРОКЕ упаковки как её альтернатива
-- и стал бы неперемещаемым, потому что группа с закреплённым этапом исключена
-- из перестановки. Плотность рангов нужна только после снятия закрепления, и
-- получить её надо там же, где оно снимается, — иначе между T3 и T4 остаётся
-- живая ловушка на первом же добавленном этапе.

-- 1. Формула фактического количества.
--
-- packs_times_pack_size — это то, что recomputeOrderActualQty делает сегодня
-- для всех типов без исключения. T3 ничего не меняет в поведении, он лишь
-- перестаёт держать это знание в коде.
--
-- Условие по is null, а не по status: черновик, если он появится до
-- применения, нуждается в формуле ровно так же, иначе его нельзя будет
-- опубликовать.
update public.product_type_configs
   set actual_qty_formula = 'packs_times_pack_size'
 where actual_qty_formula is null;

-- 2. Режим упаковки.
--
-- Упаковка стартует, как только начата предыдущая группа собранной очереди
-- заказа, и не ждёт своей очереди между заказами: tasks_screen.dart отдаёт ей
-- безусловное разрешение, а партнёром берёт orderedKeys[currentIndex - 1] —
-- то есть партнёр вычисляется на лету и в настройках его записать нечем.
-- Для этого и заведён отдельный режим parallel_with_previous.
--
-- is_pinned_last — точный признак упаковки: закреплённый этап в маршруте
-- ровно один, и это она.
update public.product_type_stages
   set execution_mode = 'parallel_with_previous'
 where is_pinned_last;

-- 3. Долг T1: копирование версии теряло новые колонки.
--
-- Обе функции копирования перечисляют колонки явно — это правильно, неявный
-- INSERT ... SELECT * сломался бы на первой же новой колонке молча. Но именно
-- поэтому добавление колонки в T1 обязано было пройти по обоим спискам, а не
-- прошло. Последствия без этой правки:
--   * черновик рождался бы без формулы и сразу непубликуемым
--     (actual_qty_formula_missing), причём техлид увидел бы это только при
--     публикации;
--   * упаковка в черновике возвращалась бы в sequential, и публикация тихо
--     превратила бы параллельный старт в последовательный — то есть правка
--     подписи этапа меняла бы очерёдность на планшетах.
--
-- Ниже обе функции переизданы целиком.

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
  'Идемпотентно создаёт черновик настроек типа продукта: возвращает '
  'существующий, если он есть, иначе делает глубокую копию опубликованной '
  'версии — блоки формы, этапы обоих уровней, рабочие места, условия, режимы '
  'очерёдности и формулу факта, — перекладывая внутренние ссылки '
  '(parent_variant_id, parallel_with_stage_id) на новые id.';

-- Копирование под-этапов между вариантами одного переключаемого этапа.
--
-- Отличие от копии черновика: партнёр может остаться прежним id. По инварианту
-- parallel_partner_unreachable партнёр под-этапа — это либо этап верхнего
-- уровня (общий для обоих вариантов, ссылка верна как есть), либо под-этап
-- ТОГО ЖЕ варианта. Во втором случае копия обязана смотреть на под-этап
-- приёмника: оставленная ссылка увела бы её в чужой вариант, и этап ждал бы
-- старта того, чего в его ветке не будет.
create or replace function public.copy_variant_sub_stages(
  p_from_variant_id uuid,
  p_to_variant_id   uuid
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_from_stage    uuid;
  v_to_stage      uuid;
  v_from_config   uuid;
  v_to_config     uuid;
  v_stage         record;
  v_new_stage     uuid;
  v_copied        integer := 0;
  v_new_ids       uuid[] := '{}';
  v_partner       uuid;
  v_partner_level integer;
  v_partner_key   text;
  v_partner_title text;
  v_resolved      uuid;
  v_title         text;
  i               integer;
begin
  if p_from_variant_id is null or p_to_variant_id is null then
    raise exception
      'Не удалось скопировать под-этапы: не указан вариант.'
      using errcode = '22023';
  end if;

  if p_from_variant_id = p_to_variant_id then
    raise exception
      'Не удалось скопировать под-этапы: источник и приёмник совпадают.'
      using errcode = '22023';
  end if;

  select w.stage_id, s.config_id into v_from_stage, v_from_config
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_from_variant_id;

  select w.stage_id, s.config_id into v_to_stage, v_to_config
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_to_variant_id;

  if v_from_stage is null or v_to_stage is null then
    raise exception
      'Не удалось скопировать под-этапы: вариант не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  -- Оба варианта обязаны принадлежать одному переключаемому этапу: копировать
  -- под-этапы между разными этапами или тем более между типами продукта
  -- бессмысленно, а последствия пришлось бы разбирать вручную.
  if v_from_stage <> v_to_stage then
    raise exception
      'Не удалось скопировать под-этапы: варианты принадлежат разным этапам.'
      using errcode = '22023';
  end if;

  if v_from_config <> v_to_config then
    raise exception
      'Не удалось скопировать под-этапы: варианты из разных версий настроек.'
      using errcode = '22023';
  end if;

  for v_stage in
    select * from product_type_stages
     where parent_variant_id = p_from_variant_id
     order by position, stage_group_key
  loop
    -- Ключ уже занят у приёмника — пропускаем: техлид мог завести часть
    -- под-этапов руками, и падать на этом невежливо.
    if exists (
      select 1 from product_type_stages s
       where s.parent_variant_id = p_to_variant_id
         and s.stage_group_key = v_stage.stage_group_key
    ) then
      continue;
    end if;

    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last,
      execution_mode, parallel_with_stage_id)
    values (
      v_stage.config_id, p_to_variant_id, 1, v_stage.stage_group_key,
      v_stage.title, v_stage.position, v_stage.selection_mode,
      v_stage.is_enabled, v_stage.is_pinned_last,
      v_stage.execution_mode, v_stage.parallel_with_stage_id)
    returning id into v_new_stage;

    v_new_ids := v_new_ids || v_new_stage;

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

    v_copied := v_copied + 1;
  end loop;

  -- Перевод партнёров-под-этапов на ветку приёмника. Цикл идёт вторым
  -- проходом: партнёр мог быть скопирован позже своего потребителя.
  for i in 1 .. coalesce(array_length(v_new_ids, 1), 0) loop
    select s.parallel_with_stage_id, s.title, p.level, p.stage_group_key, p.title
      into v_partner, v_title, v_partner_level, v_partner_key, v_partner_title
      from product_type_stages s
      left join product_type_stages p on p.id = s.parallel_with_stage_id
     where s.id = v_new_ids[i];

    -- Партнёр верхнего уровня общий для обеих веток — ссылка уже верна.
    if v_partner is null or v_partner_level = 0 then
      continue;
    end if;

    select id into v_resolved
      from product_type_stages
     where parent_variant_id = p_to_variant_id
       and stage_group_key = v_partner_key;

    -- Партнёра нет у приёмника и скопирован он не был. Молча оставить ссылку
    -- на чужую ветку нельзя, обнулить её — значит тихо сменить режим этапа,
    -- поэтому копирование отказывает целиком: техлид видит причину и решает
    -- сам. Достижимо только после T4, когда режимы станут доступны в
    -- редакторе; до тех пор ни один под-этап режима не имеет.
    if v_resolved is null then
      raise exception
        'Не удалось скопировать под-этапы: «%» идёт параллельно с «%», а '
        'этого под-этапа у варианта-приёмника нет. Скопируйте или создайте '
        'его первым.', v_title, v_partner_title
        using errcode = 'P0002';
    end if;

    update product_type_stages
       set parallel_with_stage_id = v_resolved
     where id = v_new_ids[i];
  end loop;

  return v_copied;
end;
$function$;

comment on function public.copy_variant_sub_stages(uuid, uuid) is
  'Копирует под-этапы одного варианта переключаемого этапа в другой вариант '
  'того же этапа, пропуская ключи, уже занятые у приёмника. Возвращает число '
  'скопированных под-этапов. Ссылки parallel_with_stage_id на под-этапы '
  'переводятся на ветку приёмника; если партнёра там нет, копирование '
  'отказывает целиком.';
