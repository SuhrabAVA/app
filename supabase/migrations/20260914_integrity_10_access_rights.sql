-- ============================================================================
-- Целостность данных, шаг 10: доступ к базе только после входа (2026-09-14)
--
-- Что чинит
-- ---------
-- Supabase-клиент приложения входит общим пользователем (AUTH_EMAIL из .env)
-- и работает в роли authenticated. Но у роли anon — то есть у любого, кто
-- знает адрес проекта и публичный ключ (он лежит в каждой сборке), — было:
--   * 791 право на таблицы (чтение, запись, удаление);
--   * 110 функций, включая SECURITY DEFINER — завершение этапов, списания;
--   * 14 таблиц вообще без RLS, среди них tasks.
-- Анонимных запросов к данным приложение не делает: за сутки в логах шлюза
-- anon встречается только на /auth/v1/token — это сам вход.
--
-- 12 представлений выполнялись с правами владельца (security definer view) и
-- обходили RLS своих таблиц.
--
-- Что делает миграция
-- -------------------
-- 1. RLS на 14 таблицах с политикой «вошедшему можно всё» — для приложения
--    ничего не меняется, anon отрезается.
-- 2. У anon отзываются права на таблицы, последовательности и функции схемы
--    public, и то же — для объектов, которые появятся позже.
-- 3. Представления выполняются с правами вызывающего (security_invoker).
--
-- Чего миграция НЕ делает: не меняет политики внутри authenticated. Все
-- устройства входят одним пользователем, различать сотрудников на уровне базы
-- пока не из чего — это отдельная задача (вход каждого сотрудника своим
-- пользователем).
-- ============================================================================

begin;

-- ─── 1. RLS на таблицах без неё ─────────────────────────────────────────────

do $rls$
declare
  t text;
begin
  foreach t in array array[
    'tasks', 'production_plans', 'paper_items', 'paper_moves',
    'warehouse_pens', 'warehouse_pens_arrivals', 'warehouse_pens_writeoffs',
    'warehouse_pens_inventories', 'personnel_positions', 'personnel_workplaces',
    'personnel_employees', 'workplace_id_map', 'position_id_map',
    'tasks_comments_backup'
  ] loop
    if to_regclass('public.' || t) is null then
      continue;
    end if;
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists authenticated_full_access on public.%I', t);
    execute format('create policy authenticated_full_access on public.%I '
                   'for all to authenticated using (true) with check (true)', t);
  end loop;
end
$rls$;

-- ─── 2. Роль anon без доступа к данным ──────────────────────────────────────

-- Сначала явный grant вошедшему: часть функций была доступна ему только через
-- PUBLIC, и отзыв у PUBLIC без этого отнял бы их и у приложения.
grant execute on all functions in schema public to authenticated, service_role;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema public from public;

alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, public;
alter default privileges for role postgres in schema public
  grant execute on functions to authenticated, service_role;

-- ─── 3. Представления с правами вызывающего ─────────────────────────────────

do $views$
declare
  v text;
begin
  for v in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
  loop
    execute format('alter view public.%I set (security_invoker = true)', v);
  end loop;
end
$views$;

commit;
