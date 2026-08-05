-- Настройки типа продукта, срез 1: видимость блоков формы заказа.
--
-- ЗАЧЕМ
-- Зависимость формы заказа от типа продукта сегодня существует ровно одна и
-- зашита в код: supportsCardboardForProductType() = «не Листы и не В-образные»
-- (lib/modules/orders/stage_queue_builder.dart:786, три использования в
-- edit_order_screen.dart). Остальные блоки показываются всегда, хотя у части
-- типов продукта не бывает ни красок, ни форм. Миграция переносит правило из
-- кода в данные и открывает техлиду редактор.
--
-- ЧТО ЗДЕСЬ НЕ ДЕЛАЕТСЯ
-- Таблиц этапов, предикатов и условий нет — построение очереди срез не
-- трогает, он выпускается отдельно именно поэтому. Колонка
-- order_form_blocks.affects_input и флаг is_required заведены авансом и до
-- следующей фазы не читаются: ALTER по живой таблице настроек дороже.
--
-- ТРАНЗАКЦИЯ
-- Явных begin/commit здесь нет намеренно: границей транзакции владеет
-- применяющий миграцию runner. Вложенное управление транзакцией внутри SQL
-- могло бы преждевременно закрыть внешнюю транзакцию. Критический участок
-- disable → update → restore выполнен одним DO-блоком с EXCEPTION: PostgreSQL
-- откатывает весь блок до внутренней точки сохранения, а обработчик только
-- повторно выбрасывает ошибку. Поэтому исходный tgenabled восстанавливается
-- откатом даже у runner, который не атомарен на уровне всего файла.
--
-- ПОЧЕМУ ВЕРСИИ (product_type_configs), а не плоские настройки
-- Заказы живут неделями, прод единственный. Правка без версий разъехалась бы
-- по всем открытым заказам раньше, чем её заметят. Плюс редактирование
-- многошаговое: техлид правит десяток этапов, и заказ, созданный в середине
-- правки, не должен получить полуготовый набор. Отсюда draft → published и
-- иммутабельность опубликованной версии.
--
-- ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: RLS НЕ РАЗГРАНИЧИВАЕТ ДОСТУП
-- Политики новых таблиц открыты для authenticated, как у orders и
-- warehouse_categories. Это не небрежность, а текущее состояние системы:
-- 50 сотрудников работают через 2 записи auth.users, идентичность живёт в
-- AuthHelper.currentUserId (строка 'tech_leader' в памяти клиента) и до
-- Postgres не доходит, а таблица user_roles пуста — все политики, которые её
-- опрашивают, ложны для всех. Ужесточать политики здесь бессмысленно, пока
-- идентичность не доедет до базы. Разграничение остаётся в UI.

-- Эта основная фаза запускается только после additive M0 и после доказанного
-- вывода несовместимых клиентов. Capability обязана существовать ровно в
-- одном экземпляре и оставаться выключенной до последнего statement файла.
do $require_disabled_capability$
declare
  v_count integer;
  v_enabled boolean;
begin
  select count(*), bool_or(c.enabled)
    into v_count, v_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1';

  if v_count <> 1 then
    raise exception
      'M1 требует ровно одну capability product_type_form_blocks_v1; найдено %.',
      v_count
      using errcode = '55000';
  end if;

  if v_enabled then
    raise exception
      'M1 требует выключенную capability product_type_form_blocks_v1.'
      using errcode = '55000';
  end if;
end;
$require_disabled_capability$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Нормализация типа продукта
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ЖИВОЙ ДЕФЕКТ, КОТОРЫЙ ЭТО ЗАКРЫВАЕТ
-- orders.product->>'type' хранит ЗАГОЛОВОК категории строкой, а заголовок
-- редактируется техлидом из хаба категорий (categories_hub_screen.dart:126).
-- Автосборщик распознаёт тип нормализацией заголовка с восемью алиасами
-- (stage_queue_builder.dart:789-821). Переименование категории поэтому молча
-- ломает распознавание: заказ проваливается в фолбэк и получает очередь из
-- базовых этапов плюс Упаковка, без единой ошибки в логах. Настройкам типа
-- продукта тем более не на что опереться — привязываться к редактируемой
-- строке нельзя.
--
-- product jsonb сохраняем для обратной совместимости; временные триггеры ниже
-- синхронизируют только его ключ type с новым FK.
--
-- Перед expression-index выдаём диагностические списки. CHECK не допускает
-- NULL/пустой title в будущем, unique index не допускает нормализованный дубль.
-- Будущий UI должен отдельно переводить 23505 от этого индекса в сообщение
-- «Категория с таким названием уже существует».
do $normalize_categories$
declare
  v_blank_ids  text;
  v_duplicates text;
begin
  lock table public.warehouse_categories in share row exclusive mode;

  select string_agg(c.id::text, ', ' order by c.id::text)
    into v_blank_ids
    from public.warehouse_categories c
   where nullif(btrim(c.title), '') is null;

  if v_blank_ids is not null then
    raise exception
      'warehouse_categories: title пуст или NULL у категорий [%]. '
      'Исправьте данные до миграции.', v_blank_ids
      using errcode = '23514';
  end if;

  select string_agg(
           format('%s => [%s]', d.normalized_title, d.rows_list),
           '; ' order by d.normalized_title
         )
    into v_duplicates
    from (
      select lower(btrim(c.title)) as normalized_title,
             string_agg(
               format('%s:%s', c.id, c.title),
               ', ' order by c.id::text
             ) as rows_list
        from public.warehouse_categories c
       group by lower(btrim(c.title))
      having count(*) > 1
    ) d;

  if v_duplicates is not null then
    raise exception
      'warehouse_categories: нормализованные дубли title: %. '
      'Объедините или переименуйте категории до миграции.', v_duplicates
      using errcode = '23514';
  end if;

  alter table public.warehouse_categories
    add constraint warehouse_categories_title_not_blank_check
    check (nullif(btrim(title), '') is not null);

  create unique index warehouse_categories_title_normalized_uq
    on public.warehouse_categories (lower(btrim(title)));
end;
$normalize_categories$;

-- archived_at уже добавлен additive-фазой M0. До M1 приложение держит
-- capability выключенной и продолжает legacy-путь; M1 не повторяет DDL M0.

alter table public.orders
  add column product_type_id uuid;

comment on column public.orders.product_type_id is
  'Тип продукта заказа, ссылка на warehouse_categories. Заменяет сверку по '
  'заголовку из product->>''type'', которая ломалась при переименовании '
  'категории. product jsonb сохранён для обратной совместимости и остаётся '
  'источником остальных полей продукта. NULL допустим для любого количества '
  'заказов, у которых legacy-тип пуст или отсутствует.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Бэкофилл product_type_id
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Диагностический снимок на 2026-08-05: 95 заказов, 92 с непустым типом и 3
-- без него. Это НЕ инвариант и ни в одном RAISE не используется.
--
-- trg_orders_updated_at ставит updated_at := now() безусловно. Временное
-- отключение предотвращает только перезапись updated_at и изменение сортировки.
-- Оно НЕ предотвращает realtime UPDATE-события от самого бэкофилла.
-- trg_orders_sync_prod_plan_upd навешен на UPDATE OF prod_template_id, product
-- и на UPDATE только product_type_id не срабатывает — планы не тронутся.
-- Это правильно: _infer_template_id_from_order() тип продукта не читает, а
-- лишний вызов copy_template_to_plan() удалил бы и пересоздал этапы плана.
--
-- Блок берёт блокировки до проверок: новые заказы и переименования категорий не
-- могут вклиниться между проверкой соответствий и update. Состояние tgenabled
-- читается из pg_trigger и после успеха восстанавливается точно (O/R/A/D).
do $backfill_product_type$
declare
  v_trigger_state "char";
  v_zero_matches  text;
  v_many_matches  text;
  v_bad_after     text;
begin
  lock table public.warehouse_categories in share mode;
  lock table public.orders in share row exclusive mode;

  select t.tgenabled
    into v_trigger_state
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class r on r.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
   where n.nspname = 'public'
     and r.relname = 'orders'
     and t.tgname = 'trg_orders_updated_at'
     and not t.tgisinternal;

  if not found then
    raise exception
      'Бэкофилл product_type_id: триггер public.orders.trg_orders_updated_at не найден.'
      using errcode = '55000';
  end if;

  -- 1. Для каждого непустого legacy-типа должна существовать категория.
  select string_agg(
           format('%s:%s', o.id, o.product->>'type'),
           ', ' order by o.id::text
         )
    into v_zero_matches
    from public.orders o
   where nullif(btrim(o.product->>'type'), '') is not null
     and not exists (
       select 1
         from public.warehouse_categories c
        where lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
     );

  if v_zero_matches is not null then
    raise exception
      'Бэкофилл product_type_id: нет категории для заказов [order_id:type] = [%].',
      v_zero_matches
      using errcode = '23514';
  end if;

  -- 2. Проверка оставлена явно, хотя unique index уже делает случай невозможным.
  select string_agg(
           format('%s:%s (%s совпадений)', x.order_id, x.legacy_title, x.matches),
           ', ' order by x.order_id::text
         )
    into v_many_matches
    from (
      select o.id as order_id,
             o.product->>'type' as legacy_title,
             count(c.id) as matches
        from public.orders o
        join public.warehouse_categories c
          on lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
       where nullif(btrim(o.product->>'type'), '') is not null
       group by o.id, o.product->>'type'
      having count(c.id) > 1
    ) x;

  if v_many_matches is not null then
    raise exception
      'Бэкофилл product_type_id: неоднозначные соответствия [%].',
      v_many_matches
      using errcode = '23514';
  end if;

  if v_trigger_state <> 'D' then
    execute 'alter table public.orders disable trigger trg_orders_updated_at';
  end if;

  update public.orders o
     set product_type_id = c.id
    from public.warehouse_categories c
   where nullif(btrim(o.product->>'type'), '') is not null
     and lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
     and o.product_type_id is null;

  -- 3–4. После бэкофилла каждый непустой тип имеет ненулевой FK ровно на ту
  -- категорию, с которой совпадает нормализованный заголовок.
  select string_agg(
           format('%s:%s=>%s', o.id, o.product->>'type',
                  coalesce(o.product_type_id::text, 'NULL')),
           ', ' order by o.id::text
         )
    into v_bad_after
    from public.orders o
   where nullif(btrim(o.product->>'type'), '') is not null
     and (
       o.product_type_id is null
       or not exists (
         select 1
           from public.warehouse_categories c
          where c.id = o.product_type_id
            and lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
       )
     );

  if v_bad_after is not null then
    raise exception
      'Бэкофилл product_type_id: итоговое несоответствие '
      '[order_id:type=>product_type_id] = [%].', v_bad_after
      using errcode = '23514';
  end if;

  -- 5. Пустой/отсутствующий legacy-тип намеренно не проверяется: таких NULL FK
  -- может быть любое количество.
  case v_trigger_state
    when 'O' then
      execute 'alter table public.orders enable trigger trg_orders_updated_at';
    when 'R' then
      execute 'alter table public.orders enable replica trigger trg_orders_updated_at';
    when 'A' then
      execute 'alter table public.orders enable always trigger trg_orders_updated_at';
    when 'D' then
      null;
    else
      raise exception
        'Бэкофилл product_type_id: неизвестное tgenabled=% для trg_orders_updated_at.',
        v_trigger_state
        using errcode = '55000';
  end case;
exception
  when others then
    -- Никакого unconditional ENABLE здесь нет. Изменения всего DO-блока,
    -- включая DISABLE и UPDATE, откатываются к внутренней точке сохранения;
    -- затем исходная ошибка уходит runner-у.
    raise;
end;
$backfill_product_type$;

-- Внешний ключ ставится ПОСЛЕ бэкофилла, чтобы проверка прошла один раз по
-- уже заполненным данным.
--
-- ON DELETE RESTRICT согласован с архивной семантикой категории: история
-- заказов и конфигураций не осиротеет. Текущий hard-delete UI до своей фазы
-- будет получать настоящий 23503; в этой миграции UI не меняется.
alter table public.orders
  add constraint orders_product_type_id_fkey
  foreign key (product_type_id)
  references public.warehouse_categories(id)
  on delete restrict;

create index orders_product_type_id_idx
  on public.orders (product_type_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Временный триггер синхронизации
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Закрывает окно между применением миграции и релизом Dart-кода.
--
-- PostgreSQL запускает UPDATE OF-триггер по наличию колонки в SET, даже если
-- значение осталось прежним. Триггер 00 кладёт transaction-local GUC-маркер
-- txid:OLD.id; триггер 10 читает и сразу очищает его. AFTER STATEMENT-триггер
-- 99 — страховка на случай, если другой BEFORE ROW-триггер вернёт NULL.
--
-- Точные имена и порядок BEFORE UPDATE на orders после миграции:
--   trg_orders_00_mark_explicit_product_type_id  (UPDATE OF product_type_id)
--   trg_orders_10_sync_product_type              (UPDATE OF product, product_type_id)
--   trg_orders_sync_form_fields                  (UPDATE OF form_id)
--   trg_orders_sync_form_no                      (UPDATE OF form_id)
--   trg_orders_updated_at                        (UPDATE)
-- Триггеры одного timing/event исполняются по имени. plan-sync — AFTER ROW и в
-- этот список не входит. GUC называется ровно
-- easy_pack.orders_explicit_product_type_id, ставится local=true, очищается
-- после каждой строки и после statement, а в конце транзакции исчезает сам.
-- Это маркер намерения, НЕ граница авторизации: клиент теоретически может
-- выставить custom GUC самостоятельно.
--
-- УДАЛИТЬ вместе с алиасным распознаванием типа в stage_queue_builder.dart —
-- это единственные два места, где заголовок ещё работает ключом.

create or replace function public.tg_orders_00_mark_explicit_product_type_id()
returns trigger
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform set_config(
    'easy_pack.orders_explicit_product_type_id',
    format('%s:%s', txid_current(), old.id),
    true
  );
  return new;
end;
$function$;

create trigger trg_orders_00_mark_explicit_product_type_id
  before update of product_type_id on public.orders
  for each row
  execute function public.tg_orders_00_mark_explicit_product_type_id();

create or replace function public.tg_orders_10_sync_product_type()
returns trigger
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_title             text;
  v_id                uuid;
  v_canonical_title   text;
  v_archived_at       timestamptz;
  v_title_changed     boolean := false;
  v_explicit_id       boolean := false;
  v_expected_marker   text;
begin
  v_title := nullif(btrim(coalesce(new.product->>'type', '')), '');

  if tg_op = 'INSERT' then
    -- У INSERT нет SET-list: непустой ID означает новый клиент, NULL означает
    -- legacy-контракт. Явно переданный NULL на INSERT отдельно не различим.
    v_explicit_id := new.product_type_id is not null;
  else
    v_expected_marker := format('%s:%s', txid_current(), old.id);
    v_explicit_id := coalesce(
      current_setting('easy_pack.orders_explicit_product_type_id', true)
        = v_expected_marker,
      false
    );
    -- Удаляем маркер до любой дальнейшей проверки/ошибки.
    perform set_config('easy_pack.orders_explicit_product_type_id', '', true);
    v_title_changed :=
      new.product->>'type' is distinct from old.product->>'type';
  end if;

  if v_explicit_id then
    -- Новый клиент: ID имеет приоритет и никогда не переоткрывается по title.
    if new.product_type_id is null then
      new.product := coalesce(new.product, '{}'::jsonb) - 'type';
      return new;
    end if;

    select c.title, c.archived_at
      into v_canonical_title, v_archived_at
      from public.warehouse_categories c
     where c.id = new.product_type_id;

    if not found then
      raise exception
        'Не удалось сохранить заказ: категория с ID % отсутствует.',
        new.product_type_id
        using errcode = '23503';
    end if;

    -- Существующий заказ с уже архивированным типом можно пересохранить с тем
    -- же ID, но выбрать архивную категорию для нового заказа/нового типа нельзя.
    if v_archived_at is not null then
      if tg_op = 'INSERT' then
        raise exception
          'Не удалось сохранить заказ: категория с ID % архивирована.',
          new.product_type_id
          using errcode = '23514';
      elsif new.product_type_id is distinct from old.product_type_id then
        raise exception
          'Не удалось сохранить заказ: категория с ID % архивирована.',
          new.product_type_id
          using errcode = '23514';
      end if;
    end if;

    if v_title is not null
       and lower(btrim(v_title)) <> lower(btrim(v_canonical_title)) then
      raise exception
        'Не удалось сохранить заказ: заголовок типа «%» и product_type_id % '
        'указывают на разные категории (для ID ожидается «%»).',
        v_title, new.product_type_id, v_canonical_title
        using errcode = '23514';
    end if;

    new.product := jsonb_set(
      coalesce(new.product, '{}'::jsonb),
      '{type}',
      to_jsonb(v_canonical_title),
      true
    );
    return new;
  end if;

  if tg_op = 'INSERT'
     or v_title_changed
     or new.product_type_id is null then
    -- Старый клиент: ID переоткрывается только из legacy-заголовка.
    if v_title is null then
      new.product_type_id := null;
      new.product := coalesce(new.product, '{}'::jsonb) - 'type';
      return new;
    end if;

    select c.id, c.title
      into v_id, v_canonical_title
      from public.warehouse_categories c
     where lower(btrim(c.title)) = lower(v_title)
       and c.archived_at is null;

    if not found then
      raise exception
        'Не удалось сохранить заказ: тип продукта «%» отсутствует в '
        'справочнике категорий. Обновите список типов и выберите тип заново.',
        v_title
        using errcode = '23514';
    end if;

    new.product_type_id := v_id;
    new.product := jsonb_set(
      coalesce(new.product, '{}'::jsonb),
      '{type}',
      to_jsonb(v_canonical_title),
      true
    );
  end if;

  return new;
end;
$function$;

comment on function public.tg_orders_10_sync_product_type() is
  'ВРЕМЕННЫЙ. Синхронизирует orders.product_type_id и product->>''type'' '
  'между старым и новым клиентами. Наличие product_type_id в UPDATE SET '
  'определяется предшествующим marker-trigger, а не сравнением NEW и OLD. '
  'Удалить после окончания переходного периода.';

create trigger trg_orders_10_sync_product_type
  before insert or update of product, product_type_id on public.orders
  for each row
  execute function public.tg_orders_10_sync_product_type();

create or replace function public.tg_orders_99_clear_product_type_marker()
returns trigger
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform set_config('easy_pack.orders_explicit_product_type_id', '', true);
  return null;
end;
$function$;

create trigger trg_orders_99_clear_product_type_marker
  after update of product_type_id on public.orders
  for each statement
  execute function public.tg_orders_99_clear_product_type_marker();

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Версии настроек типа продукта
-- ═══════════════════════════════════════════════════════════════════════════

create table public.product_type_configs (
  id              uuid primary key default gen_random_uuid(),
  product_type_id uuid not null
                    references public.warehouse_categories(id) on delete restrict,
  version         integer not null,
  status          text not null default 'draft'
                    check (status in ('draft','published','archived')),
  note            text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  published_at    timestamptz,
  unique (product_type_id, version)
);

comment on table public.product_type_configs is
  'Версия настроек типа продукта. Опубликованная версия иммутабельна: правка '
  'создаётся как draft и заменяет прежнюю при публикации, прежняя уходит в '
  'archived. Так многошаговое редактирование не долетает до заказов '
  'наполовину применённым.';

comment on column public.product_type_configs.status is
  'draft — редактируется, приложением не читается. published — действующая, '
  'ровно одна на тип продукта. archived — прежняя опубликованная; хранится '
  'ради заказов, привязанных к ней через orders.stage_config_id. Версии '
  'published/archived никогда не удаляются физически; draft можно отменить.';

create unique index product_type_configs_published_uq
  on public.product_type_configs (product_type_id)
  where status = 'published';

create unique index product_type_configs_draft_uq
  on public.product_type_configs (product_type_id)
  where status = 'draft';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Привязка заказа к версии настроек (задел под фазу 3)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- В этом срезе колонка НЕ заполняется и НЕ читается. Заведена сейчас, потому
-- что на ней держится довесок к версионности: маркер «настройки типа продукта
-- обновились» — это сравнение stage_config_id заказа с текущей опубликованной
-- версией, а массовое действие «пересобрать по новой версии» её переписывает.
--
-- ЧТО ОНА ЗАКРЕПЛЯЕТ, А ЧТО НЕТ
-- Пришпиливает ПРАВИЛА ОЧЕРЕДИ. Видимость блоков формы к ней не привязана:
-- редактор заказа читает блоки из текущей опубликованной версии, иначе
-- открытый старый заказ показывал бы блоки по устаревшим правилам. Схема
-- допускает и второе поведение — если в фазе 3 решим, что видимость блоков
-- тоже должна следовать закреплённой версии, меняется только запрос чтения.

alter table public.orders
  add column stage_config_id uuid
    references public.product_type_configs(id) on delete restrict;

comment on column public.orders.stage_config_id is
  'Версия настроек, по которой собрана очередь заказа. Заполняется с фазы 3. '
  'Расхождение с текущей опубликованной версией = маркер «настройки '
  'обновились» в списке заказов.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Справочник блоков формы заказа
-- ═══════════════════════════════════════════════════════════════════════════

create table public.order_form_blocks (
  code          text primary key,
  title         text not null,
  affects_input text,
  sort_order    integer not null default 0
);

comment on table public.order_form_blocks is
  'Перечень блоков формы заказа, видимостью которых техлид управляет. Блоки, '
  'без которых заказ не существует (дата, заказчик, тип, тираж, размеры, '
  'основной материал), сюда намеренно не входят — их скрытие сломало бы '
  'форму, а не настроило её.';

comment on column public.order_form_blocks.affects_input is
  'Связь среза 1 с фазой 3: какой вход автосборщика принудительно обнуляется '
  'при скрытии блока. Скрыли «Краски» → has_paint = false → Флексопечать не '
  'добавляется. Без этого форма и очередь разъехались бы: блока не видно, а '
  'этап в плане есть. В срезе 1 колонка не читается.';

insert into public.order_form_blocks (code, title, affects_input, sort_order) values
  ('cardboard',    'Картон',        'has_cardboard', 10),
  ('trimming',     'Подрезка',      'has_trimming',  20),
  ('handle',       'Ручки',         'handle_type',   30),
  ('paints',       'Краски',        'has_paint',     40),
  ('form',         'Форма',          null,           50),
  ('pdf',          'PDF',            null,           60),
  ('makeready',    'Приладка',       null,           70),
  ('extra_papers', 'Доп. бумаги',    null,           80),
  ('roll',         'Рулон',          null,           90),
  ('bl_quantity',  'Кол-во по БЛ',   null,          100);

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Видимость блоков для версии настроек
-- ═══════════════════════════════════════════════════════════════════════════

create table public.product_type_form_blocks (
  config_id   uuid    not null
                references public.product_type_configs(id) on delete cascade,
  block_code  text    not null references public.order_form_blocks(code),
  is_visible  boolean not null default true,
  is_required boolean not null default false,
  primary key (config_id, block_code)
);

comment on table public.product_type_form_blocks is
  'Настройка блока формы для версии. Отсутствие строки = блок виден и не '
  'обязателен. Таблица заполняется только отклонениями от умолчания, поэтому '
  'появление нового блока в справочнике не требует правки данных.';

comment on column public.product_type_form_blocks.is_required is
  'Задел: обязательность заполнения блока. В срезе 1 не читается — '
  'реализуется вместе с валидацией формы.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Наполнение: по одной опубликованной версии на каждую категорию
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Версия создаётся для всех девяти категорий, включая «Рулонную печать» и
-- «Готовую продукцию»: редактор должен открываться на любой из них. Состав
-- этапов у этих двух не задаётся — маршрут уточняется у производства, а
-- таблиц этапов в этом срезе и нет. Категории, заведённые позже, получают draft
-- при первой правке через create_product_type_config_draft(); простой просмотр
-- настроек ничего не создаёт.

insert into public.product_type_configs
       (product_type_id, version, status, note, published_at)
select c.id, 1, 'published',
       'Создано миграцией: перенос зашитого в код правила по картону.',
       now()
  from public.warehouse_categories c;

-- Единственное правило, которое сейчас живёт в коде:
-- supportsCardboardForProductType() = не Листы и не В-образные. Переносим один
-- в один, чтобы поведение формы после релиза не изменилось ни у одного типа.
insert into public.product_type_form_blocks (config_id, block_code, is_visible)
select cfg.id, 'cardboard', false
  from public.product_type_configs cfg
 where cfg.status = 'published'
   and cfg.product_type_id in (
     'aab3ed17-1688-43f0-b623-58dac264941f',  -- Листы
     '448b731a-eafe-40f1-9268-bc5dd6ba57bc',  -- В-образный окно
     '688ce20b-2db5-43ed-a414-dda08443a06a',  -- В-образный пакет
     'dfd3beb1-1afd-4c06-9b3b-5da680377b0d',  -- В-образный уголок
     'd2323dba-74c9-4e86-adfb-18cd47be9480'   -- В-образный фри
   );

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. Иммутабельность и полный draft → publish workflow
-- ═══════════════════════════════════════════════════════════════════════════
--
-- GUC здесь не подходит как защита: authenticated-клиент может сам выставить
-- произвольный custom GUC. Поэтому контролируемые RPC кладут разрешение в
-- приватную guard-таблицу по (backend PID, txid, config_id); у authenticated
-- нет прав на неё, а SECURITY DEFINER-триггеры читают её. На успехе строка
-- удаляется, на ошибке откатывается вместе с вызовом функции.
create table public.product_type_config_write_guards (
  backend_pid    integer not null,
  transaction_id bigint not null,
  config_id      uuid    not null,
  operation      text    not null
                   check (operation in ('create_draft','discard_draft','publish')),
  primary key (backend_pid, transaction_id, config_id)
);

revoke all on table public.product_type_config_write_guards from public;
revoke all on table public.product_type_config_write_guards from anon;
revoke all on table public.product_type_config_write_guards from authenticated;

comment on table public.product_type_config_write_guards is
  'Внутренний маркер controlled RPC. Клиенту недоступен; успешный RPC удаляет '
  'строку, а неуспешный откатывает её вместе со statement/транзакцией.';

create or replace function public.tg_protect_product_type_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_operation text;
  v_id uuid := case when tg_op = 'DELETE' then old.id else new.id end;
begin
  select g.operation
    into v_operation
    from public.product_type_config_write_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current()
     and g.config_id = v_id;

  if tg_op = 'INSERT' then
    if v_operation = 'create_draft'
       and new.status = 'draft'
       and new.published_at is null then
      return new;
    end if;

    raise exception
      'product_type_configs: новую версию можно создать только как draft через create_product_type_config_draft().'
      using errcode = '55000';
  end if;

  if tg_op = 'DELETE' then
    if v_operation = 'discard_draft' and old.status = 'draft' then
      return old;
    end if;

    raise exception
      'product_type_configs: физическое удаление версии запрещено; удалить можно только draft через discard_product_type_config_draft().'
      using errcode = '55000';
  end if;

  if v_operation = 'publish' then
    if old.id is distinct from new.id
       or old.product_type_id is distinct from new.product_type_id
       or old.version is distinct from new.version
       or old.note is distinct from new.note
       or old.created_by is distinct from new.created_by
       or old.created_at is distinct from new.created_at then
      raise exception
        'product_type_configs: публикация не может менять идентичность или содержимое версии.'
        using errcode = '55000';
    end if;

    if old.status = 'published'
       and new.status = 'archived'
       and old.published_at is not distinct from new.published_at then
      return new;
    end if;

    if old.status = 'draft'
       and new.status = 'published'
       and old.published_at is null
       and new.published_at is not null then
      return new;
    end if;

    raise exception
      'product_type_configs: controlled publish допускает только published→archived и draft→published.'
      using errcode = '55000';
  end if;

  -- Обычное редактирование допускается только для note у draft.
  if old.status = 'draft'
     and new.status = 'draft'
     and old.id is not distinct from new.id
     and old.product_type_id is not distinct from new.product_type_id
     and old.version is not distinct from new.version
     and old.created_by is not distinct from new.created_by
     and old.created_at is not distinct from new.created_at
     and old.published_at is null
     and new.published_at is null then
    return new;
  end if;

  raise exception
    'product_type_configs: published/archived неизменяемы; редактировать можно только draft.'
    using errcode = '55000';
end;
$function$;

create trigger trg_product_type_configs_immutability
  before insert or update or delete on public.product_type_configs
  for each row execute function public.tg_protect_product_type_config();

create or replace function public.tg_protect_product_type_form_block()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_old_status text;
  v_new_status text;
  v_config_id uuid := case when tg_op = 'DELETE' then old.config_id else new.config_id end;
  v_discarding boolean;
begin
  select exists (
    select 1
      from public.product_type_config_write_guards g
     where g.backend_pid = pg_backend_pid()
       and g.transaction_id = txid_current()
       and g.config_id = v_config_id
       and g.operation = 'discard_draft'
  ) into v_discarding;

  if tg_op = 'DELETE' and v_discarding then
    return old;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    select c.status into v_old_status
      from public.product_type_configs c
     where c.id = old.config_id;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select c.status into v_new_status
      from public.product_type_configs c
     where c.id = new.config_id;
  end if;

  if tg_op = 'INSERT' and v_new_status = 'draft' then
    return new;
  elsif tg_op = 'UPDATE'
        and v_old_status = 'draft'
        and v_new_status = 'draft' then
    return new;
  elsif tg_op = 'DELETE' and v_old_status = 'draft' then
    return old;
  end if;

  raise exception
    'product_type_form_blocks: дочерние строки published/archived версии неизменяемы; редактировать можно только draft.'
    using errcode = '55000';
end;
$function$;

create trigger trg_product_type_form_blocks_immutability
  before insert or update or delete on public.product_type_form_blocks
  for each row execute function public.tg_protect_product_type_form_block();

-- Открытие редактора ничего не создаёт: UI читает текущий published и, если
-- есть, draft. При первой правке вызывается эта идемпотентная функция. Она
-- возвращает существующий draft либо создаёт следующую версию и копирует в неё
-- только sparse-overrides дочерних блоков из published.
create or replace function public.create_product_type_config_draft(
  p_product_type_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_draft_id     uuid;
  v_published_id uuid;
  v_version      integer;
begin
  if p_product_type_id is null then
    raise exception 'create_product_type_config_draft: product_type_id обязателен.'
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_product_type_id::text, 0));

  perform 1
    from public.warehouse_categories c
   where c.id = p_product_type_id
     and c.archived_at is null
   for share;

  if not found then
    if exists (
      select 1 from public.warehouse_categories c
       where c.id = p_product_type_id
    ) then
      raise exception
        'create_product_type_config_draft: категория % архивирована.',
        p_product_type_id
        using errcode = '23514';
    end if;

    raise exception
      'create_product_type_config_draft: категория % не существует.',
      p_product_type_id
      using errcode = '23503';
  end if;

  select c.id into v_draft_id
    from public.product_type_configs c
   where c.product_type_id = p_product_type_id
     and c.status = 'draft';

  if found then
    return v_draft_id;
  end if;

  select c.id into v_published_id
    from public.product_type_configs c
   where c.product_type_id = p_product_type_id
     and c.status = 'published';

  select coalesce(max(c.version), 0) + 1
    into v_version
    from public.product_type_configs c
   where c.product_type_id = p_product_type_id;

  v_draft_id := gen_random_uuid();

  insert into public.product_type_config_write_guards
         (backend_pid, transaction_id, config_id, operation)
  values (pg_backend_pid(), txid_current(), v_draft_id, 'create_draft');

  insert into public.product_type_configs
         (id, product_type_id, version, status, note, created_by)
  values (v_draft_id, p_product_type_id, v_version, 'draft', null, auth.uid());

  if v_published_id is not null then
    insert into public.product_type_form_blocks
           (config_id, block_code, is_visible, is_required)
    select v_draft_id, b.block_code, b.is_visible, b.is_required
      from public.product_type_form_blocks b
     where b.config_id = v_published_id;
  end if;

  delete from public.product_type_config_write_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current()
     and g.config_id = v_draft_id;

  return v_draft_id;
end;
$function$;

create or replace function public.discard_product_type_config_draft(
  p_config_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_product_type_id uuid;
  v_status text;
begin
  select c.product_type_id, c.status
    into v_product_type_id, v_status
    from public.product_type_configs c
   where c.id = p_config_id;

  if not found or v_status <> 'draft' then
    raise exception
      'discard_product_type_config_draft: % не является существующим draft.',
      p_config_id
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_product_type_id::text, 0));

  -- Повторно блокируем/проверяем после advisory lock.
  select c.status into v_status
    from public.product_type_configs c
   where c.id = p_config_id
   for update;

  if not found or v_status <> 'draft' then
    raise exception
      'discard_product_type_config_draft: draft % уже изменён.', p_config_id
      using errcode = '23514';
  end if;

  insert into public.product_type_config_write_guards
         (backend_pid, transaction_id, config_id, operation)
  values (pg_backend_pid(), txid_current(), p_config_id, 'discard_draft');

  delete from public.product_type_configs c where c.id = p_config_id;

  delete from public.product_type_config_write_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current()
     and g.config_id = p_config_id;
end;
$function$;

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
  v_published_id    uuid;
begin
  select c.product_type_id, c.status
    into v_product_type_id, v_status
    from public.product_type_configs c
   where c.id = p_config_id;

  if not found or v_status <> 'draft' then
    raise exception
      'publish_product_type_config: % не является существующим draft.',
      p_config_id
      using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_product_type_id::text, 0));

  -- Draft мог быть создан до архивирования категории. Публикация повторно
  -- фиксирует активную строку FOR SHARE: конкурентное архивирование либо
  -- линеаризуется после publish, либо успевает первым и publish отклоняется.
  perform 1
    from public.warehouse_categories c
   where c.id = v_product_type_id
     and c.archived_at is null
   for share;

  if not found then
    raise exception
      'publish_product_type_config: категория % архивирована.',
      v_product_type_id
      using errcode = '23514';
  end if;

  select c.status into v_status
    from public.product_type_configs c
   where c.id = p_config_id
   for update;

  if not found or v_status <> 'draft' then
    raise exception
      'publish_product_type_config: draft % уже изменён.', p_config_id
      using errcode = '23514';
  end if;

  select c.id into v_published_id
    from public.product_type_configs c
   where c.product_type_id = v_product_type_id
     and c.status = 'published'
   for update;

  insert into public.product_type_config_write_guards
         (backend_pid, transaction_id, config_id, operation)
  values (pg_backend_pid(), txid_current(), p_config_id, 'publish');

  if v_published_id is not null then
    insert into public.product_type_config_write_guards
           (backend_pid, transaction_id, config_id, operation)
    values (pg_backend_pid(), txid_current(), v_published_id, 'publish');

    update public.product_type_configs c
       set status = 'archived'
     where c.id = v_published_id;
  end if;

  update public.product_type_configs c
     set status = 'published',
         published_at = clock_timestamp()
   where c.id = p_config_id;

  delete from public.product_type_config_write_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current()
     and g.config_id in (p_config_id, v_published_id);

  return p_config_id;
end;
$function$;

-- Архивирование категории после включения capability выполняется только через
-- одну атомарную RPC. Прямое изменение archived_at запрещает trigger. Как и у
-- config workflow, разрешение хранится не в подделываемом custom GUC, а в
-- недоступной клиентским ролям guard-таблице текущего backend/transaction.
create table public.warehouse_category_archive_guards (
  backend_pid    integer not null,
  transaction_id bigint not null,
  category_id    uuid    not null,
  primary key (backend_pid, transaction_id, category_id)
);

revoke all on table public.warehouse_category_archive_guards
  from public, anon, authenticated;

create or replace function public.tg_protect_warehouse_category_archive()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.archived_at is not distinct from old.archived_at then
    return new;
  end if;

  if exists (
       select 1
         from public.warehouse_category_archive_guards g
        where g.backend_pid = pg_backend_pid()
          and g.transaction_id = txid_current()
          and g.category_id = old.id
     ) then
    return new;
  end if;

  raise exception
    'warehouse_categories.archived_at можно изменить только через archive_warehouse_category().'
    using errcode = '55000';
end;
$function$;

create trigger trg_warehouse_categories_archive_guard
  before update of archived_at on public.warehouse_categories
  for each row
  execute function public.tg_protect_warehouse_category_archive();

create or replace function public.archive_warehouse_category(
  p_category_id uuid,
  p_reason text default null,
  p_deleted_by text default null
)
returns timestamptz
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_category public.warehouse_categories%rowtype;
  v_archived_at timestamptz;
  v_capability_enabled boolean;
begin
  select c.enabled
    into v_capability_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1';

  if not found or v_capability_enabled is distinct from true then
    raise exception
      'archive_warehouse_category: capability product_type_form_blocks_v1 не включена.'
      using errcode = '55000';
  end if;

  if p_category_id is null then
    raise exception 'archive_warehouse_category: category_id обязателен.'
      using errcode = '23514';
  end if;

  select c.*
    into v_category
    from public.warehouse_categories c
   where c.id = p_category_id
   for update;

  if not found then
    raise exception
      'archive_warehouse_category: категория % не существует.', p_category_id
      using errcode = '23503';
  end if;

  -- Повторный запрос идемпотентен и не создаёт дубликат audit-записи.
  if v_category.archived_at is not null then
    return v_category.archived_at;
  end if;

  v_archived_at := clock_timestamp();

  insert into public.warehouse_category_archive_guards
         (backend_pid, transaction_id, category_id)
  values (pg_backend_pid(), txid_current(), p_category_id);

  update public.warehouse_categories c
     set archived_at = v_archived_at
   where c.id = p_category_id;

  delete from public.warehouse_category_archive_guards g
   where g.backend_pid = pg_backend_pid()
     and g.transaction_id = txid_current()
     and g.category_id = p_category_id;

  insert into public.warehouse_deleted_records
         (entity_type, entity_id, payload, reason, deleted_by)
  values (
    'category',
    p_category_id::text,
    jsonb_build_object(
      'id', v_category.id,
      'code', v_category.code,
      'title', v_category.title,
      'has_subtables', v_category.has_subtables,
      'archived_at', v_archived_at
    ),
    nullif(btrim(p_reason), ''),
    nullif(btrim(p_deleted_by), '')
  );

  return v_archived_at;
end;
$function$;

-- PostgreSQL по умолчанию выдаёт EXECUTE на новую функцию роли PUBLIC.
-- Trigger-функции вызываются самим механизмом триггеров и не требуют EXECUTE
-- у клиента; RPC сначала очищаем от всех клиентских грантов, затем выдаём
-- только authenticated. anon не наследует authenticated.
revoke all on function public.tg_orders_00_mark_explicit_product_type_id()
  from public, anon, authenticated;
revoke all on function public.tg_orders_10_sync_product_type()
  from public, anon, authenticated;
revoke all on function public.tg_orders_99_clear_product_type_marker()
  from public, anon, authenticated;
revoke all on function public.tg_protect_product_type_config()
  from public, anon, authenticated;
revoke all on function public.tg_protect_product_type_form_block()
  from public, anon, authenticated;
revoke all on function public.tg_protect_warehouse_category_archive()
  from public, anon, authenticated;

revoke all on function public.create_product_type_config_draft(uuid)
  from public, anon, authenticated;
revoke all on function public.discard_product_type_config_draft(uuid)
  from public, anon, authenticated;
revoke all on function public.publish_product_type_config(uuid)
  from public, anon, authenticated;
revoke all on function public.archive_warehouse_category(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.create_product_type_config_draft(uuid) to authenticated;
grant execute on function public.discard_product_type_config_draft(uuid) to authenticated;
grant execute on function public.publish_product_type_config(uuid) to authenticated;
grant execute on function public.archive_warehouse_category(uuid, text, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. RLS — повторяет действующую модель, обоснование в шапке файла
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.product_type_configs     enable row level security;
alter table public.order_form_blocks        enable row level security;
alter table public.product_type_form_blocks enable row level security;

create policy product_type_configs_select on public.product_type_configs
  for select to authenticated using (true);
create policy product_type_configs_write on public.product_type_configs
  for all to authenticated using (true) with check (true);

create policy order_form_blocks_select on public.order_form_blocks
  for select to authenticated using (true);

create policy product_type_form_blocks_select on public.product_type_form_blocks
  for select to authenticated using (true);
create policy product_type_form_blocks_write on public.product_type_form_blocks
  for all to authenticated using (true) with check (true);

-- Capability включается только после встроенной проверки законченной схемы.
-- Любая ошибка ниже оставляет M0-row выключенной при атомарном runner; если
-- runner не атомарен, финальный UPDATE всё равно не выполняется.
do $final_schema_checks$
declare
  v_bad text;
begin
  if to_regclass('public.product_type_configs') is null
     or to_regclass('public.order_form_blocks') is null
     or to_regclass('public.product_type_form_blocks') is null
     or to_regclass('public.product_type_config_write_guards') is null
     or to_regclass('public.warehouse_category_archive_guards') is null
     or to_regclass('public.warehouse_deleted_records') is null then
    raise exception 'M1 final check: отсутствует одна из обязательных таблиц.'
      using errcode = '55000';
  end if;

  if not exists (
       select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'orders'
          and column_name = 'product_type_id'
     ) or not exists (
       select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'orders'
          and column_name = 'stage_config_id'
     ) then
    raise exception 'M1 final check: orders.product_type_id/stage_config_id отсутствует.'
      using errcode = '55000';
  end if;

  with expected(name) as (
    values
      ('trg_orders_00_mark_explicit_product_type_id'),
      ('trg_orders_10_sync_product_type'),
      ('trg_orders_99_clear_product_type_marker'),
      ('trg_product_type_configs_immutability'),
      ('trg_product_type_form_blocks_immutability'),
      ('trg_warehouse_categories_archive_guard')
  )
  select string_agg(e.name, ', ' order by e.name)
    into v_bad
    from expected e
   where not exists (
     select 1
       from pg_catalog.pg_trigger t
      where t.tgname = e.name
        and not t.tgisinternal
   );

  if v_bad is not null then
    raise exception 'M1 final check: отсутствуют triggers [%].', v_bad
      using errcode = '55000';
  end if;

  with expected(signature) as (
    values
      ('public.create_product_type_config_draft(uuid)'),
      ('public.discard_product_type_config_draft(uuid)'),
      ('public.publish_product_type_config(uuid)'),
      ('public.archive_warehouse_category(uuid,text,text)')
  )
  select string_agg(e.signature, ', ' order by e.signature)
    into v_bad
    from expected e
   where pg_catalog.to_regprocedure(e.signature) is null;

  if v_bad is not null then
    raise exception 'M1 final check: отсутствуют RPC [%].', v_bad
      using errcode = '55000';
  end if;

  if to_regclass('public.warehouse_categories_title_normalized_uq') is null
     or to_regclass('public.product_type_configs_published_uq') is null
     or to_regclass('public.product_type_configs_draft_uq') is null then
    raise exception 'M1 final check: отсутствуют обязательные unique indexes.'
      using errcode = '55000';
  end if;

  if not exists (
       select 1 from pg_catalog.pg_constraint c
        where c.conrelid = 'public.warehouse_categories'::regclass
          and c.conname = 'warehouse_categories_title_not_blank_check'
          and c.contype = 'c' and c.convalidated
     ) then
    raise exception 'M1 final check: title CHECK отсутствует.'
      using errcode = '55000';
  end if;

  select string_agg(o.id::text, ', ' order by o.id::text)
    into v_bad
    from public.orders o
   where nullif(btrim(o.product->>'type'), '') is not null
     and (
       o.product_type_id is null
       or not exists (
         select 1 from public.warehouse_categories c
          where c.id = o.product_type_id
            and lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
       )
     );

  if v_bad is not null then
    raise exception 'M1 final check: несогласованные orders [%].', v_bad
      using errcode = '23514';
  end if;

  if exists (select 1 from public.product_type_config_write_guards)
     or exists (select 1 from public.warehouse_category_archive_guards) then
    raise exception 'M1 final check: workflow guard-marker не очищен.'
      using errcode = '55000';
  end if;

  if exists (
       select 1
         from public.warehouse_categories c
        where not exists (
          select 1
            from public.product_type_configs cfg
           where cfg.product_type_id = c.id
             and cfg.status = 'published'
        )
     ) then
    raise exception 'M1 final check: не у каждой категории есть published config.'
      using errcode = '55000';
  end if;
end;
$final_schema_checks$;

do $lock_capability_before_enable$
declare
  v_enabled boolean;
begin
  select c.enabled
    into v_enabled
    from public.app_capabilities c
   where c.code = 'product_type_form_blocks_v1'
   for update;

  if not found then
    raise exception 'M1 final check: capability-row отсутствует.'
      using errcode = '55000';
  end if;

  if v_enabled is distinct from false then
    raise exception 'M1 final check: capability должна оставаться false до финального UPDATE.'
      using errcode = '55000';
  end if;
end;
$lock_capability_before_enable$;

UPDATE public.app_capabilities
   SET enabled = true,
       updated_at = now()
 WHERE code = 'product_type_form_blocks_v1';
