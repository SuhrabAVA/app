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
-- ОДНА ФАЗА
-- Клиент выкатывается вместе с этой миграцией. Ни capability-флага, ни M0/M1,
-- ни слоя совместимости здесь нет: предыдущая попытка сделать выкат двухфазным
-- дала неработающее приложение (см. docs/archive/product-type-rollout-codex).
--
-- ЧТО ЗДЕСЬ НЕ ДЕЛАЕТСЯ
-- Таблиц этапов, предикатов и условий нет — построение очереди срез не
-- трогает, он выпускается отдельно именно поэтому. Колонка
-- order_form_blocks.affects_input и флаг is_required заведены авансом и до
-- следующей фазы не читаются: ALTER по живой таблице настроек дороже.
--
-- ТРАНЗАКЦИЯ
-- Явных begin/commit нет намеренно. Проверено: батч операторов исполняется как
-- одна транзакция (два оператора в одном вызове дают общий pg_current_xact_id).
-- Собственная пара ничего не добавила бы, а при внешней транзакции обёртки
-- commit закрыл бы её досрочно. Отсюда следует главное: disable trigger →
-- бэкофилл → enable trigger атомарны, и срабатывание контрольной проверки
-- откатывает в том числе отключение триггера.
--
-- ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: RLS НЕ РАЗГРАНИЧИВАЕТ ДОСТУП
-- Политики новых таблиц открыты для authenticated, как у orders и
-- warehouse_categories. Это текущее состояние системы, а не небрежность:
-- 50 сотрудников работают через две записи auth.users, идентичность живёт в
-- AuthHelper.currentUserId (строка 'tech_leader' в памяти клиента) и до
-- Postgres не доходит, таблица user_roles пуста — все политики, которые её
-- опрашивают, ложны для всех одинаково. Ужесточать политики бессмысленно,
-- пока идентичность не доедет до базы. Разграничение остаётся в UI.

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
-- product jsonb намеренно НЕ трогаем: всё, что его читает, продолжает работать.

alter table public.orders
  add column product_type_id uuid;

comment on column public.orders.product_type_id is
  'Тип продукта заказа, ссылка на warehouse_categories. Заменяет сверку по '
  'заголовку из product->>''type'', которая ломалась при переименовании '
  'категории. product jsonb сохранён для обратной совместимости и остаётся '
  'источником остальных полей продукта. NULL допустим: у части исторических '
  'заказов тип не указан вовсе.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Бэкофилл product_type_id
-- ═══════════════════════════════════════════════════════════════════════════
--
-- trg_orders_updated_at ставит updated_at := now() безусловно, поэтому без
-- отключения бэкофилл поднял бы updated_at у всех сопоставленных заказов и
-- разослал столько же realtime-событий подписчикам списка заказов. Данные бы
-- не пострадали, но сортировка «последние изменённые» схлопнулась бы в один
-- момент времени. trg_orders_sync_prod_plan_upd навешен на
-- UPDATE OF prod_template_id, product и здесь не срабатывает — планы не
-- тронутся.

alter table public.orders disable trigger trg_orders_updated_at;

update public.orders o
   set product_type_id = c.id
  from public.warehouse_categories c
 where lower(btrim(c.title)) = lower(btrim(o.product->>'type'))
   and o.product_type_id is null;

alter table public.orders enable trigger trg_orders_updated_at;

-- Контроль по смыслу, а не по числу заказов: их количество меняется само по
-- себе, и привязка к константе дала бы ложное срабатывание, как только кто-то
-- создаст пустой заказ. Инвариант: не должно остаться ни одного заказа, у
-- которого заголовок типа НЕПУСТОЙ, но категория по нему не нашлась. Заказы
-- вообще без типа остаются NULL законно, сколько бы их ни было.
do $$
declare
  v_null      integer;
  v_unmatched integer;
begin
  select count(*) into v_null
    from public.orders
   where product_type_id is null;

  select count(*) into v_unmatched
    from public.orders
   where product_type_id is null
     and nullif(btrim(coalesce(product->>'type', '')), '') is not null;

  if v_unmatched > 0 then
    raise exception
      'Бэкофилл product_type_id: у % заказов заголовок типа непустой, но '
      'категория по нему не найдена (всего без типа: %). Миграция откачена, '
      'разберите расхождение.', v_unmatched, v_null;
  end if;

  raise notice
    'Бэкофилл product_type_id: без типа осталось % заказов, все с пустым '
    'заголовком.', v_null;
end $$;

-- Внешний ключ ставится ПОСЛЕ бэкофилла, чтобы проверка прошла один раз по
-- уже заполненным данным.
--
-- ON DELETE RESTRICT — СОЗНАТЕЛЬНОЕ ИЗМЕНЕНИЕ ПОВЕДЕНИЯ.
-- Сегодня удаление категории из хаба (жёсткое delete) не задевает заказы: в
-- jsonb остаётся заголовок несуществующей категории. После этой строки удалить
-- категорию, на которую ссылается хотя бы один заказ, станет нельзя —
-- молчаливое осиротение и привело к нынешнему состоянию.
-- Соседние связи на warehouse_categories (materials, paints, papers,
-- stationery) объявлены как NO ACTION, что здесь равносильно RESTRICT: обе
-- блокируют удаление. Они уже сейчас могли бы дать 23503, но у всех четырёх
-- ноль строк с заполненным category_id, поэтому orders станет первым реально
-- срабатывающим источником ошибки.
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
-- Держит product_type_id согласованным с product->>'type' для писателей,
-- которые про колонку не знают.
--
-- ПРАВИЛО: триггер заполняет только то, что писатель не адресовал.
-- PostgREST шлёт в UPDATE лишь перечисленные в .update({...}) колонки, а
-- неперечисленные приходят в NEW со значениями OLD. Поэтому
-- new.product_type_id is distinct from old.product_type_id — точный признак
-- «клиент написал колонку сам», и такую запись триггер не трогает. Проверки
-- «is null» недостаточно: после бэкофилла колонка заполнена почти везде, и
-- смена типа в существующем заказе оставила бы старый id навсегда.
--
-- ТРИГГЕР НИКОГДА НЕ ОТВЕРГАЕТ ЗАПИСЬ.
-- Ни одной ветки raise здесь нет сознательно. Ревью откачённой ветки нашло
-- сценарий, где валидация «id должен соответствовать заголовку» после
-- переименования категории делала заказ несохраняемым. Если заголовок непустой
-- и в справочнике не найден — прежнее значение остаётся как есть, и id с
-- заголовком какое-то время расходятся. Это осознанная плата: расхождение
-- чинится следующей явной записью типа, несохраняемый заказ не чинится ничем.
--
-- УДАЛИТЬ вместе с алиасным распознаванием типа в stage_queue_builder.dart —
-- это единственные два места, где заголовок ещё работает ключом.

create or replace function public.tg_orders_fill_product_type_id()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_title text;
  v_id    uuid;
begin
  -- Клиент прислал id сам — не вмешиваемся.
  if tg_op = 'INSERT' and new.product_type_id is not null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.product_type_id is distinct from old.product_type_id then
    return new;
  end if;

  -- Ничего не изменилось: заголовок тот же, id уже стоит.
  if tg_op = 'UPDATE'
     and new.product_type_id is not null
     and new.product->>'type' is not distinct from old.product->>'type' then
    return new;
  end if;

  v_title := nullif(btrim(coalesce(new.product->>'type', '')), '');
  if v_title is null then
    return new;   -- тип не указан вовсе; прежнее значение не трогаем
  end if;

  select c.id into v_id
    from public.warehouse_categories c
   where lower(btrim(c.title)) = lower(v_title);

  -- Нашли — заполняем. Не нашли — оставляем как было и молча выходим.
  if v_id is not null then
    new.product_type_id := v_id;
  end if;

  return new;
end;
$function$;

comment on function public.tg_orders_fill_product_type_id() is
  'ВРЕМЕННЫЙ. Заполняет orders.product_type_id по заголовку из product, пока '
  'клиент не начал писать колонку сам. Явную запись клиента не перебивает и '
  'никогда не отвергает запись: неизвестный заголовок оставляет прежнее '
  'значение. Удалить после релиза Dart-кода среза 1.';

create trigger trg_orders_fill_product_type_id
  before insert or update of product on public.orders
  for each row execute function public.tg_orders_fill_product_type_id();

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Версии настроек типа продукта
-- ═══════════════════════════════════════════════════════════════════════════

create table public.product_type_configs (
  id              uuid primary key default gen_random_uuid(),
  product_type_id uuid not null
                    references public.warehouse_categories(id) on delete cascade,
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
  'никогда не удаляются физически.';

create unique index product_type_configs_published_uq
  on public.product_type_configs (product_type_id)
  where status = 'published';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Привязка заказа к версии настроек (задел под следующую фазу)
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
-- допускает и второе поведение — если решим, что видимость блоков тоже должна
-- следовать закреплённой версии, меняется только запрос чтения.
--
-- ВНИМАНИЕ ОБРАБОТЧИКУ ОШИБКИ 23503 В ХАБЕ КАТЕГОРИЙ.
-- Связка получается двухступенчатой: product_type_configs удаляется КАСКАДОМ
-- при удалении категории, а orders.stage_config_id ссылается на configs с
-- RESTRICT. Значит, как только stage_config_id начнёт заполняться, удаление
-- категории с заказами будет падать на orders_stage_config_id_fkey, а вовсе не
-- обязательно на orders_product_type_id_fkey — какое из двух ограничений
-- Postgres сообщит первым, не определено. Обработчик должен считать оба имени
-- одним случаем «на категорию ссылаются заказы» и не завязываться на одно.

alter table public.orders
  add column stage_config_id uuid
    references public.product_type_configs(id) on delete restrict;

comment on column public.orders.stage_config_id is
  'Версия настроек, по которой собрана очередь заказа. Заполняется в следующей '
  'фазе. Расхождение с текущей опубликованной версией = маркер «настройки '
  'обновились» в списке заказов. При удалении категории даёт 23503 по '
  'orders_stage_config_id_fkey — обрабатывать вместе с '
  'orders_product_type_id_fkey.';

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
  'форму, а не настроило её. Наполняется миграциями, из приложения только '
  'читается.';

comment on column public.order_form_blocks.affects_input is
  'Связь с фазой правил очереди: какой вход автосборщика принудительно '
  'обнуляется при скрытии блока. Скрыли «Краски» → has_paint = false → '
  'Флексопечать не добавляется. Без этого форма и очередь разъехались бы: '
  'блока не видно, а этап в плане есть. В срезе 1 колонка не читается.';

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
-- таблиц этапов в этом срезе и нет. Категории, заведённые позже, получают
-- версию при первом открытии редактора — это работа UI, не миграции.

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
-- 9. Права и RLS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Гранты выданы явно, а не оставлены на default privileges схемы. Список
-- ролей — принятый в проекте шаблон (20260709_employee_status_history.sql:117,
-- 20260710_workplace_priladka.sql:74): anon, authenticated, service_role.
-- Права при этом разделены по смыслу: order_form_blocks — справочник, из
-- приложения только читается. Фактическим фильтром доступа остаётся RLS,
-- политики которой выданы только authenticated, поэтому грант anon ниже
-- мёртвый и стоит здесь лишь ради единообразия с соседними миграциями.

grant select on public.order_form_blocks
  to anon, authenticated, service_role;

grant select, insert, update, delete on public.product_type_configs
  to anon, authenticated, service_role;

grant select, insert, update, delete on public.product_type_form_blocks
  to anon, authenticated, service_role;

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
