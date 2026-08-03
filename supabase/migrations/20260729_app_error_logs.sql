-- Журнал ошибок приложения на сервере (2026-07-29).
--
-- Задача: локальный лог живёт только внутри сессии — после выхода
-- сотрудника или выключения планшета он недоступен. Клиент выгружает
-- накопленные записи в эту таблицу при уходе приложения в фон/закрытии,
-- а на следующем старте досылает то, что не успело уйти.
--
-- Письмо на почту отправляет отдельная Edge Function (send-error-log-email),
-- которая читает свежие строки отсюда. Таблица — источник правды: даже если
-- почта не настроена или недоступна, логи не теряются.

create table if not exists public.app_error_logs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),

  -- Кто и на чём работал в момент ошибок.
  employee_id text,
  employee_name text,
  device_model text,
  platform text,
  app_version text,

  -- Сессия приложения: все выгрузки одной сессии имеют один session_id.
  session_id text not null,
  session_started_at timestamptz,

  -- Что вызвало выгрузку: paused | detached | logout | startup_flush.
  reason text not null,

  entries_count int not null default 0,

  -- Сами записи: [{time, source, message, stack, context}, ...].
  entries jsonb not null default '[]'::jsonb,

  -- Отправлено ли письмо по этой партии (заполняет Edge Function).
  emailed_at timestamptz
);

create index if not exists idx_app_error_logs_created_at
  on public.app_error_logs (created_at desc);

-- Для выборки «что ещё не отправлено письмом».
create index if not exists idx_app_error_logs_pending_email
  on public.app_error_logs (created_at)
  where emailed_at is null;

alter table public.app_error_logs enable row level security;

-- Приложение работает под общим Supabase-пользователем: разрешаем вставку
-- всем аутентифицированным, чтение — только служебной роли (логи могут
-- содержать текст ошибок с данными заказов).
drop policy if exists app_error_logs_insert on public.app_error_logs;
create policy app_error_logs_insert
  on public.app_error_logs
  for insert
  to authenticated, anon
  with check (true);

drop policy if exists app_error_logs_select_service on public.app_error_logs;
create policy app_error_logs_select_service
  on public.app_error_logs
  for select
  to service_role
  using (true);
