-- =====================================================================
-- Аналитика производства: новые таблицы и поля
-- =====================================================================

-- 1. Справочник статусов сотрудников ----------------------------------
create table if not exists public.employee_statuses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  color       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.employees
  add column if not exists status_id uuid references public.employee_statuses(id);

alter table public.employees
  add column if not exists pay_type text;

-- значения pay_type: 'salary' | 'piece' | 'mixed' (null = не задано)


-- 2. Коэффициенты рабочих мест ----------------------------------------
create table if not exists public.workplace_coefficients (
  id              uuid primary key default gen_random_uuid(),
  workplace_id    text not null,
  coefficient     numeric not null default 0,
  effective_month date not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      text,
  updated_by      text,
  unique (workplace_id, effective_month)
);

create index if not exists workplace_coefficients_workplace_idx
  on public.workplace_coefficients (workplace_id, effective_month desc);


-- 3. Настройки оплаты по месяцам --------------------------------------
create table if not exists public.salary_settings (
  id              uuid primary key default gen_random_uuid(),
  effective_month date not null unique,
  night_percent   numeric not null default 0,
  meal_amount     numeric not null default 0,
  social_default  numeric not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      text
);

create index if not exists salary_settings_month_idx
  on public.salary_settings (effective_month desc);


-- 4. Ручные начисления / удержания по сотруднику за месяц -------------
create table if not exists public.employee_month_salary_adjustments (
  id            uuid primary key default gen_random_uuid(),
  employee_id   text not null,
  month         date not null,
  compensation  numeric not null default 0,
  social        numeric not null default 0,
  advance       numeric not null default 0,
  cashless      numeric not null default 0,
  discipline    numeric not null default 0,
  defect        numeric not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text,
  unique (employee_id, month)
);

create index if not exists employee_month_salary_adjustments_month_idx
  on public.employee_month_salary_adjustments (month);


-- 5. Графики работы ----------------------------------------------------
create table if not exists public.work_schedules (
  id              uuid primary key default gen_random_uuid(),
  employee_id     text not null,
  work_date       date not null,
  shift_type      text not null check (shift_type in ('day','night','off')),
  arrival_time    time,
  departure_time  time,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      text,
  unique (employee_id, work_date)
);

create index if not exists work_schedules_date_idx
  on public.work_schedules (work_date);


-- 6. Претензии ---------------------------------------------------------
create table if not exists public.claims (
  id            uuid primary key default gen_random_uuid(),
  order_id      text not null,
  comment_id    text,
  employee_id   text not null,
  workplace_id  text,
  description   text,
  created_by    text,
  created_at    timestamptz not null default now()
);

create index if not exists claims_order_idx on public.claims (order_id);
create index if not exists claims_employee_idx on public.claims (employee_id);
create index if not exists claims_workplace_idx on public.claims (workplace_id);


-- 7. RLS политики ------------------------------------------------------
-- Включаем RLS и открываем для authenticated, чтобы клиент работал.
do $$ begin
  perform 1;
exception when others then null;
end $$;

alter table public.employee_statuses enable row level security;
alter table public.workplace_coefficients enable row level security;
alter table public.salary_settings enable row level security;
alter table public.employee_month_salary_adjustments enable row level security;
alter table public.work_schedules enable row level security;
alter table public.claims enable row level security;

drop policy if exists employee_statuses_all on public.employee_statuses;
create policy employee_statuses_all on public.employee_statuses
  for all using (true) with check (true);

drop policy if exists workplace_coefficients_all on public.workplace_coefficients;
create policy workplace_coefficients_all on public.workplace_coefficients
  for all using (true) with check (true);

drop policy if exists salary_settings_all on public.salary_settings;
create policy salary_settings_all on public.salary_settings
  for all using (true) with check (true);

drop policy if exists employee_month_salary_adjustments_all on public.employee_month_salary_adjustments;
create policy employee_month_salary_adjustments_all on public.employee_month_salary_adjustments
  for all using (true) with check (true);

drop policy if exists work_schedules_all on public.work_schedules;
create policy work_schedules_all on public.work_schedules
  for all using (true) with check (true);

drop policy if exists claims_all on public.claims;
create policy claims_all on public.claims
  for all using (true) with check (true);
