-- ============================================================================
-- Миграция: способ расчёта приладки и цена приладки по рабочим местам
-- Дата: 2026-07-10
--
-- 1. workplaces.priladka_calc_mode — способ расчёта приладки для рабочих мест
--    с включённой приладкой (has_machine = true):
--      by_colors — по количеству красок заказа,
--      by_order  — одна приладка за заказ,
--      by_size   — приладка засчитывается, если размеры заказа (ширина/
--                  длина/глубина) отличаются от предыдущего заказа,
--                  обработанного на этом рабочем месте.
--    null = режим не выбран (админ обязан выбрать при включённой приладке).
-- 2. workplaces.priladka_price — цена за одну засчитанную приладку (₸).
-- 3. workplace_setup_history — журнал завершённых наладок по рабочим местам
--    в хронологии фактического выполнения. Используется режимом by_size для
--    поиска «предыдущего заказа» и как аудит начисленных приладок.
--
-- Примечание про типы: workplace_id/order_id/task_id объявлены как text —
-- в живой базе есть строковые id рабочих мест ('w_bobiner') наряду с uuid,
-- поэтому uuid-тип здесь не подходит (см. прецедент 42883 uuid=text).
-- ============================================================================

begin;

alter table public.workplaces
  add column if not exists priladka_calc_mode text null;

alter table public.workplaces
  add column if not exists priladka_price numeric not null default 0;

do $$
begin
  begin
    alter table public.workplaces
      add constraint workplaces_priladka_calc_mode_check
      check (priladka_calc_mode is null
             or priladka_calc_mode in ('by_colors', 'by_order', 'by_size'));
  exception when duplicate_object then
    raise notice 'Constraint workplaces_priladka_calc_mode_check уже существует';
  end;
end $$;

create table if not exists public.workplace_setup_history (
  id uuid primary key default gen_random_uuid(),
  workplace_id text not null,
  order_id text null,
  task_id text null,
  employee_id text null,
  -- Размеры продукта заказа на момент наладки (null = размер не задан).
  width numeric null,
  height numeric null,
  depth numeric null,
  -- Сколько приладок засчитано этой наладкой и по какому режиму.
  counted_qty numeric not null default 0,
  calc_mode text null,
  note text null,
  created_at timestamptz not null default now()
);

-- Выборка «последняя наладка на рабочем месте» (хронология выполнения).
create index if not exists ix_workplace_setup_history_last
  on public.workplace_setup_history (workplace_id, created_at desc);

-- RLS: как у соседних таблиц модуля (контроль доступа на уровне приложения).
alter table public.workplace_setup_history enable row level security;

drop policy if exists workplace_setup_history_all on public.workplace_setup_history;
create policy workplace_setup_history_all
  on public.workplace_setup_history
  for all
  using (true)
  with check (true);

grant select, insert, update, delete on public.workplace_setup_history to anon, authenticated, service_role;

commit;
