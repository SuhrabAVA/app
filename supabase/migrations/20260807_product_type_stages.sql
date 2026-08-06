-- Настройки типа продукта, фаза 3, часть 1 из 2: СХЕМА правил очереди.
-- Сид девяти типов вынесен в 20260807_product_type_stages_seed.sql — его
-- читают и правят отдельно, это перенос 36 правил руками.
--
-- ЧТО ЭТО ЗАКРЫВАЕТ
-- Маршрут производства сегодня зашит в stage_queue_builder.dart: 36 правил,
-- ни одно не параметризовано. Эти таблицы дают тот же маршрут данными.
-- На боевой путь миграция НЕ влияет: сборщик по-прежнему старый, таблицы
-- никем не читаются до фазы 3.5.
--
-- ГЛАВНОЕ РЕШЕНИЕ СХЕМЫ: ПРИНАДЛЕЖНОСТЬ ≠ МЕСТО
-- Макет предполагал, что под-этапы варианта идут сплошным блоком сразу за
-- переключателем. Реальный маршрут П-образного пакета это опровергает:
--     3 переключатель Автомат/Труба
--     4 Резка              (общий)
--     5 Резка картона      (общий)
--     6 Вставка картона    ← принадлежит вариантам-автоматам
--     7 Сборка дно+картон  ← принадлежит варианту Труба
--     8 Склейка дна        ← принадлежит варианту Труба
--     9 ручка              (общий)
-- Между переключателем и его под-этапами стоят два ОБЩИХ этапа, поэтому
-- вставить подочередь сплошным блоком нельзя ни при какой точке вставки.
-- Отсюда: parent_variant_id отвечает на вопрос «чьё это и что удалится
-- вместе с вариантом», position — на вопрос «где стоит». Позиция сквозная
-- по всему конфигу, включая под-этапы. В редакторе список под-этапов
-- варианта — отфильтрованный вид, а превью показывает СЛИТУЮ очередь.
--
-- ПОЧЕМУ РЕКУРСИЯ, А НЕ ОТДЕЛЬНАЯ ТАБЛИЦА ПОД-ЭТАПОВ
-- Под-этап не проще этапа: «Склейка дна» — это три рабочих места на одном
-- шаге, и условия под-этапу тоже нужны. Отдельная таблица потребовала бы
-- зеркалить три таблицы (этапы, их РМ, их условия) и второй путь исполнения
-- в сборщике. Это ровно то дублирование, которое дало нам опечатки в uuid,
-- вылеченные реестром production_ids.dart. Глубина ограничена декларативно
-- колонкой level: под-этап имеет level = 1, его собственные под-этапы
-- потребовали бы level = 2, что запрещено CHECK. Вложенность вариантов в
-- вариантах невозможна по построению, без единого триггера.
--
-- ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ
-- Предиката variant_selected нет. Правило «Вставка картона при картоне И НЕ
-- Труба» в этой схеме теряет отрицание: «не Труба» выражается тем, ЧЬИМ
-- под-этапом является строка. Проверено на всех 36 правилах — каждое
-- сводится максимум к одному предикату. Цена — дублирование «Вставки
-- картона» под двумя вариантами-автоматами; принято сознательно, потому что
-- дублирование видно в редакторе, а негативное условие молча перестаёт быть
-- верным при добавлении четвёртого варианта.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Справочник предикатов
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Закрытый набор: техлид выбирает из списка, но не сочиняет выражения.
-- Обоснование в отчёте фазы 1 — входов у автосборщика всего пять, ни одно из
-- 36 правил не требует ни OR, ни арифметики, а мини-DSL ради пяти булевых
-- входов потребовал бы парсера, валидатора и редактора выражений.
--
-- Предиката «always» намеренно нет: ОТСУТСТВИЕ строк условий и означает
-- «всегда». Тот же принцип, что и у product_type_form_blocks, где отсутствие
-- строки означает «блок виден» — таблицы хранят только отклонения.

create table public.order_predicates (
  code       text primary key,
  title      text not null,
  param_kind text check (param_kind in ('handle_type')),
  sort_order integer not null default 0
);

comment on table public.order_predicates is
  'Условия, которые правило может проверить у ЗАКАЗА (не у настроек типа '
  'продукта). Каждый код реализован функцией в Dart; новый предикат требует '
  'релиза приложения, техлид сам его не заводит.';

comment on column public.order_predicates.param_kind is
  'NULL — предикат булев. handle_type — требует значения в '
  'product_type_stage_conditions.param_text: flat | twisted | dieCut '
  '(имена значений enum OrderHandleType).';

insert into public.order_predicates (code, title, param_kind, sort_order) values
  ('has_paint',            'В заказе есть краски',                  null, 10),
  ('has_cardboard',        'В заказе есть картон',                  null, 20),
  ('has_trimming',         'В заказе есть подрезка',                null, 30),
  ('handle_type_is',       'Тип ручки',                    'handle_type', 40),
  -- Не имеет соответствующего блока формы: признак вычисляется по всему
  -- списку бумаг заказа (существует бумага, у которой ширина заказа строго
  -- меньше формата, с допуском). Разбор — в отчёте фазы 1. Поэтому список
  -- условий в редакторе состоит из ПРЕДИКАТОВ, а не из блоков: список блоков
  -- сделал бы Бабинорезку невыразимой.
  ('needs_bobbin_cutting', 'Ширина заказа меньше формата бумаги',   null, 50);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Этапы маршрута
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Внешний ключ parent_variant_id добавляется ниже отдельным ALTER: таблицы
-- ссылаются друг на друга по кругу (этап → РМ-вариант → под-этап), и в
-- CREATE TABLE это выразить нельзя.

create table public.product_type_stages (
  id                uuid primary key default gen_random_uuid(),
  config_id         uuid not null
                      references public.product_type_configs(id) on delete cascade,
  parent_variant_id uuid,
  level             smallint not null default 0,
  stage_group_key   text not null,
  title             text not null,
  position          integer not null,
  selection_mode    text not null default 'all'
                      check (selection_mode in ('all','one_of')),
  is_enabled        boolean not null default true,
  is_pinned_last    boolean not null default false,
  created_at        timestamptz not null default now(),

  constraint product_type_stages_level_ck
    check (level in (0, 1)),
  -- Ровно одно из двух: либо этап верхнего уровня без родителя, либо
  -- под-этап варианта. Третьего состояния нет.
  constraint product_type_stages_parent_level_ck
    check ((level = 0) = (parent_variant_id is null)),
  constraint product_type_stages_position_ck
    check (position > 0)
);

comment on table public.product_type_stages is
  'Этап маршрута типа продукта. Строки уровня 0 — общая очередь, уровня 1 — '
  'под-этапы варианта переключаемого этапа. Позиция сквозная по конфигу для '
  'обоих уровней.';

comment on column public.product_type_stages.stage_group_key is
  'Ключ этапа в плане заказа: попадает в prod_plan_stages.stage_group_key, по '
  'нему потребители группируют строки одного шага. У этапа с одним рабочим '
  'местом равен uuid этого РМ; у групп — устойчивый текстовый ключ '
  '(bottom_glue_group, p_main_switch, v_main_switch, die_cut_a1_a2, '
  'flat_handle_group, twisted_handle_group). Эти шесть перенесены в сид '
  'БУКВАЛЬНО: на них ссылаются живые планы. Ключи новых групп генерирует '
  'система, техлид задаёт только подпись.';

comment on column public.product_type_stages.title is
  'Отображаемая подпись. Для selection_mode = one_of подпись этапа в очереди '
  'берётся у ВЫБРАННОГО варианта (product_type_stage_workplaces.variant_title), '
  'а это поле служит меткой в редакторе. Переименование меняет только подпись '
  'и никогда не ключ.';

comment on column public.product_type_stages.position is
  'Место в очереди. Единственный способ задать порядок: «после этапа Y» в '
  'редакторе — жест ввода, который превращается в позицию при сохранении. '
  'Хранить обе формы нельзя — ссылка «после Y» повисает, когда Y удалён или '
  'сам условен и в конкретном заказе отсутствует. Уникальности НЕТ намеренно: '
  'под-этапы разных вариантов одного переключателя стоят на одной позиции и '
  'никогда не встречаются в одной очереди. Порядок при равных позициях '
  'детерминирован сортировкой (position, stage_group_key).';

comment on column public.product_type_stages.is_enabled is
  'Выключить этап, не удаляя его. Переключатель «активен» из макета.';

comment on column public.product_type_stages.is_pinned_last is
  'Упаковка. Техлид её не двигает и не удаляет: actual_qty пересчитывается '
  'только после завершения упаковки (recomputeOrderActualQty), а '
  'stage_sequence_utils разрешает ей стартовать вне очереди — разрешить '
  'перемещение значит молча сломать аналитику. Редактор показывает этап без '
  'кнопок перемещения и удаления, с пояснением.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Рабочие места этапа
-- ═══════════════════════════════════════════════════════════════════════════

create table public.product_type_stage_workplaces (
  id            uuid primary key default gen_random_uuid(),
  stage_id      uuid not null
                  references public.product_type_stages(id) on delete cascade,
  -- ТИП НЕ uuid. public.workplaces.id объявлен как text, и prod_plan_stages
  -- .stage_id тоже text. Здесь тот же тип сознательно: приведение на границе
  -- дало бы ровно ту ошибку 42883 (operator does not exist: text = uuid),
  -- которую мы уже ловили в RPC.
  workplace_id  text not null references public.workplaces(id),
  variant_title text,
  is_default    boolean not null default false,
  sort_order    integer not null default 0,
  unique (stage_id, workplace_id)
);

comment on table public.product_type_stage_workplaces is
  'Рабочие места этапа. При selection_mode = all все они попадают в план '
  'N строками с общим stage_group_key и общим step_no. При one_of строка — '
  'это ВАРИАНТ: в план идёт только выбранный, а остальные варианты могут '
  'владеть собственными под-этапами.';

comment on column public.product_type_stage_workplaces.variant_title is
  'Подпись варианта; для one_of становится названием этапа в очереди '
  '(сегодня эту роль играет функция _selectedName в билдере). Для '
  'selection_mode = all не используется.';

-- Вариант по умолчанию у этапа ровно один.
create unique index product_type_stage_workplaces_default_uq
  on public.product_type_stage_workplaces (stage_id)
  where is_default;

-- Замыкаем круг: под-этап принадлежит РМ-варианту. Каскад работает по цепочке
-- конфиг → этап → РМ-вариант → под-этап → его РМ и обрывается на level = 1.
alter table public.product_type_stages
  add constraint product_type_stages_parent_variant_fkey
  foreign key (parent_variant_id)
  references public.product_type_stage_workplaces(id) on delete cascade;

-- NULLS NOT DISTINCT обязателен: без него parent_variant_id = NULL считался бы
-- различным в каждой строке, и уникальность ключа на верхнем уровне пропала бы.
alter table public.product_type_stages
  add constraint product_type_stages_key_uq
  unique nulls not distinct (config_id, parent_variant_id, stage_group_key);

create index product_type_stages_config_idx
  on public.product_type_stages (config_id, position);
create index product_type_stages_parent_idx
  on public.product_type_stages (parent_variant_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Условия появления этапа
-- ═══════════════════════════════════════════════════════════════════════════

create table public.product_type_stage_conditions (
  id         uuid primary key default gen_random_uuid(),
  stage_id   uuid not null
               references public.product_type_stages(id) on delete cascade,
  predicate  text not null references public.order_predicates(code),
  negate     boolean not null default false,
  param_text text,
  unique (stage_id, predicate, param_text)
);

comment on table public.product_type_stage_conditions is
  'Условия одного этапа соединяются только через AND; отсутствие строк '
  'означает «всегда». OR не заведён намеренно — ни одно из 36 текущих правил '
  'его не требует, а его появление сразу потребовало бы дерева выражений и '
  'скобок в редакторе. После перехода на подочереди каждое правило сводится '
  'максимум к ОДНОМУ предикату, поэтому редактор фазы 3 показывает одно '
  'условие на этап, а список остаётся заделом.';

comment on column public.product_type_stage_conditions.negate is
  'Задел. В сиде не используется ни разу: отрицание, которое было нужно '
  'правилу «Вставка картона при картоне И НЕ Труба», теперь выражено '
  'принадлежностью под-этапа варианту.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Валидация структуры конфига
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Часть инвариантов сквозная по таблицам, и CHECK их не выражает: например,
-- «родитель под-этапа обязан быть рабочим местом переключаемого этапа ТОГО ЖЕ
-- конфига». Проверяем не триггером на каждой вставке, а один раз при
-- публикации — там, где техлид нажимает кнопку и может прочитать причину.
-- Отдельная функция, а не код внутри publish, чтобы редактор мог показать
-- список проблем ДО попытки публикации.

create or replace function public.validate_product_type_config(
  p_config_id uuid
)
returns table (code text, message text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  -- Этап без рабочих мест: в план из него ничего не попадёт.
  select 'stage_without_workplaces',
         format('Этап «%s» не имеет ни одного рабочего места.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id)

  union all
  -- Переключаемый этап с одним вариантом переключать нечем.
  select 'one_of_needs_two_variants',
         format('Переключаемый этап «%s»: вариантов меньше двух.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and (select count(*) from product_type_stage_workplaces w
           where w.stage_id = s.id) < 2

  union all
  -- Вариант по умолчанию нужен: без него сборщик не знает, что брать, когда
  -- заказ ещё не выбрал. Второй такой вариант отсекает уникальный индекс.
  select 'one_of_without_default',
         format('Переключаемый этап «%s»: не выбран вариант по умолчанию.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id and w.is_default)

  union all
  -- Под-этап чужого конфига: каскад бы его не удалил вместе со своим типом
  -- продукта, и он остался бы висеть.
  select 'sub_stage_foreign_config',
         format('Под-этап «%s» принадлежит варианту из другого типа продукта.', s.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.config_id <> s.config_id

  union all
  -- У этапа с режимом «все РМ» вариантов нет, значит и под-этапов быть не может.
  select 'sub_stage_parent_not_switchable',
         format('Под-этап «%s» привязан к рабочему месту этапа «%s», '
                'который не является переключаемым.', s.title, parent.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.selection_mode <> 'one_of'

  union all
  -- Значение параметра сверяем со списком имён enum OrderHandleType.
  select 'bad_handle_type_param',
         format('Этап «%s»: недопустимый тип ручки «%s».',
                s.title, coalesce(c.param_text, '—'))
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
   where s.config_id = p_config_id
     and c.predicate = 'handle_type_is'
     and coalesce(c.param_text, '') not in ('flat', 'twisted', 'dieCut')

  union all
  -- Булев предикат с параметром — почти наверняка опечатка редактора.
  select 'unexpected_param',
         format('Этап «%s»: условие «%s» не принимает значения.', s.title, c.predicate)
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
    join order_predicates p on p.code = c.predicate
   where s.config_id = p_config_id
     and p.param_kind is null
     and c.param_text is not null

  union all
  -- Пустой маршрут публиковать нельзя. Это же и предохранитель от черновика,
  -- созданного ради правки блоков формы: без копирования этапов из
  -- опубликованной версии он оказался бы с нулём этапов, и его публикация
  -- обнулила бы маршрут типа продукта. Проверка делает такой случай громким.
  select 'route_empty',
         'Маршрут пуст: не задано ни одного этапа.'
    from (select 1) _
   where not exists (select 1 from product_type_stages s
                      where s.config_id = p_config_id)

  union all
  -- Упаковка обязана быть и обязана быть одна.
  select 'packaging_missing',
         'В маршруте нет ровно одного завершающего этапа упаковки.'
    from (select 1) _
   where exists (select 1 from product_type_stages s where s.config_id = p_config_id)
     and (select count(*) from product_type_stages s
           where s.config_id = p_config_id and s.is_pinned_last) <> 1

  union all
  -- Упаковка — этап верхнего уровня, а не под-этап варианта.
  select 'packaging_not_top_level',
         format('Завершающий этап «%s» не может быть под-этапом варианта.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.is_pinned_last
     and s.level <> 0;
$function$;

comment on function public.validate_product_type_config(uuid) is
  'Возвращает список структурных проблем версии настроек: пустой результат = '
  'версию можно публиковать. Проверяет инварианты, которые не выражаются '
  'через CHECK, потому что сквозные по таблицам.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Публикация не выпускает битую версию
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Дополняем publish_product_type_config проверкой структуры. Остальное тело
-- функции без изменений — оно применено миграцией
-- 20260806_publish_product_type_config.sql и там же объяснено.

create or replace function public.publish_product_type_config(
  p_config_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_product_type_id uuid;
  v_status          text;
  v_version         integer;
  v_problem         record;
  v_problems        text := '';
  v_count           integer := 0;
begin
  if p_config_id is null then
    raise exception
      'Не удалось опубликовать настройки: не указана версия.'
      using errcode = '22023';
  end if;

  select product_type_id, status, version
    into v_product_type_id, v_status, v_version
    from product_type_configs
   where id = p_config_id
   for update;

  -- P0002 (no_data_found), а не 23503: тот означает foreign_key_violation и
  -- здесь семантически неверен. Хаб категорий разбирает 23503 как «на
  -- категорию ссылаются заказы», и общий обработчик, ветвящийся по коду,
  -- показал бы неверное сообщение.
  if not found then
    raise exception
      'Не удалось опубликовать настройки: версия не найдена. Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_status <> 'draft' then
    raise exception
      'Не удалось опубликовать настройки: версия % уже имеет статус «%», '
      'публиковать можно только черновик. Обновите экран.',
      v_version, v_status
      using errcode = '22023';
  end if;

  -- Структурная проверка. Собираем первые три проблемы в одно сообщение:
  -- техлиду нужен повод открыть список, а не весь список в снекбаре.
  for v_problem in
    select message from validate_product_type_config(p_config_id) limit 3
  loop
    v_count := v_count + 1;
    v_problems := v_problems || ' ' || v_problem.message;
  end loop;

  if v_count > 0 then
    raise exception
      'Не удалось опубликовать настройки: маршрут собран неверно.%',
      v_problems
      using errcode = '23514';
  end if;

  update product_type_configs
     set status = 'archived'
   where product_type_id = v_product_type_id
     and status = 'published';

  if exists (
    select 1
      from product_type_configs
     where product_type_id = v_product_type_id
       and status = 'published'
       and id <> p_config_id
  ) then
    raise exception
      'Не удалось опубликовать настройки: параллельно опубликована другая '
      'версия. Обновите экран и повторите.'
      using errcode = '40001';
  end if;

  update product_type_configs
     set status       = 'published',
         published_at = now()
   where id = p_config_id;

  return p_config_id;
end;
$function$;

comment on function public.publish_product_type_config(uuid) is
  'Атомарно публикует черновик настроек типа продукта: проверяет структуру '
  'через validate_product_type_config, прежнюю опубликованную версию '
  'переводит в archived, черновик — в published с published_at. Возвращает id '
  'опубликованной версии. Публиковать можно только строку со status = draft.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Создание черновика — глубокая копия опубликованной версии
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ЗАЧЕМ СЕРВЕРНАЯ ФУНКЦИЯ
-- Сегодня черновик создаёт клиент: вставляет шапку версии и копирует строки
-- product_type_form_blocks. С появлением этапов копировать нужно граф —
-- этапы, их рабочие места, условия, — да ещё и переложить parent_variant_id
-- на НОВЫЕ id рабочих мест. Клиентом это N+1 запросов без транзакции: обрыв
-- на середине оставит черновик с половиной маршрута, и техлид опубликует
-- его, не заметив. Тот же класс дефекта, что чинили в replace_plan_stages и
-- в publish_product_type_config.
--
-- ИДЕМПОТЕНТНОСТЬ
-- Если черновик уже есть, функция возвращает его и ничего не создаёт. Это
-- закрывает вторую дыру: экран настроек ищет черновик при открытии, но два
-- одновременно открытых экрана могли создать по своему. Блокировка версий
-- типа продукта в начале транзакции делает гонку невозможной.

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

  insert into product_type_configs(product_type_id, version, status, note)
  values (p_product_type_id, v_version, 'draft',
          'Черновик правки настроек типа продукта.')
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

  -- Карта «старый id → новый» нужна только для рабочих мест: на них
  -- ссылаются под-этапы. drop if exists — на случай двух вызовов в одной
  -- транзакции, ON COMMIT DROP срабатывает лишь на коммите.
  drop table if exists _draft_wp_map;
  create temporary table _draft_wp_map(
    old_id uuid primary key,
    new_id uuid not null
  ) on commit drop;

  -- Сначала верхний уровень: его рабочие места станут родителями под-этапов.
  for v_stage in
    select * from product_type_stages
     where config_id = v_published and level = 0
     order by position, stage_group_key
  loop
    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last)
    values (
      v_draft, null, 0, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last)
    returning id into v_new_stage;

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

      insert into _draft_wp_map(old_id, new_id) values (v_wp.id, v_new_wp);
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
      from _draft_wp_map
     where old_id = v_stage.parent_variant_id;

    if v_new_parent is null then
      raise exception
        'Не удалось создать черновик: под-этап «%» ссылается на вариант, '
        'которого нет в опубликованной версии.', v_stage.title
        using errcode = '23503';
    end if;

    insert into product_type_stages(
      config_id, parent_variant_id, level, stage_group_key, title,
      position, selection_mode, is_enabled, is_pinned_last)
    values (
      v_draft, v_new_parent, 1, v_stage.stage_group_key, v_stage.title,
      v_stage.position, v_stage.selection_mode, v_stage.is_enabled,
      v_stage.is_pinned_last)
    returning id into v_new_stage;

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

  return v_draft;
end;
$function$;

comment on function public.create_product_type_config_draft(uuid) is
  'Создаёт черновик настроек типа продукта глубокой копией опубликованной '
  'версии: блоки формы, этапы, их рабочие места и условия, с перекладкой '
  'parent_variant_id на новые id вариантов. Идемпотентна — если черновик уже '
  'есть, возвращает его.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Права и RLS — как у соседних таблиц настроек
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Обоснование модели — в шапке 20260806_product_type_form_blocks.sql: 50
-- сотрудников работают через две записи auth.users, идентичность до Postgres
-- не доходит, user_roles пуста. Разграничение остаётся в UI.

grant select on public.order_predicates
  to anon, authenticated, service_role;

grant select, insert, update, delete on public.product_type_stages
  to anon, authenticated, service_role;
grant select, insert, update, delete on public.product_type_stage_workplaces
  to anon, authenticated, service_role;
grant select, insert, update, delete on public.product_type_stage_conditions
  to anon, authenticated, service_role;

revoke execute on function public.validate_product_type_config(uuid) from public;
grant  execute on function public.validate_product_type_config(uuid) to authenticated;

revoke execute on function public.create_product_type_config_draft(uuid) from public;
grant  execute on function public.create_product_type_config_draft(uuid) to authenticated;

alter table public.order_predicates                enable row level security;
alter table public.product_type_stages             enable row level security;
alter table public.product_type_stage_workplaces   enable row level security;
alter table public.product_type_stage_conditions   enable row level security;

create policy order_predicates_select on public.order_predicates
  for select to authenticated using (true);

create policy product_type_stages_select on public.product_type_stages
  for select to authenticated using (true);
create policy product_type_stages_write on public.product_type_stages
  for all to authenticated using (true) with check (true);

create policy product_type_stage_workplaces_select
  on public.product_type_stage_workplaces
  for select to authenticated using (true);
create policy product_type_stage_workplaces_write
  on public.product_type_stage_workplaces
  for all to authenticated using (true) with check (true);

create policy product_type_stage_conditions_select
  on public.product_type_stage_conditions
  for select to authenticated using (true);
create policy product_type_stage_conditions_write
  on public.product_type_stage_conditions
  for all to authenticated using (true) with check (true);
