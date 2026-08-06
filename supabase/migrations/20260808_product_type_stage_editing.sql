-- Редактирование маршрута типа продукта: перестановка этапов, копирование
-- под-этапов между вариантами и четыре новые структурные проверки.
--
-- ОБЩАЯ ПРИЧИНА ДЛЯ ФУНКЦИЙ
-- Редактор пишет каждый жест в черновик сразу — это безопасно, потому что
-- черновик никем не читается, пока не опубликован. Но два жеста состоят
-- больше чем из одного оператора, и обрыв на середине оставляет черновик в
-- состоянии, которого техлид не заказывал. Тот же класс дефекта, что уже
-- чинили в replace_plan_stages, publish_product_type_config и
-- create_product_type_config_draft.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Перестановка этапов
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ЕДИНИЦА ПЕРЕСТАНОВКИ — ГРУППА РАНГА, А НЕ ЭТАП
-- position — это ранг, а не индекс в списке, и совпадение рангов осмысленно:
-- этапы на одном ранге взаимоисключающие, в очередь попадает не более одного
-- (три этапа ручек делят позицию 9 по handle_type_is). Ранг сквозной по обоим
-- уровням: у П-образного пакета под-этапы вариантов стоят на 6-8, а общий
-- этап ручки — на 9, ПОСЛЕ них.
--
-- Первая версия этой функции раздавала подвижным этапам уровня 0 позиции
-- 1..N подряд. На П-образном пакете это уводило ручки на 6,7,8 — в
-- столкновение с под-этапами — и разводило три ручки по разным рангам, то
-- есть молча меняло маршрут. Отсюда контракт: приходит упорядоченный список
-- ГРУПП по обоим уровням, сервер раздаёт группам ранги 1..N.
--
-- ЧТО ФУНКЦИЯ ПРОВЕРЯЕТ, А НЕ ДОВЕРЯЕТ КЛИЕНТУ
--   * состав списка совпадает с составом версии, без дублей;
--   * группа однородна по уровню. Иначе общий этап и под-этап варианта
--     оказались бы на одном ранге: общий появляется всегда, под-этап иногда,
--     и порядок между ними решала бы сортировка по ключу;
--   * группа уровня 1 — это разные варианты ОДНОГО переключателя. Два
--     под-этапа одного варианта не взаимоисключающие, они появятся вместе;
--   * ранг под-этапа строго больше ранга его переключателя. Проверка одна на
--     оба направления: и «поднять под-этап выше переключателя», и «опустить
--     переключатель ниже своих под-этапов» нарушают её одинаково.
--
-- ПОЧЕМУ МАССИВЫ, А НЕ ВРЕМЕННАЯ ТАБЛИЦА
-- Функция вызывается на каждый клик по стрелке. Временная таблица на каждый
-- вызов — это запись в системный каталог и сброс планов; разобрать список
-- шесть раз подряд в CTE — шесть копий одного разбора, которые разойдутся при
-- первой же правке формата. Разбираем один раз в два выровненных массива и
-- дальше читаем их через unnest: каждая проверка остаётся рядом со своим
-- сообщением, а имя переменной plpgsql не зависит от search_path — в отличие
-- от неквалифицированной временной таблицы, которую при search_path
-- 'public','pg_temp' перехватила бы одноимённая таблица в public.
--
-- ЧТО ФУНКЦИЯ НЕ ТРОГАЕТ
-- Закреплённую упаковку: она в список не входит и позицию сохраняет.

-- Первая версия так и не была применена; drop нужен только потому, что
-- create or replace не умеет менять имя входного параметра.
drop function if exists public.set_product_type_stage_positions(uuid, jsonb);

create or replace function public.set_product_type_stage_positions(
  p_config_id      uuid,
  p_ordered_groups jsonb
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_ids      uuid[];
  v_ranks    integer[];
  v_listed   integer;
  v_expected integer;
  v_updated  integer := 0;
  v_sub      text;
  v_switch   text;
begin
  if p_config_id is null then
    raise exception
      'Не удалось сохранить порядок этапов: не указана версия настроек.'
      using errcode = '22023';
  end if;

  if p_ordered_groups is null or jsonb_typeof(p_ordered_groups) <> 'array' then
    raise exception
      'Не удалось сохранить порядок этапов: список этапов повреждён.'
      using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_ordered_groups) as g(items)
     where jsonb_typeof(g.items) <> 'array' or jsonb_array_length(g.items) = 0
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: список групп повреждён.'
      using errcode = '22023';
  end if;

  -- Фиксируем строки версии до COMMIT: параллельная правка не переставит
  -- этапы между нашим чтением и записью.
  perform 1 from product_type_stages
   where config_id = p_config_id
   for update;

  -- Разбор один раз. Одинаковый ORDER BY в обоих array_agg держит массивы
  -- выровненными: v_ids[i] лежит на ранге v_ranks[i].
  begin
    select array_agg((m.value #>> '{}')::uuid order by g.ord, m.ord),
           array_agg(g.ord::integer order by g.ord, m.ord)
      into v_ids, v_ranks
      from jsonb_array_elements(p_ordered_groups)
             with ordinality as g(items, ord)
      cross join lateral jsonb_array_elements(g.items)
             with ordinality as m(value, ord);
  exception when invalid_text_representation then
    raise exception
      'Не удалось сохранить порядок этапов: в списке не идентификатор этапа.'
      using errcode = '22023';
  end;

  if exists (
    select 1 from unnest(v_ids) as t(id) group by t.id having count(*) > 1
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: этап указан в списке дважды.'
      using errcode = '22023';
  end if;

  -- Список обязан совпадать с составом версии: иначе экран показывал
  -- устаревший маршрут, и перенумерация испортила бы порядок вслепую.
  v_listed := coalesce(array_length(v_ids, 1), 0);
  select count(*) into v_expected
    from product_type_stages
   where config_id = p_config_id
     and not is_pinned_last;

  if v_listed <> v_expected or exists (
    select 1
      from unnest(v_ids) as t(id)
      left join product_type_stages s
        on s.id = t.id
       and s.config_id = p_config_id
       and not s.is_pinned_last
     where s.id is null
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: список не совпадает с маршрутом. '
      'Обновите экран и повторите.'
      using errcode = '22023';
  end if;

  -- Группа однородна по уровню.
  if exists (
    select 1
      from unnest(v_ids, v_ranks) as r(stage_id, rank)
      join product_type_stages s on s.id = r.stage_id
     group by r.rank
    having count(distinct s.level) > 1
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: на одном шаге оказались общий '
      'этап и под-этап варианта. Они не взаимоисключающие, порядок между '
      'ними не определён.'
      using errcode = '22023';
  end if;

  -- Группа уровня 1 — разные варианты ОДНОГО переключателя.
  if exists (
    select 1
      from unnest(v_ids, v_ranks) as r(stage_id, rank)
      join product_type_stages s on s.id = r.stage_id and s.level = 1
      join product_type_stage_workplaces w on w.id = s.parent_variant_id
     group by r.rank
    having count(distinct w.stage_id) > 1
        or count(distinct w.id) <> count(*)
  ) then
    raise exception
      'Не удалось сохранить порядок этапов: на одном шаге оказались под-этапы '
      'одного варианта или разных переключателей — вместе они появятся оба.'
      using errcode = '22023';
  end if;

  -- Под-этап строго позже своего переключателя. Одна проверка закрывает и
  -- подъём под-этапа, и опускание переключателя.
  select s.title, p.title
    into v_sub, v_switch
    from unnest(v_ids, v_ranks) as r(stage_id, rank)
    join product_type_stages s on s.id = r.stage_id and s.level = 1
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages p on p.id = w.stage_id
    left join unnest(v_ids, v_ranks) as pr(stage_id, rank)
           on pr.stage_id = p.id
   where pr.stage_id is null or r.rank <= pr.rank
   limit 1;

  if v_sub is not null then
    raise exception
      'Не удалось сохранить порядок этапов: под-этап «%» должен идти после '
      'переключателя «%», иначе вариант ещё не выбран.', v_sub, v_switch
      using errcode = '22023';
  end if;

  update product_type_stages s
     set position = r.rank
    from unnest(v_ids, v_ranks) as r(stage_id, rank)
   where s.id = r.stage_id
     and s.position is distinct from r.rank;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;

comment on function public.set_product_type_stage_positions(uuid, jsonb) is
  'Раздаёт ранги 1..N группам этапов версии в порядке переданного списка. '
  'Группа — этапы одного ранга, взаимоисключающие по построению. Проверяет '
  'однородность группы по уровню, принадлежность под-этапов группы разным '
  'вариантам одного переключателя и то, что под-этап идёт строго после своего '
  'переключателя. Закреплённую упаковку не трогает.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Копирование под-этапов между вариантами
-- ═══════════════════════════════════════════════════════════════════════════
--
-- При добавлении варианта редактор предлагает перенести под-этапы соседнего:
-- у П-образного пакета «Вставка картона» повторяется под обоими автоматами,
-- и заводить её заново руками — приглашение к расхождению.
--
-- Копия — это граф: под-этап, его рабочие места, его условия. Клиентом это
-- N+1 запросов, и при обрыве техлид не узнает, что половина под-этапов уже
-- скопирована, а половина нет.

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
  v_from_stage  uuid;
  v_to_stage    uuid;
  v_from_config uuid;
  v_to_config   uuid;
  v_stage       record;
  v_new_stage   uuid;
  v_copied      integer := 0;
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
      position, selection_mode, is_enabled, is_pinned_last)
    values (
      v_stage.config_id, p_to_variant_id, 1, v_stage.stage_group_key,
      v_stage.title, v_stage.position, v_stage.selection_mode,
      v_stage.is_enabled, v_stage.is_pinned_last)
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

    v_copied := v_copied + 1;
  end loop;

  return v_copied;
end;
$function$;

comment on function public.copy_variant_sub_stages(uuid, uuid) is
  'Переносит под-этапы одного варианта переключаемого этапа на другой вариант '
  'ТОГО ЖЕ этапа вместе с их рабочими местами и условиями, одной транзакцией. '
  'Под-этапы с уже занятым ключом пропускает. Возвращает число скопированных.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Четыре новые структурные проверки
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Те же инварианты, что проверяет перестановка, но по уже лежащим позициям —
-- на случай, если строки заведены не редактором. Остальные проверки
-- перенесены без изменений из 20260807_product_type_stages.sql.

create or replace function public.validate_product_type_config(
  p_config_id uuid
)
returns table (code text, message text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  select 'one_of_without_default',
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
  -- Пустой маршрут публиковать нельзя. Это же и предохранитель от черновика,
  -- созданного ради правки блоков формы.
  select 'route_empty',
         'Маршрут пуст: не задано ни одного этапа.'
    from (select 1) _
   where not exists (select 1 from product_type_stages s
                      where s.config_id = p_config_id)

  union all
  select 'packaging_missing',
         'В маршруте нет ровно одного завершающего этапа упаковки.'
    from (select 1) _
   where exists (select 1 from product_type_stages s where s.config_id = p_config_id)
     and (select count(*) from product_type_stages s
           where s.config_id = p_config_id and s.is_pinned_last) <> 1

  union all
  select 'packaging_not_top_level',
         format('Завершающий этап «%s» не может быть под-этапом варианта.', s.title)
    from product_type_stages s
   where s.config_id = p_config_id
     and s.is_pinned_last
     and s.level <> 0

  union all
  -- Общий этап и под-этап варианта на одном ранге: общий появляется всегда,
  -- под-этап иногда, порядок между ними решала бы сортировка по ключу.
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
  -- Под-этапы разных переключателей на одном ранге могут появиться вместе.
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
  -- Под-этапы ОДНОГО варианта на одном ранге появятся вместе всегда.
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
  -- Под-этап раньше своего переключателя: вариант ещё не выбран.
  select 'sub_stage_before_switch',
         format('Под-этап «%s» на позиции %s стоит не позже переключателя '
                '«%s» (позиция %s).', s.title, s.position, p.title, p.position)
    from product_type_stages s
    join product_type_stage_workplaces w on w.id = s.parent_variant_id
    join product_type_stages p on p.id = w.stage_id
   where s.config_id = p_config_id
     and s.level = 1
     and s.position <= p.position;
$function$;

comment on function public.validate_product_type_config(uuid) is
  'Возвращает список структурных проблем версии настроек: пустой результат = '
  'версию можно публиковать. Проверяет инварианты, которые не выражаются '
  'через CHECK, потому что сквозные по таблицам, в том числе однородность '
  'групп одного ранга и то, что под-этап идёт строго после своего '
  'переключателя.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Права
-- ═══════════════════════════════════════════════════════════════════════════

revoke execute on function
  public.set_product_type_stage_positions(uuid, jsonb) from public;
grant execute on function
  public.set_product_type_stage_positions(uuid, jsonb) to authenticated;

revoke execute on function
  public.copy_variant_sub_stages(uuid, uuid) from public;
grant execute on function
  public.copy_variant_sub_stages(uuid, uuid) to authenticated;

revoke execute on function public.validate_product_type_config(uuid) from public;
grant  execute on function public.validate_product_type_config(uuid) to authenticated;
