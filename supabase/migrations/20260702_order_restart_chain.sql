-- ============================================================================
-- Миграция: сквозная история комментариев через возобновления заказа (Фаза 1)
-- Дата: 2026-07-02
--
-- 1. Чинит RPC get_order_restart_history: раньше падала с 42883
--    ("operator does not exist: uuid = text") из-за сравнения uuid-колонки
--    с text-параметром без каста.
-- 2. Добавляет RPC get_order_generation_chain: полная цепочка поколений
--    (предки + потомки) одним запросом по restart_root_order_id.
-- 3. Частичный бэкфилл: нормализация restart_root_order_id и
--    restart_generation только там, где заполнен restarted_from_order_id.
--    Заказы без связей не трогаем. RLS не меняется.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Пересоздание get_order_restart_history (удаляем все перегрузки,
--    т.к. сигнатура/тип возврата старой версии могут отличаться).
-- ----------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select oid::regprocedure as sig
    from pg_proc
    where proname = 'get_order_restart_history'
      and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

-- Возвращает сам заказ (depth 0) и всех его предков по цепочке
-- restarted_from_order_id. Клиент (OrderRestartHistoryRepository)
-- читает поля id, restarted_from_order_id, completed_at, updated_at
-- и сам отфильтровывает текущий заказ.
create function public.get_order_restart_history(
  p_order_id text,
  p_limit integer default 200
)
returns table (
  id uuid,
  restarted_from_order_id uuid,
  completed_at timestamptz,
  updated_at timestamptz
)
language sql
stable
as $$
  with recursive chain as (
    select
      o.id,
      o.restarted_from_order_id,
      o.completed_at,
      o.updated_at,
      0 as depth,
      array[o.id] as visited
    from public.orders o
    where o.id = p_order_id::uuid
    union all
    select
      p.id,
      p.restarted_from_order_id,
      p.completed_at,
      p.updated_at,
      c.depth + 1,
      c.visited || p.id
    from public.orders p
    join chain c on p.id = c.restarted_from_order_id
    where not p.id = any(c.visited)                -- защита от циклов
      and c.depth < greatest(coalesce(p_limit, 200), 1)
  )
  select c.id, c.restarted_from_order_id, c.completed_at, c.updated_at
  from chain c
  order by c.depth
  limit greatest(coalesce(p_limit, 200), 1) + 1;
$$;

comment on function public.get_order_restart_history(text, integer) is
  'Заказ и его предки по цепочке возобновлений (restarted_from_order_id), от текущего вглубь.';

-- ----------------------------------------------------------------------------
-- 2. Полная цепочка поколений (предки + потомки) одним запросом.
--    Корень цепочки = coalesce(restart_root_order_id, id) запрошенного заказа;
--    участники = корень + все заказы с restart_root_order_id = корень.
-- ----------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select oid::regprocedure as sig
    from pg_proc
    where proname = 'get_order_generation_chain'
      and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

create function public.get_order_generation_chain(
  p_order_id text
)
returns table (
  id uuid,
  restarted_from_order_id uuid,
  restart_root_order_id uuid,
  restart_generation integer,
  created_at timestamptz,
  order_date timestamptz,
  completed_at timestamptz,
  updated_at timestamptz,
  status text
)
language sql
stable
as $$
  with target as (
    select coalesce(o.restart_root_order_id, o.id) as root_id
    from public.orders o
    where o.id = p_order_id::uuid
  )
  select
    o.id,
    o.restarted_from_order_id,
    o.restart_root_order_id,
    coalesce(o.restart_generation, 0),
    o.created_at,
    o.order_date,
    o.completed_at,
    o.updated_at,
    o.status::text
  from public.orders o
  join target t
    on o.id = t.root_id
    or o.restart_root_order_id = t.root_id
  order by coalesce(o.restart_generation, 0), o.created_at;
$$;

comment on function public.get_order_generation_chain(text) is
  'Все поколения цепочки возобновлений заказа (оригинал и возобновления), по возрастанию поколения.';

-- Функции SECURITY INVOKER (по умолчанию): читают orders под RLS вызывающего,
-- т.е. исторические комментарии видят те же роли, что видят заказ.
grant execute on function public.get_order_restart_history(text, integer)
  to anon, authenticated, service_role;
grant execute on function public.get_order_generation_chain(text)
  to anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Индекс под выборку цепочки по корню (частичный — NULL-ов большинство).
-- ----------------------------------------------------------------------------
create index if not exists idx_orders_restart_root_order_id
  on public.orders (restart_root_order_id)
  where restart_root_order_id is not null;

-- ----------------------------------------------------------------------------
-- 4. Частичный бэкфилл: пересчёт restart_root_order_id / restart_generation
--    ТОЛЬКО у заказов с заполненным restarted_from_order_id, чья цепочка
--    прослеживается до корня. Заказы с оборванной связью (родитель удалён)
--    и заказы без restarted_from_order_id не изменяются.
-- ----------------------------------------------------------------------------
with recursive lineage as (
  -- корни: заказы без родителя
  select o.id, o.id as root_id, 0 as gen, array[o.id] as visited
  from public.orders o
  where o.restarted_from_order_id is null
  union all
  -- потомки: идём вниз по ссылкам restarted_from_order_id
  select o.id, l.root_id, l.gen + 1, l.visited || o.id
  from public.orders o
  join lineage l on o.restarted_from_order_id = l.id
  where not o.id = any(l.visited)                  -- защита от циклов
)
update public.orders o
set restart_root_order_id = l.root_id,
    restart_generation    = l.gen
from lineage l
where o.id = l.id
  and o.restarted_from_order_id is not null
  and (o.restart_root_order_id is distinct from l.root_id
       or o.restart_generation is distinct from l.gen);

commit;
