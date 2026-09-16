-- Отгрузка частями: журнал отгрузок заказа.
--
-- ЗАЧЕМ
-- Отгрузка была одним событием и тремя полями в заказе: `shipped_at`,
-- `shipped_by`, `shipped_qty`. Заказ отгружался ровно один раз и сразу уходил
-- в архив. На деле тираж часто забирают партиями: сегодня половину, через
-- неделю остальное. Каждая такая партия — своя дата, своё количество, свой
-- сотрудник и свой документ, и трёх полей на это не хватает.
--
-- ЧТО МЕНЯЕТСЯ В ЗАКАЗЕ
-- Поля заказа остаются и продолжают означать то же, что и раньше: ПОСЛЕДНЮЮ
-- отгрузку и факт закрытия. `shipped_at` проставляется только когда отгружено
-- всё фактическое количество, — до тех пор заказ висит в «Завершённых» и
-- готов к следующей отгрузке. Отсюда же следует правило «выбрал частями, но
-- списал весь факт»: заказ закрывается так же, как при отгрузке разом.
--
-- ПОЧЕМУ НЕ ПЕРЕСЧИТЫВАТЬ ОТГРУЖЕННОЕ КАЖДЫЙ РАЗ ПО ЖУРНАЛУ
-- Пересчитывать и надо: сумма строк журнала — единственная правда об
-- отгруженном. `orders.shipped_qty` при этом хранит количество ПОСЛЕДНЕЙ
-- партии, как и хранил; складывать его с журналом нельзя.

create table if not exists public.order_shipments (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  qty         numeric not null check (qty > 0),
  shipped_at  timestamptz not null default now(),
  shipped_by  text not null default '',
  user_id     text,
  has_document boolean not null default false,
  note        text,
  created_at  timestamptz not null default now()
);

comment on table public.order_shipments is
  'Партии отгрузки заказа: по строке на каждую. Сумма qty — сколько всего '
  'отгружено; заказ закрывается (orders.shipped_at), когда сумма достигла '
  'фактического количества. До тех пор заказ остаётся в «Завершённых» и '
  'доступен для следующей отгрузки.';

comment on column public.order_shipments.has_document is
  'Отгрузка сопровождена документом. Ставит и снимает кладовщик галочкой; '
  'каждое переключение пишется в историю заказа отдельным событием — по этому '
  'признаку ищут партии, по которым бумаги не пришли.';

comment on column public.order_shipments.shipped_by is
  'Имя сотрудника на момент отгрузки — снимок, а не ссылка. Сотрудника могут '
  'переименовать или уволить, а в журнале отгрузок должно остаться то, что '
  'было записано тогда. Ссылка на учётную запись — в user_id, рядом.';

create index if not exists order_shipments_by_order
  on public.order_shipments (order_id, shipped_at);

-- ═══════════════════════════════════════════════════════════════════════════
-- Права и RLS
-- ═══════════════════════════════════════════════════════════════════════════

grant select, insert, update, delete on public.order_shipments
  to anon, authenticated, service_role;

alter table public.order_shipments enable row level security;

drop policy if exists order_shipments_select on public.order_shipments;
create policy order_shipments_select on public.order_shipments
  for select to authenticated using (true);

drop policy if exists order_shipments_write on public.order_shipments;
create policy order_shipments_write on public.order_shipments
  for all to authenticated using (true) with check (true);

-- ═══════════════════════════════════════════════════════════════════════════
-- Перенос уже отгруженных заказов
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Без этого архив у старых заказов показал бы пустую таблицу отгрузок, хотя
-- отгрузка была. Данных ровно на одну строку — столько, сколько хранил заказ.
-- Идемпотентно: повторный прогон не задваивает, потому что проверяет, есть ли
-- уже строки у заказа.

insert into public.order_shipments (order_id, qty, shipped_at, shipped_by, has_document)
select o.id,
       coalesce(nullif(o.shipped_qty, 0), o.actual_qty, 0),
       o.shipped_at,
       coalesce(o.shipped_by, ''),
       false
  from public.orders o
 where o.shipped_at is not null
   and coalesce(nullif(o.shipped_qty, 0), o.actual_qty, 0) > 0
   and not exists (
     select 1 from public.order_shipments s where s.order_id = o.id
   );
