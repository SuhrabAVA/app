-- Дополнительные опции заказа: справочник на тип продукта + снимок в заказе.
--
-- ЗАЧЕМ
-- Техлиду нужны произвольные поля заказа, которых сегодня нет в форме:
-- «Ламинация — да/нет», «Тип ручки — из списка», завтра «Перфорация», «Вид
-- клея». Каждое такое поле сейчас означало бы правку кода формы. Миграция
-- переносит перечень полей в данные: опции и их варианты заводятся из
-- редактора, форма строится по справочнику.
--
-- ГРАНИЦА: ОПЦИИ НЕ ВЛИЯЮТ НА ПРОИЗВОДСТВО
-- Опции только хранятся и показываются. Ни на состав очереди этапов, ни на
-- предикаты маршрута (product_type_stage_conditions) они не действуют.
-- Существующее поле «Тип ручки» — предикат handle_type_is и правила R25–R28
-- в stage_queue_builder.dart — остаётся отдельным и работает как прежде.
-- Опция с таким же названием, заведённая в редакторе, будет ВТОРЫМ полем и на
-- маршрут не повлияет; заводить её не нужно.
--
-- ПОЧЕМУ БЕЗ ВЕРСИЙ И ЧЕРНОВИКОВ
-- У настроек типа продукта версии есть неспроста: правка там меняет маршрут,
-- и долетевшая наполовину правка ломает производство. Здесь ломать нечего —
-- цена ошибки равна одной строке в форме. Требование заказчика прямое:
-- добавил вариант — он сразу виден при создании новых заказов. Поэтому
-- product_type_configs эти таблицы не касаются, правка действует немедленно.
--
-- ПОЧЕМУ СНИМОК, А НЕ ССЫЛКА
-- Выбранное значение обязано пережить любую правку справочника: заказ,
-- открытый через год из архива, показывает то, что выбрали при создании.
-- Ссылка на order_option_values этого не даёт — переименование варианта
-- переписало бы историю всех заказов разом. Поэтому в заказ пишется СНИМОК:
-- название опции и текст значения на момент сохранения.
--
-- ПОЧЕМУ jsonb В orders, А НЕ ТАБЛИЦА ЗНАЧЕНИЙ
-- Заказ сохраняется одним insert/update из OrderModel.toMap()
-- (orders_provider.dart:1075, :1254), а список заказов и архив читают строки
-- orders без джойнов. Отдельная таблица значений завела бы второй путь записи
-- рядом с оптимистичным обновлением и лишний запрос на каждом экране показа.
-- Значения по опциям никогда не агрегируются и не фильтруются в SQL — читать
-- их иначе как «все опции этого заказа» незачем. Прецедент рядом:
-- orders.queue_signature.
--
-- ЧТО ЗДЕСЬ НЕ ДЕЛАЕТСЯ
-- Колонка orders.extra_options заводится, но ни клиентом, ни сервером пока не
-- читается и не пишется: редактор и блок формы — следующие фазы. Значение по
-- умолчанию '[]' делает включение бесшовным — фазе записи не придётся
-- различать «опций не было» и «опции не выбраны».
--
-- RLS
-- Политики открыты для authenticated, как у orders и product_type_configs.
-- Причина та же, что описана в 20260806_product_type_form_blocks.sql: 50
-- сотрудников работают через две записи auth.users, идентичность до Postgres
-- не доходит. Разграничение доступа к редактору остаётся в UI.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Опции типа продукта
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.order_option_defs (
  id              uuid primary key default gen_random_uuid(),
  product_type_id uuid not null
                    references public.warehouse_categories(id) on delete cascade,
  title           text not null check (btrim(title) <> ''),
  kind            text not null check (kind in ('boolean','select')),
  sort_order      integer not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

comment on table public.order_option_defs is
  'Дополнительная опция заказа для одного типа продукта. kind = boolean — '
  'выбор Да/Нет, select — выбор из order_option_values. Заводится техлидом из '
  'редактора опций, правка действует сразу: версий и черновиков у этих таблиц '
  'нет.';

comment on column public.order_option_defs.sort_order is
  'Порядок показа в блоке «Дополнительные опции». Задаётся техлидом '
  'перетаскиванием, при равенстве значений порядок доопределяется по '
  'названию — иначе строки прыгали бы между открытиями формы.';

comment on column public.order_option_defs.is_active is
  'Мягкое удаление. Снятый флаг убирает опцию из формы НОВЫХ заказов, но '
  'заказы, где значение уже выбрано, продолжают его показывать: они хранят '
  'снимок в orders.extra_options и на эту строку не смотрят. Физическое '
  'удаление тоже безопасно по той же причине, но лишает историю расшифровки.';

create index if not exists order_option_defs_by_type
  on public.order_option_defs (product_type_id, sort_order, id);

-- Тёзки среди действующих опций одного типа продукта запрещены: в форме они
-- дали бы две неразличимые строки, а в снимке заказа — два одинаковых
-- названия без способа понять, какое из них какое.
create unique index if not exists order_option_defs_active_title_uq
  on public.order_option_defs (product_type_id, lower(btrim(title)))
  where is_active;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Варианты опции
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.order_option_values (
  id         uuid primary key default gen_random_uuid(),
  option_id  uuid not null
               references public.order_option_defs(id) on delete cascade,
  title      text not null check (btrim(title) <> ''),
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.order_option_values is
  'Вариант опции с kind = select. У опции kind = boolean строк здесь не '
  'бывает: Да/Нет не редактируется и в справочнике не хранится. Сменить kind '
  'у заведённой опции редактор не даёт — смена означала бы либо удаление '
  'вариантов, либо список без единого варианта. Нужен другой тип — заводится '
  'другая опция.';

comment on column public.order_option_values.is_active is
  'Мягкое удаление, зеркало order_option_defs.is_active. Неактивный вариант '
  'не предлагается в новых заказах, но остаётся выбранным там, где его уже '
  'выбрали, и подставляется в список выбора при правке такого заказа — иначе '
  'открытие заказа на редактирование молча сбрасывало бы значение.';

create index if not exists order_option_values_by_option
  on public.order_option_values (option_id, sort_order, id);

create unique index if not exists order_option_values_active_title_uq
  on public.order_option_values (option_id, lower(btrim(title)))
  where is_active;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Снимок выбранных значений в заказе
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ФОРМАТ: массив объектов, по одному на ВЫБРАННУЮ опцию. Невыбранные опции в
-- массив не попадают — заполнение необязательно, и пустая строка отличается от
-- отсутствующей только шумом.
--
--   [{"option_id":   "uuid",       -- ссылка на order_option_defs; нужна,
--                                  --   чтобы при правке заказа узнать свою
--                                  --   опцию
--     "title":       "Тип ручки",  -- название НА МОМЕНТ СОХРАНЕНИЯ
--     "kind":        "select",     -- boolean | select
--     "value_id":    "uuid",       -- select: order_option_values.id;
--                                  --   boolean: 'yes' | 'no'
--     "value_label": "Верёвочная", -- текст НА МОМЕНТ СОХРАНЕНИЯ; именно он
--                                  --   показывается в просмотре и архиве
--     "sort":        10}]          -- порядок на момент сохранения
--
-- Показ строится по value_label, а не по справочнику. Поэтому переименование
-- или удаление варианта не меняет ни одного уже сохранённого заказа.

alter table public.orders
  add column if not exists extra_options jsonb not null default '[]'::jsonb;

do $$
begin
  alter table public.orders
    add constraint orders_extra_options_is_array
      check (jsonb_typeof(extra_options) = 'array');
exception when duplicate_object then null;
end $$;

comment on column public.orders.extra_options is
  'Снимок дополнительных опций заказа: массив '
  '{option_id, title, kind, value_id, value_label, sort}. Именно снимок, а не '
  'ссылки: просмотр и архив рисуются из него, поэтому правка справочника '
  'order_option_defs / order_option_values не переписывает историю заказов. '
  'Формат разобран в миграции 20260910_order_extra_options.sql.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Права и RLS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Список ролей — принятый в проекте шаблон
-- (20260806_product_type_form_blocks.sql, раздел 9). Грант anon мёртвый:
-- политики выданы только authenticated.

grant select, insert, update, delete on public.order_option_defs
  to anon, authenticated, service_role;

grant select, insert, update, delete on public.order_option_values
  to anon, authenticated, service_role;

alter table public.order_option_defs   enable row level security;
alter table public.order_option_values enable row level security;

drop policy if exists order_option_defs_select on public.order_option_defs;
create policy order_option_defs_select on public.order_option_defs
  for select to authenticated using (true);
drop policy if exists order_option_defs_write on public.order_option_defs;
create policy order_option_defs_write on public.order_option_defs
  for all to authenticated using (true) with check (true);

drop policy if exists order_option_values_select on public.order_option_values;
create policy order_option_values_select on public.order_option_values
  for select to authenticated using (true);
drop policy if exists order_option_values_write on public.order_option_values;
create policy order_option_values_write on public.order_option_values
  for all to authenticated using (true) with check (true);
