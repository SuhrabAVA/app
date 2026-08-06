-- Настройки типа продукта, фаза 3, часть 2 из 2: СИД девяти типов.
-- Схема — в 20260807_product_type_stages.sql.
--
-- ЧТО ЭТО
-- Перенос 36 правил из stage_queue_builder.dart в данные, руками. Цель —
-- ПАРИТЕТ: для каждого из девяти типов новая сборка обязана давать ту же
-- очередь, что старый код, на всём пространстве входов. Проверять это будет
-- исчерпывающий тест фазы 3.2 (hasPaint × hasCardboard × hasTrimming ×
-- handleType(4) × needsBobbin × выбор варианта — около 900 случаев).
-- Поэтому сид пишется руками, а не генерируется из старого кода: генератор
-- унаследовал бы и его ошибки, и проверять было бы нечего.
--
-- НУМЕРАЦИЯ ПРАВИЛ
-- Ссылки вида R3, R22 — из таблицы отчёта фазы 1, где 36 правил пронумерованы
-- по порядку исполнения в билдере. Это НЕ сквозная нумерация проекта: в
-- обсуждении те же правила иногда назывались иначе (например, связка «Труба
-- добавляет Сборку дно+картон и Склейку дна» упоминалась как R12/R13, здесь
-- это R23 и R24). Внутри файла нумерация согласована сама с собой.
--
-- КЛЮЧИ ЭТАПОВ ПЕРЕНЕСЕНЫ БУКВАЛЬНО
-- У этапа с одним рабочим местом stage_group_key равен uuid этого РМ.
-- Шесть групповых ключей — bottom_glue_group, p_main_switch, v_main_switch,
-- die_cut_a1_a2, flat_handle_group, twisted_handle_group — перенесены как
-- есть: они лежат в живых планах (проверено по prod_plan_stages) и по ним
-- группируют потребители. Менять их нельзя.
--
-- «РУЛОННАЯ ПЕЧАТЬ» И «ГОТОВАЯ ПРОДУКЦИЯ»
-- Собственного маршрута у них нет — старый билдер их не распознаёт и молча
-- отдаёт только базовые этапы плюс Упаковку. Базу и Упаковку им здесь ставим
-- ИМЕННО ПОЭТОМУ: без них паритет сломался бы в другую сторону, новая сборка
-- отдала бы пустую очередь. Продуктовых этапов у них нет.
--
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- Живут в pg_temp и исчезают вместе с сессией — постоянных объектов миграция
-- не оставляет. Без них сид был бы простынёй INSERT'ов с ручной прокладкой
-- сгенерированных id, где ошибиться проще всего.

-- ═══════════════════════════════════════════════════════════════════════════
-- Предохранитель: сид наполняет только ОПУБЛИКОВАННЫЕ версии
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Редактор блоков формы уже в бою, и черновики версий могли появиться. Такой
-- черновик сид не наполнит, и он останется с настройками блоков, но с нулём
-- этапов. Опубликуй его техлид — у типа продукта окажется маршрут из ничего.
-- На боевой путь это дойдёт только в фазе 3.5, но паритетный тест фазы 3.2
-- читает опубликованную версию и упал бы раньше и непонятнее.
--
-- Копировать этапы в черновик здесь нельзя: черновик мог быть создан ради
-- правки блоков, и досыпать в него маршрут задним числом значило бы менять
-- то, что человек уже видел на экране. Поэтому не молчим и не гадаем, а
-- останавливаем миграцию со списком — решение принимается руками.
do $$
declare
  v_row   record;
  v_count integer := 0;
  v_text  text := '';
begin
  for v_row in
    select cat.title as product_type, c.id, c.version, c.status
      from product_type_configs c
      join warehouse_categories cat on cat.id = c.product_type_id
     where c.status = 'draft'
     order by cat.title, c.version
  loop
    v_count := v_count + 1;
    v_text := v_text || format(E'\n  %s — версия %s (%s)',
                               v_row.product_type, v_row.version, v_row.id);
  end loop;

  if v_count > 0 then
    raise exception
      E'Сид не применён: найдено черновиков версий — %.%\nСид наполняет только опубликованные версии, эти остались бы без этапов. Удалите или опубликуйте их и повторите миграцию.',
      v_count, v_text;
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Помощники
-- ═══════════════════════════════════════════════════════════════════════════

-- Опубликованные версии девяти типов созданы миграцией
-- 20260806_product_type_form_blocks.sql; здесь мы к ним только досыпаем этапы.
-- Если версии вдруг нет, NULL молча ушёл бы в NOT NULL config_id и упал бы
-- невнятной 23502 — поэтому проверяем явно.
create or replace function pg_temp.cfg(p_product_type uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  select id into v from public.product_type_configs
   where product_type_id = p_product_type
     and status = 'published';
  if v is null then
    raise exception
      'Сид: у типа продукта % нет опубликованной версии настроек.', p_product_type;
  end if;
  return v;
end $$;

create or replace function pg_temp.stage(
  p_config    uuid,
  p_key       text,
  p_title     text,
  p_position  integer,
  p_selection text    default 'all',
  p_parent    uuid    default null,
  p_pinned    boolean default false
) returns uuid language sql as $$
  insert into public.product_type_stages(
    config_id, parent_variant_id, level, stage_group_key, title,
    position, selection_mode, is_pinned_last)
  values (
    p_config, p_parent,
    case when p_parent is null then 0 else 1 end,
    p_key, p_title, p_position, p_selection, p_pinned)
  returning id;
$$;

create or replace function pg_temp.wp(
  p_stage         uuid,
  p_workplace     text,
  p_variant_title text    default null,
  p_default       boolean default false,
  p_sort          integer default 0
) returns uuid language sql as $$
  insert into public.product_type_stage_workplaces(
    stage_id, workplace_id, variant_title, is_default, sort_order)
  values (p_stage, p_workplace, p_variant_title, p_default, p_sort)
  returning id;
$$;

create or replace function pg_temp.cond(
  p_stage     uuid,
  p_predicate text,
  p_param     text default null
) returns void language sql as $$
  insert into public.product_type_stage_conditions(stage_id, predicate, param_text)
  values (p_stage, p_predicate, p_param);
$$;

-- Одиночный этап: ключ = uuid рабочего места, одно РМ, необязательное условие.
create or replace function pg_temp.simple(
  p_config    uuid,
  p_workplace text,
  p_title     text,
  p_position  integer,
  p_predicate text default null,
  p_parent    uuid default null
) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.stage(p_config, p_workplace, p_title, p_position, 'all', p_parent);
  perform pg_temp.wp(v, p_workplace);
  if p_predicate is not null then
    perform pg_temp.cond(v, p_predicate);
  end if;
  return v;
end $$;

-- R1, R2. Базовые этапы, одинаковые у всех девяти типов.
create or replace function pg_temp.base_stages(p_config uuid)
returns void language plpgsql as $$
begin
  -- R1  Бабинорезка, когда заказ уже формата бумаги
  perform pg_temp.simple(p_config, 'b92a89d1-8e95-4c6d-b990-e308486e4bf1',
                         'Бабинорезка', 1, 'needs_bobbin_cutting');
  -- R2  Флексопечать, когда в заказе есть краски
  perform pg_temp.simple(p_config, '0571c01c-f086-47e4-81b2-5d8b2ab91218',
                         'Флексопечать', 2, 'has_paint');
end $$;

-- R30. Упаковка: всегда есть, всегда последняя, техлид её не двигает.
create or replace function pg_temp.packaging(p_config uuid)
returns void language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.stage(p_config, 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1',
                     'Упаковка', 999, 'all', null, true);
  perform pg_temp.wp(v, 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1');
end $$;

-- R26, R27, R28. Ручки: три взаимоисключающих этапа на ОДНОЙ позиции.
-- Одновременно из них присутствует ровно один — тот, чей тип ручки выбран в
-- заказе; поэтому общая позиция законна и уникальности по ней нет.
-- Плоская и кручёная — по два рабочих места на шаге (профильное плюс ручное).
create or replace function pg_temp.handles(p_config uuid, p_position integer)
returns void language plpgsql as $$
declare v uuid;
begin
  -- R26  Плоская ручка
  v := pg_temp.stage(p_config, 'flat_handle_group', 'Плоская ручка', p_position);
  perform pg_temp.wp(v, '6fdff2d9-3f57-45ca-9fad-dd700ac5c320', null, false, 1); -- Ручка-склейка плоская
  perform pg_temp.wp(v, 'c25ac6fa-390a-4e87-84aa-536055e013f4', null, false, 2); -- Ручка-склейка ручная
  perform pg_temp.cond(v, 'handle_type_is', 'flat');

  -- R27  Кручёная ручка
  v := pg_temp.stage(p_config, 'twisted_handle_group', 'Кручёная ручка', p_position);
  perform pg_temp.wp(v, 'c5c1eb2e-dac8-4068-9e4c-ced8fb975626', null, false, 1); -- Ручка-склейка крученая
  perform pg_temp.wp(v, 'c25ac6fa-390a-4e87-84aa-536055e013f4', null, false, 2); -- Ручка-склейка ручная
  perform pg_temp.cond(v, 'handle_type_is', 'twisted');

  -- R28  Вырубка. Ключ 9f3e — тот, что существует в справочнике; в старых
  -- планах встречается опечатка 9f5e, исправлять её здесь не наша задача.
  v := pg_temp.simple(p_config, '4925309c-a2c6-4f5f-9f3e-7dd5ff38827d',
                      'Вырубка', p_position);
  perform pg_temp.cond(v, 'handle_type_is', 'dieCut');

  -- R29 «ручки нет» строк не имеет: отсутствие подходящего условия и есть
  -- отсутствие этапа.
end $$;

-- R17, R24. Склейка дна: три альтернативных рабочих места ОДНОГО шага,
-- все три попадают в план строками с общим stage_group_key и общим step_no.
create or replace function pg_temp.bottom_glue(
  p_config uuid, p_position integer, p_parent uuid default null
) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := pg_temp.stage(p_config, 'bottom_glue_group', 'Склейка дна',
                     p_position, 'all', p_parent);
  perform pg_temp.wp(v, 'dee83c5c-4624-4ca4-b36c-47673dc5cd72', null, false, 1); -- Склейка дна(ручная)
  perform pg_temp.wp(v, 'ad504db5-86c3-4284-8266-42bbf967b064', null, false, 2); -- Склейка дна (Горячая)
  perform pg_temp.wp(v, '96075b60-77d8-4fb2-91b0-bfbe6c1ed13c', null, false, 3); -- Склейка дна (Холодная)
  return v;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ЛИСТЫ  (R3, R4, ручка)
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare c uuid := pg_temp.cfg('aab3ed17-1688-43f0-b623-58dac264941f');
begin
  perform pg_temp.base_stages(c);
  -- R3  Листорезка — безусловно
  perform pg_temp.simple(c, '19a67630-8374-4f9f-ae5b-f2f66828720b', 'Листорезка', 3);
  -- R4  Резка — при подрезке
  perform pg_temp.simple(c, 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba', 'Резка', 4,
                         'has_trimming');
  perform pg_temp.handles(c, 5);
  perform pg_temp.packaging(c);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- В-ОБРАЗНЫЕ — четыре категории с одинаковым маршрутом  (R6, R7, ручка)
-- Вариант БЕЗ подочереди: переключатель меняет одно рабочее место и подпись
-- этапа, состав очереди не трогает. Ни одной строки level = 1.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  c uuid;
  v uuid;
  pt uuid;
begin
  foreach pt in array array[
    '448b731a-eafe-40f1-9268-bc5dd6ba57bc'::uuid,  -- В-образный окно
    '688ce20b-2db5-43ed-a414-dda08443a06a'::uuid,  -- В-образный пакет
    'd2323dba-74c9-4e86-adfb-18cd47be9480'::uuid,  -- В-образный фри
    'dfd3beb1-1afd-4c06-9b3b-5da680377b0d'::uuid   -- В-образный уголок
  ] loop
    c := pg_temp.cfg(pt);
    perform pg_temp.base_stages(c);

    -- R6  Переключатель Фри/Окно, по умолчанию Фри
    v := pg_temp.stage(c, 'v_main_switch', 'Формирование дна', 3, 'one_of');
    perform pg_temp.wp(v, '92d96ee9-0519-40b9-bd17-9bec475496b6', 'Фри',  true,  1);
    perform pg_temp.wp(v, '8337f16e-c2d1-42dc-966d-6277ba3c1a50', 'Окно', false, 2);

    -- R7  Резка — при подрезке
    perform pg_temp.simple(c, 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba', 'Резка', 4,
                           'has_trimming');
    perform pg_temp.handles(c, 5);
    perform pg_temp.packaging(c);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ПАКЕТ ИЗ 2Х ЛИСТОВ  (R9–R17, ручка)
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  c uuid := pg_temp.cfg('b07cd977-939c-4d4f-b68c-8d163341460e');
  v uuid;
begin
  perform pg_temp.base_stages(c);

  -- R9   Листорезка
  perform pg_temp.simple(c, '19a67630-8374-4f9f-ae5b-f2f66828720b', 'Листорезка', 3);
  -- R10  Резка — при подрезке
  perform pg_temp.simple(c, 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba', 'Резка', 4,
                         'has_trimming');

  -- R11  Высечка A1/A2 — два рабочих места на одном шаге
  v := pg_temp.stage(c, 'die_cut_a1_a2', 'Высечка A1/A2', 5);
  perform pg_temp.wp(v, '7c168998-76b8-4a4c-9708-af45c2dbd4f0', null, false, 1); -- Высечка А1
  perform pg_temp.wp(v, '5a47821b-c276-4deb-90de-f196539fc95d', null, false, 2); -- Высечка А2

  -- R12  Скотч
  perform pg_temp.simple(c, 'a9e21c59-e145-4074-8d24-f2db089c8747', 'Скотч', 6);
  -- R13  С 2х листов
  perform pg_temp.simple(c, '008a5bbd-86f8-48c1-a98b-0034f80492a6', 'С 2х листов', 7);
  -- R14  Сборка трубы
  perform pg_temp.simple(c, '4e4750b0-5849-42be-94b8-a721a68b85da', 'Сборка трубы', 8);
  -- R15  Резка картона — при картоне
  perform pg_temp.simple(c, 'd7d91f75-2f85-446f-8c1d-a20606bdb3b1', 'Резка картона', 9,
                         'has_cardboard');
  -- R16  Сборка дно+картон — безусловно, даже без картона
  perform pg_temp.simple(c, 'd15da69b-9842-4967-96ed-28a4834b409e',
                         'Сборка дно+картон', 10);
  -- R17  Склейка дна — три рабочих места
  perform pg_temp.bottom_glue(c, 11);

  perform pg_temp.handles(c, 12);
  perform pg_temp.packaging(c);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- П-ОБРАЗНЫЙ ПАКЕТ  (R19–R24, ручка)
-- Единственный тип с подочередями. Здесь проверяется главное решение схемы:
-- под-этапы вариантов стоят на позициях 6–8, а между ними и переключателем
-- (позиция 3) находятся ДВА общих этапа — Резка и Резка картона.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  c        uuid := pg_temp.cfg('71c889cb-b24c-4bda-9a69-ae312f9a4bbd');
  v_switch uuid;
  v_big    uuid;
  v_small  uuid;
  v_tube   uuid;
begin
  perform pg_temp.base_stages(c);

  -- R19  Переключатель Автомат большой / Автомат маленький / Труба,
  --      по умолчанию Автомат большой
  v_switch := pg_temp.stage(c, 'p_main_switch', 'Сборка пакета', 3, 'one_of');
  v_big   := pg_temp.wp(v_switch, 'fdbf1735-a67c-47c9-a7e1-90546e1fe6ed',
                        'Автомат большой',    true,  1);
  v_small := pg_temp.wp(v_switch, 'cbcbe469-b924-4064-ae05-885ccd1b842a',
                        'Автомат маленький',  false, 2);
  v_tube  := pg_temp.wp(v_switch, 'e62fc013-4785-43f3-b3ee-a3ca51777199',
                        'Труба',              false, 3);

  -- R20  Резка — при подрезке. Общий этап, стоит ПЕРЕД под-этапами вариантов.
  perform pg_temp.simple(c, 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba', 'Резка', 4,
                         'has_trimming');
  -- R21  Резка картона — при картоне. Тоже общий: нужна и автоматам, и трубе.
  perform pg_temp.simple(c, 'd7d91f75-2f85-446f-8c1d-a20606bdb3b1', 'Резка картона', 5,
                         'has_cardboard');

  -- R22  Вставка картона — при картоне И НЕ Труба.
  --      Отрицания здесь нет: «не Труба» выражено принадлежностью под-этапа
  --      двум вариантам-автоматам. Отсюда и две строки вместо одной — плата
  --      за то, что при добавлении четвёртого варианта правило не соврёт
  --      молча, а просто не будет к нему привязано.
  perform pg_temp.simple(c, 'ce15da53-34bb-4a48-acef-610dddfad42e',
                         'Вставка картона', 6, 'has_cardboard', v_big);
  perform pg_temp.simple(c, 'ce15da53-34bb-4a48-acef-610dddfad42e',
                         'Вставка картона', 6, 'has_cardboard', v_small);

  -- R23  Сборка дно+картон — только Труба, безусловно.
  --      Труба собирает дно всегда, даже без картона: раньше эти этапы жили
  --      внутри ветки картона, и переключение автомата на трубу без картона
  --      вообще не меняло маршрут.
  perform pg_temp.simple(c, 'd15da69b-9842-4967-96ed-28a4834b409e',
                         'Сборка дно+картон', 7, null, v_tube);
  -- R24  Склейка дна — только Труба, три рабочих места
  perform pg_temp.bottom_glue(c, 8, v_tube);

  perform pg_temp.handles(c, 9);
  perform pg_temp.packaging(c);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- РУЛОННАЯ ПЕЧАТЬ и ГОТОВАЯ ПРОДУКЦИЯ  (R36)
-- Продуктового маршрута нет — старый билдер их не распознаёт. База и Упаковка
-- ставятся именно затем, чтобы паритет сохранился: без них новая сборка
-- отдала бы пустую очередь, а старая отдаёт базу плюс Упаковку.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  c  uuid;
  pt uuid;
begin
  foreach pt in array array[
    '3e5b7098-382f-4fda-8021-77721618c6ac'::uuid,  -- Рулонная печать
    '434a2fe1-73f1-4bf0-8e16-cb6f4a7b67b1'::uuid   -- Готовая продукция
  ] loop
    c := pg_temp.cfg(pt);
    perform pg_temp.base_stages(c);
    perform pg_temp.packaging(c);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Контроль: ни одна из девяти версий не должна быть структурно битой
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  v_problem record;
  v_count   integer := 0;
  v_text    text := '';
begin
  for v_problem in
    select c.id, cat.title as product_type, p.message
      from product_type_configs c
      join warehouse_categories cat on cat.id = c.product_type_id
      cross join lateral validate_product_type_config(c.id) p
     where c.status = 'published'
     order by cat.title
  loop
    v_count := v_count + 1;
    v_text := v_text || format(E'\n  %s: %s', v_problem.product_type, v_problem.message);
  end loop;

  if v_count > 0 then
    raise exception 'Сид собран неверно, найдено проблем: %.%', v_count, v_text;
  end if;

  raise notice 'Сид: все девять версий проходят структурную проверку.';
end $$;
