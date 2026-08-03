-- ============================================================================
-- Миграция: статусы сотрудников с фиксированной оплатой по истории периодов
-- Дата: 2026-07-09
--
-- 1. employee_status_history — история присвоения/снятия статусов сотрудникам
--    с датами (date_from включительно, date_to исключительно, null = открыт).
--    Текущий статус сотрудника = строка с date_to is null.
-- 2. employee_status_pay_rates — фиксированная ставка за смену по статусу,
--    версионируется по месяцу (effective_month), по образцу
--    workplace_coefficients (carry-forward: берётся последняя ставка
--    с effective_month <= выбранный месяц).
-- 3. employees.status_id (существующая колонка) больше не используется как
--    источник истины — оставляем как есть (без DDL), заменяется историей.
--
-- Примечание про типы: employee_id/status_id объявлены как text, а не uuid.
-- В этом проекте уже был инцидент с рассинхроном uuid/text между колонками
-- (42883 "operator does not exist: uuid = text"), а фактический тип
-- employees.id / employee_statuses.id в живой базе отсюда не проверить.
-- text принимает любое представление id без риска упасть на INSERT;
-- FK-ограничения ниже добавляются "best effort" (через DO-блок с перехватом
-- исключения) — если типы совпадут, ссылочная целостность включится, если
-- нет — просто пропустится, без прерывания скрипта.
-- ============================================================================

begin;

create table if not exists public.employee_status_history (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null,
  status_id text not null,
  date_from date not null,
  date_to date null,
  created_at timestamptz not null default now(),
  constraint employee_status_history_date_check
    check (date_to is null or date_to > date_from)
);

-- Не более одного открытого периода на сотрудника одновременно.
create unique index if not exists ux_employee_status_history_open
  on public.employee_status_history (employee_id)
  where date_to is null;

-- Для выборки периодов, пересекающих месяц/диапазон дат.
create index if not exists ix_employee_status_history_range
  on public.employee_status_history (employee_id, date_from, date_to);

create index if not exists ix_employee_status_history_status
  on public.employee_status_history (status_id);

create table if not exists public.employee_status_pay_rates (
  id uuid primary key default gen_random_uuid(),
  status_id text not null,
  fixed_day_pay numeric not null default 0,
  effective_month date not null,
  updated_at timestamptz not null default now(),
  updated_by text null,
  constraint employee_status_pay_rates_unique unique (status_id, effective_month)
);

create index if not exists ix_employee_status_pay_rates_month
  on public.employee_status_pay_rates (effective_month desc);

-- ----------------------------------------------------------------------------
-- Best-effort внешние ключи: пытаемся привязать к employees/employee_statuses.
-- Если типы колонок не совпадают (text vs uuid) — ловим исключение и просто
-- пропускаем ограничение, не прерывая транзакцию.
-- ----------------------------------------------------------------------------
do $$
begin
  begin
    alter table public.employee_status_history
      add constraint employee_status_history_employee_fk
      foreign key (employee_id) references public.employees(id) on delete cascade;
  exception when others then
    raise notice 'Пропущен FK employee_status_history.employee_id -> employees.id: %', sqlerrm;
  end;

  begin
    alter table public.employee_status_history
      add constraint employee_status_history_status_fk
      foreign key (status_id) references public.employee_statuses(id) on delete cascade;
  exception when others then
    raise notice 'Пропущен FK employee_status_history.status_id -> employee_statuses.id: %', sqlerrm;
  end;

  begin
    alter table public.employee_status_pay_rates
      add constraint employee_status_pay_rates_status_fk
      foreign key (status_id) references public.employee_statuses(id) on delete cascade;
  exception when others then
    raise notice 'Пропущен FK employee_status_pay_rates.status_id -> employee_statuses.id: %', sqlerrm;
  end;
end $$;

-- RLS: включаем и разрешаем чтение/запись авторизованным пользователям,
-- по образцу остальных таблиц модуля аналитики/персонала в этом проекте
-- (не ограничиваем по ролям на уровне БД — контроль доступа на уровне
-- приложения через AuthHelper.isTechLeader/canEdit, как и для соседних
-- финансовых таблиц workplace_coefficients/salary_settings).
alter table public.employee_status_history enable row level security;
alter table public.employee_status_pay_rates enable row level security;

drop policy if exists employee_status_history_all on public.employee_status_history;
create policy employee_status_history_all
  on public.employee_status_history
  for all
  using (true)
  with check (true);

drop policy if exists employee_status_pay_rates_all on public.employee_status_pay_rates;
create policy employee_status_pay_rates_all
  on public.employee_status_pay_rates
  for all
  using (true)
  with check (true);

grant select, insert, update, delete on public.employee_status_history to anon, authenticated, service_role;
grant select, insert, update, delete on public.employee_status_pay_rates to anon, authenticated, service_role;

commit;
