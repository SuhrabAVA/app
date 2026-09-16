-- Отметки прихода и ухода сотрудников (2026-08-15).
--
-- Нужны сотрудникам, у которых есть статус (уборщик, охранник и т.п.), но нет
-- должности: заданий они не выполняют, и в производственных таблицах их следа
-- нет. Отметка — это факт, а не план: план лежит в work_schedules
-- (arrival_time/departure_time заполняет руководитель).
--
-- ВАЖНО: отметка НЕ влияет на начисление. Смена под статусом оплачивается по
-- графику — сотрудник может забыть отметиться, и зарплату это не меняет
-- (см. SalaryCalculator._statusShiftCounts). Отметки нужны только для
-- наглядности в аналитике: пришёл/ушёл и сколько пробыл.
--
-- work_date — день смены, а не календарные сутки: ночная смена, начавшаяся
-- вечером, целиком относится к своему дню (см. lib/utils/shift_day.dart).
-- Клиент вычисляет его сам и присылает готовым.

create table if not exists public.employee_attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null,
  work_date date not null,
  arrived_at timestamptz,
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Одна строка на сотрудника в день: повторные нажатия обновляют её.
  constraint employee_attendance_unique_day unique (employee_id, work_date)
);

create index if not exists idx_employee_attendance_date
  on public.employee_attendance (work_date desc);

create index if not exists idx_employee_attendance_employee
  on public.employee_attendance (employee_id, work_date desc);

alter table public.employee_attendance enable row level security;

-- Приложение работает под общим Supabase-пользователем, как и остальные
-- таблицы модуля персонала: разграничение по сотрудникам делается в клиенте.
drop policy if exists employee_attendance_rw on public.employee_attendance;
create policy employee_attendance_rw
  on public.employee_attendance
  for all
  to authenticated, anon
  using (true)
  with check (true);

-- Realtime: отметки видны в аналитике сразу, без перезахода.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'employee_attendance'
     )
  then
    execute 'alter publication supabase_realtime add table public.employee_attendance';
  end if;
end
$$;
