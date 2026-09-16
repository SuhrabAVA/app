-- Гибкий финальный этап, настраиваемая формула факта и режимы очерёдности.
--
-- ЧТО ЭТО НЕ ДЕЛАЕТ
-- Ничего из этого не меняет поведения приложения. Правила очерёдности живут
-- в stage_sequence_utils.dart, actual_qty считает task_provider.dart, и оба
-- работают по глобальным константам, а не по настройкам типа продукта.
-- Настройки можно завести, отредактировать и опубликовать — на живые заказы
-- это не повлияет до срезов T5/T6, которые идут строго после Ф3.5.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Справочник формул фактического количества
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Закрытый справочник, не выражения: вариантов конечное число, а мини-DSL
-- потребовал бы парсера и редактора формул ради четырёх строк. Добавление
-- новой формулы — строка в справочнике плюс ветка в Dart, без миграции схемы.
--
-- Состав выведен из существующего кода, а не придуман:
--   packs_times_pack_size — текущее поведение recomputeOrderActualQty;
--   last_stage_quantity   — существующая легаси-ветка для заказов без упаковки;
--   run_size, paper_length — величины, которыми уже оперирует
--                            quantity_status_service.getExpectedQuantity.
-- Формулы с валом и приладкой уточняются у производства и добавятся позже.

create table public.actual_qty_formulas (
  code        text primary key,
  title       text not null,
  description text not null,
  sort_order  integer not null default 0
);

comment on table public.actual_qty_formulas is
  'Способы посчитать orders.actual_qty. Каждый код реализован функцией в '
  'Dart; новая формула требует релиза приложения, техлид сам её не заводит.';

insert into public.actual_qty_formulas (code, title, description, sort_order) values
  ('packs_times_pack_size', 'Упаковки × фасовка',
   'Количество, зафиксированное на упаковке, умноженное на фасовку из '
   'параметра заказа «Упаковка: N». Текущее поведение.', 10),
  ('last_stage_quantity', 'Количество последнего этапа',
   'Сумма количеств этапа, отчитавшегося последним, без множителя.', 20),
  ('run_size', 'Тираж заказа',
   'Плановый тираж как есть, независимо от зафиксированных количеств.', 30),
  ('paper_length', 'Длина бумаги',
   'Суммарная длина бумаги заказа в метрах.', 40);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Формула — свойство типа продукта, а не этапа
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Она отвечает на вопрос «как из зафиксированных количеств получить факт»;
-- этап при этом только триггер. Живёт в product_type_configs, значит
-- версионируется вместе с остальными настройками и копируется в черновик
-- функцией create_product_type_config_draft без правок.
--
-- Колонка nullable намеренно: заполнять её девяти существующим типам будет
-- отдельная миграция T3. До неё инвариант actual_qty_formula_missing будет
-- срабатывать — это ожидаемо и ровно то, ради чего T3 существует.

alter table public.product_type_configs
  add column actual_qty_formula text
    references public.actual_qty_formulas(code);

comment on column public.product_type_configs.actual_qty_formula is
  'Как считать orders.actual_qty для заказов этого типа продукта. С фазы 3.5 '
  'берётся из версии, закреплённой за заказом (orders.stage_config_id), а не '
  'из текущей опубликованной: иначе публикация новых настроек меняла бы факт '
  'у заказов, которые уже в работе.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Режим очерёдности этапа
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ЗА РЕЖИМАМИ СТОЯТ ДВЕ НЕЗАВИСИМЫЕ ОСИ — фиксируем, иначе семантика поплывёт
-- при первой же правке:
--
--   режим                   ждёт завершения    держит очередь   триггер
--                           предыдущего этапа  между заказами   старта
--   sequential              да                 да               предыдущий завершён
--   free_of_chain           нет                да               свободен
--   parallel_with           нет                НЕТ              партнёр НАЧАТ
--   parallel_with_previous  нет                НЕТ              предыдущая группа
--                                                               очереди НАЧАТА
--
-- ЗАЧЕМ ЧЕТВЁРТЫЙ РЕЖИМ
-- Сегодняшнее право упаковки стартовать досрочно — это parallel_with, но
-- партнёр у него ДИНАМИЧЕСКИЙ: stage_sequence_utils берёт
-- orderedKeys[currentIndex - 1], то есть предыдущую группу СОБРАННОЙ очереди
-- конкретного заказа (stage_sequence_utils.dart:252-254). У П-образного
-- пакета это ручка, если тип ручки выбран, иначе «Склейка дна», иначе «Резка
-- картона» — зависит от условий заказа. Статический partner такое не
-- выражает, и без этого режима миграция T3 изменила бы поведение упаковки.
--
-- Что очередь между заказами на упаковке сегодня НЕ соблюдается — видно в
-- tasks_screen.dart:6067: в _isUnlockedByWorkplaceQueue стоит безусловный
-- `if (isPackagingNow) return true;` перед всеми прочими проверками.

alter table public.product_type_stages
  add column execution_mode text not null default 'sequential'
    check (execution_mode in
      ('sequential', 'free_of_chain', 'parallel_with', 'parallel_with_previous'));

alter table public.product_type_stages
  add column parallel_with_stage_id uuid
    references public.product_type_stages(id) on delete restrict;

-- Этап не может ждать собственного старта: он бы не стартовал никогда.
-- Проверка внутристрочная, поэтому выражается CHECK, а не валидатором.
alter table public.product_type_stages
  add constraint product_type_stages_parallel_self_ck
    check (parallel_with_stage_id is distinct from id);

comment on column public.product_type_stages.execution_mode is
  'Когда этап может начаться. sequential — после полного завершения '
  'предыдущего этапа заказа, с очередью между заказами. free_of_chain — не '
  'ждёт предыдущий, но очередь между заказами держит. parallel_with — '
  'стартует, как только НАЧАТ партнёр, очередь между заказами не держит. '
  'parallel_with_previous — то же, но партнёром считается предыдущая группа '
  'собранной очереди заказа (текущее поведение упаковки).';

comment on column public.product_type_stages.parallel_with_stage_id is
  'Партнёр для execution_mode = parallel_with. ON DELETE RESTRICT, а не SET '
  'NULL: обнуление оставило бы этап в режиме parallel_with без партнёра, то '
  'есть в невалидном состоянии, о котором техлид узнал бы только при '
  'публикации. При RESTRICT удаление отказывает, и редактор перечисляет '
  'зависимые этапы.';

create index product_type_stages_parallel_with_idx
  on public.product_type_stages (parallel_with_stage_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Валидатор: снятие привязки к упаковке и проверки режимов
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Убраны packaging_missing и packaging_not_top_level: последним теперь может
-- быть любой этап. Вместо них actual_qty_formula_missing — по-настоящему
-- обязательна не упаковка, а заданная формула, потому что от actual_qty
-- зависят отгрузка и списания со склада.
--
-- Заодно one_of_without_default переименован в one_of_needs_default: имя было
-- несимметрично соседнему one_of_needs_two_variants, а переиздавать функцию
-- ради одного литерала отдельно мы не стали бы. Код нигде не разбирается —
-- клиент читает только message.

create or replace function public.validate_product_type_config(
  p_config_id uuid
)
returns table (code text, message text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  -- Рёбра «этап → партнёр» и обход для поиска циклов. CTE объявлен наверху,
  -- поэтому виден всем ветвям UNION ALL ниже. Ограничение глубины — страховка
  -- от бесконечной рекурсии, а не бизнес-правило: цепочка партнёров длиннее
  -- десяти этапов означает, что что-то уже не так.
  with recursive parallel_edges as (
    select s.id as src, s.parallel_with_stage_id as dst
      from product_type_stages s
     where s.config_id = p_config_id
       and s.execution_mode = 'parallel_with'
       and s.parallel_with_stage_id is not null
  ),
  parallel_walk (start_id, node, depth) as (
    select src, dst, 1 from parallel_edges
    union all
    select w.start_id, e.dst, w.depth + 1
      from parallel_walk w
      join parallel_edges e on e.src = w.node
     where w.depth < 10
  )

  select 'stage_without_workplaces',
         format('Этап «%s» не имеет ни одного рабочего места.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id)

  union all
  select 'one_of_needs_two_variants',
         format('Переключаемый этап «%s»: вариантов меньше двух.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and (select count(*) from product_type_stage_workplaces w
           where w.stage_id = s.id) < 2

  union all
  select 'one_of_needs_default',
         format('Переключаемый этап «%s»: не выбран вариант по умолчанию.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.selection_mode = 'one_of'
     and not exists (select 1 from product_type_stage_workplaces w
                      where w.stage_id = s.id and w.is_default)

  union all
  select 'sub_stage_foreign_config',
         format('Под-этап «%s» принадлежит варианту из другого типа продукта.', s.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.config_id <> s.config_id

  union all
  select 'sub_stage_parent_not_switchable',
         format('Под-этап «%s» привязан к рабочему месту этапа «%s», '
                'который не является переключаемым.', s.title, parent.title)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages parent on parent.id = w.stage_id
   where s.config_id = p_config_id
     and parent.selection_mode <> 'one_of'

  union all
  select 'bad_handle_type_param',
         format('Этап «%s»: недопустимый тип ручки «%s».',
                s.title, coalesce(c.param_text, '—'))
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
   where s.config_id = p_config_id
     and c.predicate = 'handle_type_is'
     and coalesce(c.param_text, '') not in ('flat', 'twisted', 'dieCut')

  union all
  select 'unexpected_param',
         format('Этап «%s»: условие «%s» не принимает значения.', s.title, c.predicate)
    from product_type_stage_conditions c
    join product_type_stages s on s.id = c.stage_id
    join order_predicates p on p.code = c.predicate
   where s.config_id = p_config_id
     and p.param_kind is null
     and c.param_text is not null

  union all
  select 'route_empty',
         'Маршрут пуст: не задано ни одного этапа.'
    from (select 1) _
   where not exists (select 1 from product_type_stages s
                      where s.config_id = p_config_id)

  union all
  -- Заменяет packaging_missing. Раньше инвариантом было «есть ровно один
  -- завершающий этап упаковки»; теперь последним может быть любой этап, и
  -- по-настоящему обязательна не упаковка, а ЗАДАННАЯ ФОРМУЛА: без неё
  -- actual_qty не определён, а от него зависят отгрузка и списания.
  select 'actual_qty_formula_missing',
         'Не выбрана формула фактического количества: без неё нельзя '
         'посчитать факт, а от него зависят отгрузка и списания со склада.'
    from product_type_configs c
   where c.id = p_config_id
     and c.actual_qty_formula is null

  union all
  select 'group_mixes_levels',
         format('Позицию %s делят общий этап и под-этап варианта — они не '
                'взаимоисключающие.', g.position)
    from (
      select s.position, count(distinct s.level) as levels
        from product_type_stages s
       where s.config_id = p_config_id and not s.is_pinned_last
       group by s.position
    ) g
   where g.levels > 1

  union all
  select 'group_across_switches',
         format('Позицию %s делят под-этапы разных переключателей.', g.position)
    from (
      select s.position, count(distinct w.stage_id) as switches
        from product_type_stages s
        join product_type_stage_workplaces w on w.id = s.parent_variant_id
       where s.config_id = p_config_id and s.level = 1
       group by s.position
    ) g
   where g.switches > 1

  union all
  select 'group_same_variant',
         format('Позицию %s делят под-этапы одного варианта — они появятся '
                'вместе.', g.position)
    from (
      select s.position,
             count(*) as total,
             count(distinct s.parent_variant_id) as variants
        from product_type_stages s
       where s.config_id = p_config_id and s.level = 1
       group by s.position
    ) g
   where g.variants <> g.total

  union all
  select 'sub_stage_before_switch',
         format('Под-этап «%s» на позиции %s стоит не позже переключателя '
                '«%s» (позиция %s).', s.title, s.position, p.title, p.position)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages p on p.id = w.stage_id
   where s.config_id = p_config_id
     and s.level = 1
     and s.position <= p.position

  -- ── Режимы очерёдности ─────────────────────────────────────────────────

  union all
  select 'parallel_without_partner',
         format('Этап «%s» настроен параллельно с другим этапом, но партнёр '
                'не выбран.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.execution_mode = 'parallel_with'
     and s.parallel_with_stage_id is null

  union all
  select 'partner_without_parallel',
         format('У этапа «%s» выбран партнёр, но режим не «параллельно с '
                'этапом».', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.parallel_with_stage_id is not null
     and s.execution_mode <> 'parallel_with'

  union all
  select 'parallel_partner_foreign_config',
         format('Этап «%s»: партнёр принадлежит другому типу продукта.', s.title)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.config_id <> s.config_id

  union all
  -- Партнёр позже по рангу всегда выразим простым перемещением этапа, а
  -- превью при этом врёт: этап показан на своей позиции, а стартует на
  -- уровне партнёра.
  select 'parallel_partner_after_stage',
         format('Этап «%s» (позиция %s) не может идти параллельно с «%s» '
                '(позиция %s): партнёр должен стоять раньше.',
                s.title, s.position, p.title, p.position)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.position >= s.position

  union all
  -- Партнёр — под-этап чужого варианта: при выборе другого варианта партнёр
  -- в очередь не попадёт, и зависимый этап не стартует никогда.
  select 'parallel_partner_unreachable',
         format('Этап «%s»: партнёр «%s» принадлежит другому варианту и при '
                'его невыборе не появится в очереди.', s.title, p.title)
    from product_type_stages s
    join product_type_stages p on p.id = s.parallel_with_stage_id
   where s.config_id = p_config_id
     and p.level = 1
     and (s.level <> 1 or s.parent_variant_id is distinct from p.parent_variant_id)

  union all
  -- Взаимная параллельность: ни один из этапов не стартует, потому что каждый
  -- ждёт старта другого.
  select 'parallel_partner_cycle',
         format('Этап «%s» участвует в замкнутой цепочке параллельных этапов: '
                'ни один из них не сможет начаться.', s.title)
    from (select distinct start_id from parallel_walk where node = start_id) c
    join product_type_stages s on s.id = c.start_id;
$function$;

comment on function public.validate_product_type_config(uuid) is
  'Возвращает список структурных проблем версии настроек: пустой результат = '
  'версию можно публиковать. Проверяет инварианты, не выразимые через CHECK, '
  'в том числе однородность групп одного ранга, порядок под-этапов и '
  'корректность режимов очерёдности, включая замкнутые цепочки партнёров.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Права — точный паттерн соседних справочников
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Такой же, как у order_predicates и order_form_blocks: грант трём ролям,
-- политика чтения только authenticated. Грант anon при этом мёртвый — anon
-- получит пустой результат, а не ошибку, — и стоит здесь ради единообразия.
-- service_role, наоборот, нужен: он обходит RLS, но грант на таблицу ему
-- по-прежнему требуется, и под ним ходит scripts/refresh_product_type_routes.
-- Чистка anon по всем конфигурационным таблицам — отдельная задача в бэклоге.

grant select on public.actual_qty_formulas
  to anon, authenticated, service_role;

alter table public.actual_qty_formulas enable row level security;

create policy actual_qty_formulas_select on public.actual_qty_formulas
  for select to authenticated using (true);
